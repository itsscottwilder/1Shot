// Compressor — a small built-in voice compressor (threshold, ratio up to 10:1, make-up gain)
// running as an in-app Audio Unit, plus the gain-reduction meter shown in the audio drawer.

import Cocoa
import AVFoundation

/// Shared between the UI and the audio thread (plain floats — a stale value for one block is harmless).
private struct CompressorState {
    var threshold: Float = 0        // dBFS
    var ratio: Float = 1            // 1 = no compression
    var makeup: Float = 0           // dB
    var attackCoef: Float = 0
    var releaseCoef: Float = 0
    var envelope: Float = 0
    var gainReductionPeak: Float = 0   // dB (positive), max since last read
}

final class CompressorAU: AUAudioUnit {
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x7470636D,          // 'tpcm'
        componentManufacturer: 0x54435059,     // 'TCPY'
        componentFlags: 0, componentFlagsMask: 0)

    /// Makes the compressor available to AVAudioUnit.instantiate (once per launch).
    static let registered: Bool = {
        AUAudioUnit.registerSubclass(CompressorAU.self, as: componentDescription,
                                     name: "1Shot: Compressor", version: 1)
        return true
    }()

    private static let maxFrames = 8192
    private static let maxChannels = 8

    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!
    private let state = UnsafeMutablePointer<CompressorState>.allocate(capacity: 1)
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: CompressorAU.maxFrames * CompressorAU.maxChannels)

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        state.initialize(to: CompressorState())
        scratch.initialize(repeating: 0, count: Self.maxFrames * Self.maxChannels)
        try super.init(componentDescription: componentDescription, options: options)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [try AUAudioUnitBus(format: format)])
        outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [try AUAudioUnitBus(format: format)])
        maximumFramesToRender = 4096
    }

    deinit {
        state.deinitialize(count: 1)
        state.deallocate()
        scratch.deallocate()
    }

    override var inputBusses: AUAudioUnitBusArray { inputs }
    override var outputBusses: AUAudioUnitBusArray { outputs }
    override var canProcessInPlace: Bool { true }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let rate = Float(outputs[0].format.sampleRate)
        state.pointee.attackCoef = expf(-1 / (0.010 * rate))     // 10 ms
        state.pointee.releaseCoef = expf(-1 / (0.150 * rate))    // 150 ms
        state.pointee.envelope = 0
    }

    func setParameters(threshold: Double, ratio: Double, makeup: Double) {
        state.pointee.threshold = Float(threshold)
        state.pointee.ratio = Float(max(1, ratio))
        state.pointee.makeup = Float(makeup)
    }

    /// Largest gain reduction (dB) since the last call.
    func takeGainReduction() -> Float {
        let value = state.pointee.gainReductionPeak
        state.pointee.gainReductionPeak = 0
        return value
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let state = self.state
        let scratch = self.scratch
        let maxFrames = Self.maxFrames
        let maxChannels = Self.maxChannels
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pull = pullInputBlock else { return kAudioUnitErr_NoConnection }
            let frames = Int(frameCount)
            guard frames <= maxFrames else { return kAudioUnitErr_TooManyFramesToProcess }

            // Give the host's buffers somewhere to land if it didn't provide memory.
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            for i in 0..<min(buffers.count, maxChannels) {
                if buffers[i].mData == nil {
                    buffers[i].mData = UnsafeMutableRawPointer(scratch + i * maxFrames)
                }
                buffers[i].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size)
            }
            var pullFlags = AudioUnitRenderActionFlags()
            let status = pull(&pullFlags, timestamp, frameCount, 0, outputData)
            guard status == noErr else { return status }

            let channelCount = min(buffers.count, maxChannels)
            guard channelCount > 0 else { return noErr }
            var s = state.pointee
            let slope = 1 - 1 / max(1, s.ratio)
            let knee: Float = 6
            var maxReduction: Float = 0

            for f in 0..<frames {
                // Stereo-linked peak detector
                var detector: Float = 0
                for c in 0..<channelCount {
                    let v = abs(buffers[c].mData!.assumingMemoryBound(to: Float.self)[f])
                    if v > detector { detector = v }
                }
                let coef = detector > s.envelope ? s.attackCoef : s.releaseCoef
                s.envelope = coef * s.envelope + (1 - coef) * detector

                // Soft-knee gain computer
                let level = 20 * log10f(max(s.envelope, 1e-9))
                let over = level - s.threshold
                var reduction: Float = 0
                if 2 * over >= knee {
                    reduction = slope * over
                } else if 2 * over > -knee {
                    let x = over + knee / 2
                    reduction = slope * x * x / (2 * knee)
                }
                if reduction > maxReduction { maxReduction = reduction }

                let gain = powf(10, (s.makeup - reduction) / 20)
                for c in 0..<channelCount {
                    let p = buffers[c].mData!.assumingMemoryBound(to: Float.self)
                    p[f] *= gain
                }
            }
            state.pointee.envelope = s.envelope
            if maxReduction > state.pointee.gainReductionPeak { state.pointee.gainReductionPeak = maxReduction }
            return noErr
        }
    }
}

// MARK: - Gain reduction meter

/// Orange bar that grows from the right as the audio is turned down (0 to −range dB).
final class GainReductionMeter: NSView {
    private var shown: Float = 0
    private var lastUpdate = ProcessInfo.processInfo.systemUptime
    private let range: Float
    /// The scale's tick labels, built once (they never change).
    private let ticks: [(db: Float, text: NSAttributedString, width: CGFloat)]

    /// range: full-scale reduction in dB. Compressor uses 20, limiter 10.
    init(range: Float = 20) {
        self.range = range
        let values: [Float] = range <= 10 ? [0, 1, 3, 6, 10] : (range <= 20 ? [0, 3, 6, 10, 20] : [0, 10, 20, 30, 40])
        self.ticks = values.map { db in
            let text = NSAttributedString(string: db == 0 ? "0" : "-\(Int(db))", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor])
            return (db, text, text.size().width)
        }
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func update(reduction: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = Float(min(0.2, now - lastUpdate))
        lastUpdate = now
        // Snap to deeper reduction, ease back out (≈30 dB/s) so it's readable.
        let before = shown
        shown = reduction >= shown ? reduction : max(reduction, shown - 30 * dt)
        if shown != before { needsDisplay = true }      // at rest (no reduction) there's nothing to redraw
    }

    override func draw(_ dirtyRect: NSRect) {
        let bar = NSRect(x: 0, y: 2, width: bounds.width - 48, height: 10)
        NSColor(white: 0.1, alpha: 1).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()

        let fraction = CGFloat(min(shown, range) / range)
        if fraction > 0 {
            NSColor.systemOrange.setFill()
            NSRect(x: bar.maxX - fraction * bar.width, y: bar.minY + 1,
                   width: fraction * bar.width, height: bar.height - 2).fill()
        }

        // Scale ticks: 0 at the right, −20 at the left
        for tick in ticks {
            let x = bar.maxX - CGFloat(tick.db / range) * bar.width
            NSColor(white: 1, alpha: 0.25).setFill()
            NSRect(x: x - 0.5, y: bar.maxY + 1, width: 1, height: 3).fill()
            tick.text.draw(at: NSPoint(x: min(max(0, x - tick.width / 2), bar.maxX - tick.width), y: bar.maxY + 3))
        }

        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.labelColor]
        let text = NSAttributedString(string: shown < 0.05 ? "0.0 dB" : String(format: "-%.1f dB", shown),
                                      attributes: valueAttrs)
        text.draw(at: NSPoint(x: bounds.width - text.size().width, y: 0))
    }
}

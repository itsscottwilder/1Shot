// DeEsser — tames harsh "s" / "sh" sounds. Splits off the high frequencies above the chosen
// Frequency, and only when they spike does it turn that band down. Everything below is
// untouched. Runs as an in-app Audio Unit after the compressor.

import Foundation
import AVFoundation

private struct DeEsserState {
    // Settings
    var frequency: Float = 6000
    var threshold: Float = 0.1             // linear level of the "s" band where reduction starts
    var active = false
    // High-pass biquad (RBJ), shared coefficients
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var designedFor: Float = 0             // frequency the coefficients were made for
    var sampleRate: Float = 48_000
    // Detector
    var envelope: Float = 0
    var attackCoef: Float = 0
    var releaseCoef: Float = 0
    var minGainSinceRead: Float = 1
}

final class DeEsserAU: AUAudioUnit {
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x74706473,          // 'tpds'
        componentManufacturer: 0x54435059,     // 'TCPY'
        componentFlags: 0, componentFlagsMask: 0)

    static let registered: Bool = {
        AUAudioUnit.registerSubclass(DeEsserAU.self, as: componentDescription,
                                     name: "1Shot: De-esser", version: 1)
        return true
    }()

    private static let maxFrames = 8192
    private static let maxChannels = 8

    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!
    private let state = UnsafeMutablePointer<DeEsserState>.allocate(capacity: 1)
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: DeEsserAU.maxFrames * DeEsserAU.maxChannels)
    /// Filter memory per channel: x1, x2, y1, y2 (no allocation on the audio thread).
    private let memory = UnsafeMutablePointer<Float>.allocate(capacity: 4 * DeEsserAU.maxChannels)
    private let high = UnsafeMutablePointer<Float>.allocate(capacity: DeEsserAU.maxChannels)

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        state.initialize(to: DeEsserState())
        scratch.initialize(repeating: 0, count: Self.maxFrames * Self.maxChannels)
        memory.initialize(repeating: 0, count: 4 * Self.maxChannels)
        high.initialize(repeating: 0, count: Self.maxChannels)
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
        memory.deallocate()
        high.deallocate()
    }

    override var inputBusses: AUAudioUnitBusArray { inputs }
    override var outputBusses: AUAudioUnitBusArray { outputs }
    override var canProcessInPlace: Bool { true }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let rate = Float(outputs[0].format.sampleRate)
        state.pointee.sampleRate = rate
        state.pointee.attackCoef = expf(-1 / (0.001 * rate))    // 1 ms: catch the "s" right away
        state.pointee.releaseCoef = expf(-1 / (0.060 * rate))   // 60 ms: let go quickly
        state.pointee.envelope = 0
        state.pointee.designedFor = 0                             // force a filter redesign
        memory.update(repeating: 0, count: 4 * Self.maxChannels)
    }

    /// frequency in Hz (where the "s" band starts); amount 0…100 (0 = off).
    func setParameters(frequency: Double, amount: Double) {
        state.pointee.frequency = Float(frequency)
        state.pointee.active = amount > 0.5
        // More amount = lower threshold for the high band (−20 dB down to −50 dB).
        let thresholdDB = -20 - 30 * Float(min(100, max(0, amount)) / 100)
        state.pointee.threshold = powf(10, thresholdDB / 20)
    }

    func takeGainReduction() -> Float {
        let g = state.pointee.minGainSinceRead
        state.pointee.minGainSinceRead = 1
        return g >= 0.9999 ? 0 : -20 * log10f(max(g, 1e-6))
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let state = self.state
        let scratch = self.scratch
        let memory = self.memory
        let high = self.high
        let maxFrames = Self.maxFrames
        let maxChannels = Self.maxChannels
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pull = pullInputBlock else { return kAudioUnitErr_NoConnection }
            let frames = Int(frameCount)
            guard frames <= maxFrames else { return kAudioUnitErr_TooManyFramesToProcess }

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

            let channels = min(buffers.count, maxChannels)
            guard channels > 0, state.pointee.active else { return noErr }

            // (Re)design the high-pass filter when the Frequency changes.
            if state.pointee.designedFor != state.pointee.frequency {
                let f = min(state.pointee.frequency, state.pointee.sampleRate * 0.45)
                let w0 = 2 * Float.pi * f / state.pointee.sampleRate
                let alpha = sinf(w0) / (2 * 0.707)
                let cosw = cosf(w0)
                let a0 = 1 + alpha
                state.pointee.b0 = ((1 + cosw) / 2) / a0
                state.pointee.b1 = (-(1 + cosw)) / a0
                state.pointee.b2 = ((1 + cosw) / 2) / a0
                state.pointee.a1 = (-2 * cosw) / a0
                state.pointee.a2 = (1 - alpha) / a0
                state.pointee.designedFor = state.pointee.frequency
            }

            let b0 = state.pointee.b0, b1 = state.pointee.b1, b2 = state.pointee.b2
            let a1 = state.pointee.a1, a2 = state.pointee.a2
            let threshold = state.pointee.threshold
            let attack = state.pointee.attackCoef, release = state.pointee.releaseCoef
            var envelope = state.pointee.envelope
            var minGain = state.pointee.minGainSinceRead

            for f in 0..<frames {
                // Split each channel: high band (above Frequency) via the biquad.
                var detector: Float = 0
                for c in 0..<channels {
                    let m = memory + c * 4                   // x1, x2, y1, y2
                    let x = buffers[c].mData!.assumingMemoryBound(to: Float.self)[f]
                    let y = b0 * x + b1 * m[0] + b2 * m[1] - a1 * m[2] - a2 * m[3]
                    m[1] = m[0]; m[0] = x
                    m[3] = m[2]; m[2] = y
                    high[c] = y
                    let a = abs(y)
                    if a > detector { detector = a }
                }
                let coef = detector > envelope ? attack : release
                envelope = coef * envelope + (1 - coef) * detector

                // Over the threshold: turn the high band down (about 4:1), at most 12 dB.
                var target: Float = 1
                if envelope > threshold {
                    let overDB = 20 * log10f(envelope / threshold)
                    target = powf(10, -min(12, overDB * 0.75) / 20)
                }
                if target < minGain { minGain = target }

                // Output = low band + reduced high band  (low = input − high).
                for c in 0..<channels {
                    let p = buffers[c].mData!.assumingMemoryBound(to: Float.self)
                    p[f] = (p[f] - high[c]) + high[c] * target
                }
            }
            state.pointee.envelope = envelope
            state.pointee.minGainSinceRead = minGain
            return noErr
        }
    }
}

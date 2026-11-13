// Gate — a speech-friendly noise gate (threshold + range) running as an in-app Audio Unit.
// Turns quiet gaps between words down by `range` dB; opens fast, holds briefly, closes smoothly.

import Foundation
import AVFoundation

private struct GateState {
    var openLevel: Float = 0.00316        // linear threshold (−50 dB)
    var closeLevel: Float = 0.00224       // 3 dB below, so it doesn't chatter
    var floorGain: Float = 1              // linear gain when closed (1 = no effect)
    var envelope: Float = 0
    var gain: Float = 1
    var isOpen = true
    var holdLeft = 0
    var holdSamples = 2400                // 50 ms at 48 kHz
    var envelopeFall: Float = 0           // detector decay
    var openCoef: Float = 0               // gain ramp up (fast)
    var closeCoef: Float = 0              // gain ramp down (smooth)
    var minGainSinceRead: Float = 1
}

final class GateAU: AUAudioUnit {
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x74706774,          // 'tpgt'
        componentManufacturer: 0x54435059,     // 'TCPY'
        componentFlags: 0, componentFlagsMask: 0)

    static let registered: Bool = {
        AUAudioUnit.registerSubclass(GateAU.self, as: componentDescription,
                                     name: "1Shot: Noise Gate", version: 1)
        return true
    }()

    private static let maxFrames = 8192
    private static let maxChannels = 8

    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!
    private let state = UnsafeMutablePointer<GateState>.allocate(capacity: 1)
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: GateAU.maxFrames * GateAU.maxChannels)

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        state.initialize(to: GateState())
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
        state.pointee.envelopeFall = expf(-1 / (0.020 * rate))   // detector: 20 ms decay
        state.pointee.openCoef = expf(-1 / (0.002 * rate))       // open in ~2 ms
        state.pointee.closeCoef = expf(-1 / (0.120 * rate))      // close over ~120 ms
        state.pointee.holdSamples = Int(0.050 * rate)            // stay open 50 ms after speech
        state.pointee.envelope = 0
        state.pointee.gain = 1
        state.pointee.isOpen = true
        state.pointee.holdLeft = 0
    }

    /// threshold in dBFS, range in dB (0 = no effect, −40 = very quiet gaps).
    func setParameters(threshold: Double, range: Double) {
        state.pointee.openLevel = powf(10, Float(threshold) / 20)
        state.pointee.closeLevel = powf(10, Float(threshold - 3) / 20)
        state.pointee.floorGain = powf(10, Float(min(0, range)) / 20)
    }

    /// Largest gain reduction (dB, positive) since the last call.
    func takeGainReduction() -> Float {
        let g = state.pointee.minGainSinceRead
        state.pointee.minGainSinceRead = 1
        return g >= 0.9999 ? 0 : -20 * log10f(max(g, 1e-6))
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
            guard channels > 0 else { return noErr }
            var s = state.pointee
            var minGain = s.minGainSinceRead

            for f in 0..<frames {
                // Stereo-linked peak detector with a short decay
                var detector: Float = 0
                for c in 0..<channels {
                    let v = abs(buffers[c].mData!.assumingMemoryBound(to: Float.self)[f])
                    if v > detector { detector = v }
                }
                s.envelope = max(detector, s.envelope * s.envelopeFall)

                // Open above the threshold; close (after a short hold) 3 dB below it.
                if s.envelope >= s.openLevel {
                    s.isOpen = true
                    s.holdLeft = s.holdSamples
                } else if s.envelope < s.closeLevel {
                    if s.holdLeft > 0 { s.holdLeft -= 1 } else { s.isOpen = false }
                }

                let target: Float = s.isOpen ? 1 : s.floorGain
                let coef = target > s.gain ? s.openCoef : s.closeCoef
                s.gain = coef * s.gain + (1 - coef) * target
                if s.gain < minGain { minGain = s.gain }

                for c in 0..<channels {
                    buffers[c].mData!.assumingMemoryBound(to: Float.self)[f] *= s.gain
                }
            }
            state.pointee.envelope = s.envelope
            state.pointee.gain = s.gain
            state.pointee.isOpen = s.isOpen
            state.pointee.holdLeft = s.holdLeft
            state.pointee.minGainSinceRead = minGain
            return noErr
        }
    }
}

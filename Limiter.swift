// Limiter — brick-wall look-ahead limiter with a fixed −0.1 dBFS ceiling and an input
// (drive) control. Runs as an in-app Audio Unit at the very end of the audio chain.

import Foundation
import AVFoundation

private struct LimiterState {
    var inputGain: Float = 1          // linear
    var ceiling: Float = powf(10, -0.1 / 20)
    var gain: Float = 1               // current gain applied
    var attackCoef: Float = 0
    var releaseCoef: Float = 0
    var lookahead = 72                // samples of delay
    var position = 0
    var minGainSinceRead: Float = 1
}

final class LimiterAU: AUAudioUnit {
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x74706C6D,          // 'tplm'
        componentManufacturer: 0x54435059,     // 'TCPY'
        componentFlags: 0, componentFlagsMask: 0)

    static let registered: Bool = {
        AUAudioUnit.registerSubclass(LimiterAU.self, as: componentDescription,
                                     name: "1Shot: Limiter", version: 1)
        return true
    }()

    private static let maxFrames = 8192
    private static let maxChannels = 8
    private static let maxDelay = 1024        // ring size limit (lookahead + 1)
    private static let lookaheadSeconds = 0.0015

    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!
    private let state = UnsafeMutablePointer<LimiterState>.allocate(capacity: 1)
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: LimiterAU.maxFrames * LimiterAU.maxChannels)
    private let delay = UnsafeMutablePointer<Float>.allocate(capacity: LimiterAU.maxDelay * LimiterAU.maxChannels)
    private let required = UnsafeMutablePointer<Float>.allocate(capacity: LimiterAU.maxDelay)

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        state.initialize(to: LimiterState())
        scratch.initialize(repeating: 0, count: Self.maxFrames * Self.maxChannels)
        delay.initialize(repeating: 0, count: Self.maxDelay * Self.maxChannels)
        required.initialize(repeating: 1, count: Self.maxDelay)
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
        delay.deallocate()
        required.deallocate()
    }

    override var inputBusses: AUAudioUnitBusArray { inputs }
    override var outputBusses: AUAudioUnitBusArray { outputs }
    override var canProcessInPlace: Bool { true }

    /// The look-ahead delay — the app's sync compensation reads this.
    override var latency: TimeInterval {
        Double(state.pointee.lookahead) / max(1, outputs[0].format.sampleRate)
    }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let rate = Float(outputs[0].format.sampleRate)
        let look = min(Self.maxDelay - 1, max(1, Int((Self.lookaheadSeconds * Double(rate)).rounded())))
        state.pointee.lookahead = look
        state.pointee.attackCoef = expf(-1 / (Float(look) / 4))   // settles well within the look-ahead
        state.pointee.releaseCoef = expf(-1 / (0.100 * rate))      // 100 ms recovery
        state.pointee.gain = 1
        state.pointee.position = 0
        delay.update(repeating: 0, count: Self.maxDelay * Self.maxChannels)
        required.update(repeating: 1, count: Self.maxDelay)
    }

    func setInputGain(dB: Double) {
        state.pointee.inputGain = powf(10, Float(dB) / 20)
    }

    /// Largest gain reduction (dB, positive) since the last call.
    func takeGainReduction() -> Float {
        let g = state.pointee.minGainSinceRead
        state.pointee.minGainSinceRead = 1
        return g >= 1 ? 0 : -20 * log10f(max(g, 1e-6))
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let state = self.state
        let scratch = self.scratch
        let delay = self.delay
        let required = self.required
        let maxFrames = Self.maxFrames
        let maxChannels = Self.maxChannels
        let maxDelay = Self.maxDelay
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
            let ring = s.lookahead + 1                // delay of `lookahead` samples
            var minGain: Float = s.minGainSinceRead

            for f in 0..<frames {
                // 1. Drive the input, store it in the delay line, note the gain this sample needs.
                var peak: Float = 0
                for c in 0..<channels {
                    let p = buffers[c].mData!.assumingMemoryBound(to: Float.self)
                    let x = p[f] * s.inputGain
                    delay[c * maxDelay + s.position] = x
                    let a = abs(x)
                    if a > peak { peak = a }
                }
                required[s.position] = peak > s.ceiling ? s.ceiling / peak : 1

                // 2. Lowest gain needed anywhere in the look-ahead window.
                var target: Float = 1
                for k in 0..<ring where required[k] < target { target = required[k] }

                // 3. Ease down fast (within the look-ahead), recover slowly.
                let coef = target < s.gain ? s.attackCoef : s.releaseCoef
                s.gain = coef * s.gain + (1 - coef) * target
                if s.gain < minGain { minGain = s.gain }

                // 4. Output the delayed sample; hard clamp guarantees the ceiling.
                let readPos = (s.position + 1) % ring
                for c in 0..<channels {
                    let p = buffers[c].mData!.assumingMemoryBound(to: Float.self)
                    let y = delay[c * maxDelay + readPos] * s.gain
                    p[f] = min(s.ceiling, max(-s.ceiling, y))
                }
                s.position = readPos
            }
            state.pointee.gain = s.gain
            state.pointee.position = s.position
            state.pointee.minGainSinceRead = minGain
            return noErr
        }
    }
}

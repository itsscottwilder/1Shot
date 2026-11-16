// AudioRack — plays the video's audio through up to 5 Audio Unit effects, in order.
//
// How it works: the AVPlayer keeps showing the picture, but its own sound is silenced.
// The audio track is read from the file (AVAssetReader), fed into a normal AVAudioEngine
// (player → effect 1 → … → effect 5 → speakers), and kept in sync with the video:
// it restarts from the video's position on play, after any scrub/seek, and if it ever
// drifts more than about a tenth of a second.

import AVFoundation

enum RackError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let m): return m }
    }
}

// MARK: - Reads audio from the file and schedules it on the player node

/// Bounds queued audio without requiring every player-node callback to run when playback stops.
private final class AudioBufferSlots {
    private let condition = NSCondition()
    private var outstanding = 0
    private var cancelled = false
    private let limit = 32

    func reserve() -> Bool {
        condition.lock(); defer { condition.unlock() }
        while outstanding >= limit && !cancelled { condition.wait() }
        guard !cancelled else { return false }
        outstanding += 1
        return true
    }

    func finish() {
        condition.lock(); defer { condition.unlock() }
        outstanding = max(0, outstanding - 1)
        condition.signal()
    }

    func cancel() {
        condition.lock(); defer { condition.unlock() }
        cancelled = true
        condition.broadcast()
    }
}

final class AudioFeeder {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let node: AVAudioPlayerNode
    private let format: AVAudioFormat
    private let slots = AudioBufferSlots()
    private let queue = DispatchQueue(label: "1Shot.audioFeeder")
    private let lock = NSLock()
    private var _cancelled = false
    var onBuffer: (() -> Void)?
    /// Fade-out end time (media seconds); audio fades to silence over the 0.5 s before it.
    var fadeEnd: Double?

    private var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    init?(asset: AVAsset, track: AVAssetTrack, start: Double, node: AVAudioPlayerNode, format: AVAudioFormat) {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: Self.readerSettings(for: format))
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, start), preferredTimescale: 48000),
                                       duration: .positiveInfinity)
        guard reader.startReading() else { return nil }
        self.reader = reader
        self.output = output
        self.node = node
        self.format = format
    }

    /// Queue a few buffers right away so sound starts the instant the node plays.
    func prime(buffers: Int) {
        for _ in 0..<buffers {
            guard slots.reserve() else { break }
            if scheduleNext() == nil { slots.finish(); break }
        }
    }

    /// Keep feeding on a background queue until the end of the track or cancel().
    func start() {
        queue.async { [self] in
            while !cancelled {
                guard slots.reserve() else { break }
                if cancelled || scheduleNext() == nil { slots.finish(); break }
            }
            reader.cancelReading()
        }
    }

    func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
        slots.cancel()   // wake the loop even if the player discarded queued buffers
    }

    private func scheduleNext() -> Int? {
        while true {
            guard let sample = output.copyNextSampleBuffer() else { return nil }
            guard let buffer = Self.pcmBuffer(from: sample, format: format) else { continue }
            if let fadeEnd {
                Self.applyFadeOut(to: buffer, startingAt: CMSampleBufferGetPresentationTimeStamp(sample).seconds,
                                  fadeEnd: fadeEnd)
            }
            node.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [slots] _ in
                slots.finish()
            }
            onBuffer?()
            return Int(buffer.frameLength)
        }
    }

    /// Fades samples to silence over the 0.5 s before `fadeEnd` (smooth, ear-friendly curve).
    static func applyFadeOut(to buffer: AVAudioPCMBuffer, startingAt start: Double, fadeEnd: Double,
                             duration: Double = 0.5) {
        guard let data = buffer.floatChannelData, start.isFinite else { return }
        let rate = buffer.format.sampleRate
        let frames = Int(buffer.frameLength)
        let fadeStart = fadeEnd - duration
        guard start + Double(frames) / rate > fadeStart else { return }   // nothing to fade here
        for i in 0..<frames {
            let t = start + Double(i) / rate
            guard t >= fadeStart else { continue }
            let g = Float(max(0, (fadeEnd - t) / duration))
            let gain = g * g
            for c in 0..<Int(buffer.format.channelCount) { data[c][i] *= gain }
        }
    }

    static func readerSettings(for format: AVAudioFormat) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount)
        ]
    }

    /// Interleaved float samples from the reader → the engine's standard (split-channel) buffer.
    static func pcmBuffer(from sample: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = CMSampleBufferGetNumSamples(sample)
        let channels = Int(format.channelCount)
        guard frames > 0, let block = CMSampleBufferGetDataBuffer(sample) else { return nil }

        var interleaved = [Float](repeating: 0, count: frames * channels)
        let byteCount = min(CMBlockBufferGetDataLength(block), interleaved.count * MemoryLayout<Float>.size)
        let status = interleaved.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: raw.baseAddress!)
        }
        guard status == noErr,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let dst = buffer.floatChannelData else { return nil }

        let validFrames = byteCount / (MemoryLayout<Float>.size * channels)
        buffer.frameLength = AVAudioFrameCount(validFrames)
        for c in 0..<channels {
            let out = dst[c]
            var i = c
            for f in 0..<validFrames {
                out[f] = interleaved[i]
                i += channels
            }
        }
        return buffer
    }
}

// MARK: - The rack

final class AudioRack {
    static let slotCount = 5

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var effects = [AVAudioUnit?](repeating: nil, count: AudioRack.slotCount)

    // Apple's voice isolation (the engine behind Final Cut Pro's Voice Isolation),
    // as a dedicated first stage ahead of the five slots.
    enum IsolationMode: Int { case off = 0, voice, highQuality }
    private(set) var isolationMode: IsolationMode = .off
    private var isolationUnit: AVAudioUnit?
    private var isolationAttached = false

    // Apple's high-pass filter, right after isolation. 0 Hz = off (out of the chain).
    private let highPassUnit = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_HighPassFilter,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    private var highPassAttached = false
    private(set) var highPassFrequency: Double = 0

    // Noise gate, after the high pass and before the compressor. Range 0 dB = off.
    private var gate: AVAudioUnit?
    private var gateAttached = false
    private(set) var gateThreshold: Double = -50
    private(set) var gateRange: Double = 0
    private var gateOn: Bool { gate != nil && gateRange < -0.5 && !bypassed.contains(.gate) }

    // Built-in compressor, right after the gate. Ratio 1:1 = off (out of the chain).
    private var compressor: AVAudioUnit?
    private var compressorAttached = false
    private(set) var compressorThreshold: Double = 0
    private(set) var compressorRatio: Double = 1
    private(set) var compressorMakeup: Double = 0
    private var compressorOn: Bool { compressor != nil && compressorRatio > 1.01 && !bypassed.contains(.compressor) }

    // De-esser, after the compressor. Amount 0 = off (out of the chain).
    private var deEsser: AVAudioUnit?
    private var deEsserAttached = false
    private(set) var deEsserFrequency: Double = 4500
    private(set) var deEsserAmount: Double = 0
    private var deEsserOn: Bool { deEsser != nil && deEsserAmount > 0.5 && !bypassed.contains(.deEsser) }

    /// Sections switched off by clicking their title (settings kept).
    enum Stage: Hashable { case isolation, gate, compressor, deEsser, limiter }
    private(set) var bypassed: Set<Stage> = []
    private var isolationActive: Bool { isolationMode != .off && !bypassed.contains(.isolation) }

    func setBypassed(_ stage: Stage, _ off: Bool) {
        guard !isExporting, bypassed.contains(stage) != off else { return }
        if off { bypassed.insert(stage) } else { bypassed.remove(stage) }
        rebuildChain()
    }

    // Brick-wall limiter, always last in the chain (−0.1 dBFS ceiling).
    private var limiter: AVAudioUnit?
    private var limiterAttached = false
    private(set) var limiterInputGain: Double = 0

    /// Everything audio currently passes through, in order.
    private var activeUnits: [AVAudioUnit] {
        var units: [AVAudioUnit] = []
        if isolationActive, let iso = isolationUnit { units.append(iso) }
        if highPassFrequency > 0 { units.append(highPassUnit) }
        if gateOn, let g = gate { units.append(g) }
        if compressorOn, let comp = compressor { units.append(comp) }
        if deEsserOn, let ds = deEsser { units.append(ds) }
        units += effects.compactMap { $0 }
        if let limiter, !bypassed.contains(.limiter) { units.append(limiter) }   // last, so nothing can exceed the ceiling
        return units
    }
    private var format: AVAudioFormat?

    private var asset: AVAsset?
    private var track: AVAssetTrack?
    private weak var player: AVPlayer?
    private var feeder: AudioFeeder?
    private var startOffset: Double = 0
    private var appliedLead: Double = 0     // plugin delay we're compensating for right now
    private var audioRunning = false

    private var observations: [NSKeyValueObservation] = []
    private var itemTokens: [NSObjectProtocol] = []
    private var engineToken: NSObjectProtocol?
    private var driftTimer: Timer?

    // Shown in the drawer's status line.
    private(set) var formatDescription: String?
    private(set) var processedBlocks = 0
    private(set) var lastError: String?

    // Output meter readings (written by the meter tap, read by the drawer).
    private let meterLock = NSLock()
    private var meterPeak: [Float] = [0, 0]
    private var meterRMS: [Float] = [0, 0]
    private var meterStamp: TimeInterval = 0
    private var liveVolume: Float = 1          // player volume, so the LUFS meter reads the mix itself
    /// LUFS of what's playing (after every stage), for the Loudness meters.
    let loudness = LUFSMeter(sampleRate: 48_000)
    private(set) var isExporting = false

    /// Audio fade-out end (media seconds), matching the picture's fade to black. nil = no fade.
    private(set) var fadeOutEnd: Double?

    func setFadeOut(end: Double?) {
        guard end != fadeOutEnd else { return }
        fadeOutEnd = end
        // Apply right away if playing (the new feeder picks up the fade).
        if !isExporting, audioRunning, let player {
            restartAudio(at: player.currentTime().seconds)
        }
    }
    var isEngineReady: Bool { engine.isRunning }

    /// Combined processing delay of the active plugins (look-ahead limiters etc.), in seconds.
    var totalLatency: Double {
        activeUnits
            .filter { !$0.auAudioUnit.shouldBypassEffect }
            .reduce(0) { $0 + $1.auAudioUnit.latency }
    }

    init() {
        engine.attach(playerNode)
        _ = CompressorAU.registered
        _ = LimiterAU.registered
        _ = GateAU.registered
        _ = DeEsserAU.registered
        AVAudioUnit.instantiate(with: DeEsserAU.componentDescription, options: []) { [weak self] unit, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let unit else {
                    NSLog("1Shot: de-esser failed to load: \(String(describing: error))")
                    return
                }
                self.deEsser = unit
                self.applyDeEsserParameters()
                if self.deEsserOn { self.rebuildChain() }
            }
        }
        AVAudioUnit.instantiate(with: GateAU.componentDescription, options: []) { [weak self] unit, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let unit else {
                    NSLog("1Shot: noise gate failed to load: \(String(describing: error))")
                    return
                }
                self.gate = unit
                self.applyGateParameters()
                if self.gateOn { self.rebuildChain() }
            }
        }
        AVAudioUnit.instantiate(with: LimiterAU.componentDescription, options: []) { [weak self] unit, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let unit else {
                    NSLog("1Shot: limiter failed to load: \(String(describing: error))")
                    return
                }
                self.limiter = unit
                (unit.auAudioUnit as? LimiterAU)?.setInputGain(dB: self.limiterInputGain)
                NSLog("1Shot: limiter loaded (ceiling −0.1 dBFS)")
                self.rebuildChain()
            }
        }
        AVAudioUnit.instantiate(with: CompressorAU.componentDescription, options: []) { [weak self] unit, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let unit else {
                    NSLog("1Shot: compressor failed to load: \(String(describing: error))")
                    return
                }
                self.compressor = unit
                self.applyCompressorParameters()
                if self.compressorOn { self.rebuildChain() }
            }
        }
        engineToken = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                // e.g. headphones plugged in — rebuild and pick up where the video is.
                NSLog("1Shot: audio device changed, restarting audio")
                guard let self, !self.isExporting else { return }
                self.rebuildChain()
            }
    }

    // MARK: Connecting to a video (main thread)

    func attach(to player: AVPlayer, item: AVPlayerItem, asset: AVAsset,
                track: AVAssetTrack?, sampleRate: Double) {
        detach()
        guard let track else {
            formatDescription = nil
            lastError = "This video has no audio track"
            return
        }
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
        format = fmt
        self.asset = asset
        self.track = track
        self.player = player
        formatDescription = String(format: "%.1f kHz · 2 ch", sampleRate / 1000)
        loudness.reset(sampleRate: sampleRate)       // a new clip (or a new edit) starts Integrated over

        // Silence the video player's own sound — we play it through the effects instead.
        let params = AVMutableAudioMixInputParameters(track: track)
        params.setVolume(0, at: .zero)
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        item.audioMix = mix

        rebuildChain()

        let onMain: (@escaping () -> Void) -> Void = { work in DispatchQueue.main.async(execute: work) }
        observations = [
            player.observe(\.timeControlStatus) { [weak self] _, _ in onMain { self?.syncState() } },
            player.observe(\.rate) { [weak self] _, _ in onMain { self?.syncState() } },
            player.observe(\.volume) { [weak self] _, _ in onMain { self?.updateVolume() } },
            player.observe(\.isMuted) { [weak self] _, _ in onMain { self?.updateVolume() } }
        ]
        itemTokens = [
            NotificationCenter.default.addObserver(forName: AVPlayerItem.timeJumpedNotification,
                                                   object: item, queue: .main) { [weak self] _ in
                self?.timeJumped()
            }
        ]
        driftTimer = Timer.everyMode(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkDrift()
        }
        updateVolume()
        syncState()
        NSLog("1Shot: audio attached (\(formatDescription ?? "?"))")
    }

    // MARK: Waveform (Sound Design tab timeline, 3.0.0)

    /// Downsampled peak envelope of the whole track (0...1, loudest moment = 1), `count` buckets
    /// evenly spaced across the clip's full duration. Reads the file with its own AVAssetReader
    /// (independent of playback), on a background queue; calls back on the main queue.
    /// The A1 lane's waveform pyramid (3.2), built off the main thread.
    func makeWaveform(completion: @escaping (WaveformData?) -> Void) {
        guard let asset, let track else { completion(nil); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let data = WaveformData.build(asset: asset, track: track)
            DispatchQueue.main.async { completion(data) }
        }
    }

    func extractWaveformPeaks(count: Int, completion: @escaping ([Float]) -> Void) {
        guard count > 0, let asset, let track else { completion([]); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let peaks = Self.readPeaks(asset: asset, track: track, count: count)
            DispatchQueue.main.async { completion(peaks) }
        }
    }

    private static func readPeaks(asset: AVAsset, track: AVAssetTrack, count: Int) -> [Float] {
        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        let durationSeconds = max(0.001, asset.duration.seconds)
        var buckets = [Float](repeating: 0, count: count)
        while let sample = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time.isFinite, let blockBuffer = CMSampleBufferGetDataBuffer(sample) else { continue }
            let bucket = min(count - 1, max(0, Int(time / durationSeconds * Double(count))))
            let length = CMBlockBufferGetDataLength(blockBuffer)
            guard length >= MemoryLayout<Float32>.size else { continue }
            var bytes = [UInt8](repeating: 0, count: length)
            let status = bytes.withUnsafeMutableBytes { ptr in
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: ptr.baseAddress!)
            }
            guard status == noErr else { continue }
            var peak: Float = 0
            bytes.withUnsafeBytes { raw in
                let floats = raw.bindMemory(to: Float32.self)
                for v in floats { peak = max(peak, abs(v)) }
            }
            if peak > buckets[bucket] { buckets[bucket] = peak }
        }
        reader.cancelReading()

        // Normalize so the loudest moment reaches 1.0 — a quiet voice clip shouldn't look flat.
        let maxPeak = buckets.max() ?? 0
        guard maxPeak > 0.0001 else { return buckets }
        return buckets.map { min(1, $0 / maxPeak) }
    }

    func detach() {
        stopAudio()
        observations = []
        itemTokens.forEach { NotificationCenter.default.removeObserver($0) }
        itemTokens = []
        driftTimer?.invalidate()
        driftTimer = nil
        player = nil
        asset = nil
        track = nil
    }

    // MARK: Slot management (main thread)

    /// Puts `unit` into slot `index` (nil empties the slot).
    func setUnit(_ unit: AVAudioUnit?, at index: Int) throws {
        guard !isExporting else { throw RackError.message("Wait for the export to finish.") }
        let old = effects[index]
        if let old { engine.detach(old) }
        if let unit { engine.attach(unit) }
        effects[index] = unit
        rebuildChain()

        if let unit, let err = lastError, format != nil {
            // Couldn't run with the new plugin — put things back the way they were.
            engine.detach(unit)
            if let old { engine.attach(old) }
            effects[index] = old
            rebuildChain()
            throw RackError.message(err)
        }
    }

    /// Wires player → effects (in slot order) → speakers, then resumes in sync with the video.
    private func rebuildChain() {
        guard let format else { return }
        let wasRunning = audioRunning
        stopAudio()
        engine.stop()

        connectChain(format: format)
        engine.prepare()
        do {
            try engine.start()
            lastError = nil
            NSLog("1Shot: audio engine running with \(activeUnits.count) stage(s), isolation: \(isolationMode), limiter last: \(activeUnits.last === limiter && limiter != nil)")
            installMeterTap()
        } catch {
            lastError = "audio output failed to start (\((error as NSError).code))"
            NSLog("1Shot: engine start failed: \(error)")
        }
        updateVolume()
        if wasRunning { syncState() }
    }

    private func connectChain(format: AVAudioFormat) {
        engine.disconnectNodeOutput(playerNode)
        for case let unit? in effects { engine.disconnectNodeOutput(unit) }

        // The high-pass filter is only in the engine while it's switched on.
        if highPassAttached { engine.disconnectNodeOutput(highPassUnit) }
        let wantHighPass = highPassFrequency > 0
        if wantHighPass && !highPassAttached {
            engine.attach(highPassUnit)
            highPassAttached = true
        } else if !wantHighPass && highPassAttached {
            engine.detach(highPassUnit)
            highPassAttached = false
        }
        if wantHighPass { applyHighPassParameters() }

        // The limiter joins the engine once it has loaded and then stays.
        if let lim = limiter {
            if limiterAttached { engine.disconnectNodeOutput(lim) }
            else { engine.attach(lim); limiterAttached = true }
        }

        // Same for the gate.
        if let g = gate {
            if gateAttached { engine.disconnectNodeOutput(g) }
            if gateOn && !gateAttached {
                engine.attach(g)
                gateAttached = true
            } else if !gateOn && gateAttached {
                engine.detach(g)
                gateAttached = false
            }
        }

        // Same for the de-esser.
        if let ds = deEsser {
            if deEsserAttached { engine.disconnectNodeOutput(ds) }
            if deEsserOn && !deEsserAttached {
                engine.attach(ds)
                deEsserAttached = true
            } else if !deEsserOn && deEsserAttached {
                engine.detach(ds)
                deEsserAttached = false
            }
        }

        // Same for the compressor.
        if let comp = compressor {
            if compressorAttached { engine.disconnectNodeOutput(comp) }
            if compressorOn && !compressorAttached {
                engine.attach(comp)
                compressorAttached = true
            } else if !compressorOn && compressorAttached {
                engine.detach(comp)
                compressorAttached = false
            }
        }

        // The isolation stage is only in the engine while it's switched on.
        if let iso = isolationUnit {
            if isolationAttached { engine.disconnectNodeOutput(iso) }
            let wanted = isolationActive
            if wanted && !isolationAttached {
                engine.attach(iso)
                isolationAttached = true
            } else if !wanted && isolationAttached {
                engine.detach(iso)
                isolationAttached = false
            }
        }

        var last: AVAudioNode = playerNode
        for unit in activeUnits {
            engine.connect(last, to: unit, format: format)
            last = unit
        }
        engine.connect(last, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
    }

    // MARK: High-pass filter (main thread)

    /// Cutoff in Hz; 0 turns the filter off. Called continuously while dragging.
    func setHighPass(frequency: Double) {
        guard !isExporting else { return }
        let wasOn = highPassFrequency > 0
        highPassFrequency = max(0, frequency)
        let isOn = highPassFrequency > 0
        if isOn { applyHighPassParameters() }
        if isOn != wasOn { rebuildChain() }       // add/remove it from the chain
    }

    private func applyHighPassParameters() {
        let au = highPassUnit.audioUnit
        AudioUnitSetParameter(au, AudioUnitParameterID(kHipassParam_CutoffFrequency), kAudioUnitScope_Global, 0,
                              AudioUnitParameterValue(highPassFrequency), 0)
        AudioUnitSetParameter(au, AudioUnitParameterID(kHipassParam_Resonance), kAudioUnitScope_Global, 0, 0, 0)   // no bump
    }

    // MARK: Noise gate (main thread)

    /// threshold in dBFS; range in dB (0 = off, down to −40). Called while dragging.
    func setGate(threshold: Double, range: Double) {
        guard !isExporting else { return }
        let wasOn = gateOn
        gateThreshold = threshold
        gateRange = min(0, max(-40, range))
        applyGateParameters()
        if gateOn != wasOn { rebuildChain() }
    }

    private func applyGateParameters() {
        (gate?.auAudioUnit as? GateAU)?.setParameters(threshold: gateThreshold, range: gateRange)
    }

    func gateGainReduction() -> Float {
        guard gateOn else { return 0 }
        return (gate?.auAudioUnit as? GateAU)?.takeGainReduction() ?? 0
    }

    // MARK: Compressor (main thread)

    /// Threshold in dBFS, ratio 1…10 (1 = off), make-up gain in dB. Called while dragging.
    func setCompressor(threshold: Double, ratio: Double, makeup: Double) {
        guard !isExporting else { return }
        let wasOn = compressorOn
        compressorThreshold = threshold
        compressorRatio = min(10, max(1, ratio))
        compressorMakeup = makeup
        applyCompressorParameters()
        if compressorOn != wasOn { rebuildChain() }
    }

    private func applyCompressorParameters() {
        (compressor?.auAudioUnit as? CompressorAU)?.setParameters(
            threshold: compressorThreshold, ratio: compressorRatio, makeup: compressorMakeup)
    }

    /// Current gain reduction in dB (positive), for the meter. 0 when the compressor is off.
    func compressorGainReduction() -> Float {
        guard compressorOn else { return 0 }
        return (compressor?.auAudioUnit as? CompressorAU)?.takeGainReduction() ?? 0
    }

    // MARK: De-esser (main thread)

    /// frequency in Hz (start of the "s" band); amount 0…100 (0 = off). Called while dragging.
    func setDeEsser(frequency: Double, amount: Double) {
        guard !isExporting else { return }
        let wasOn = deEsserOn
        deEsserFrequency = frequency
        deEsserAmount = amount
        applyDeEsserParameters()
        if deEsserOn != wasOn { rebuildChain() }
    }

    private func applyDeEsserParameters() {
        (deEsser?.auAudioUnit as? DeEsserAU)?.setParameters(frequency: deEsserFrequency, amount: deEsserAmount)
    }

    func deEsserGainReduction() -> Float {
        guard deEsserOn else { return 0 }
        return (deEsser?.auAudioUnit as? DeEsserAU)?.takeGainReduction() ?? 0
    }

    // MARK: Limiter (main thread)

    /// Drive into the limiter, in dB. The ceiling is fixed at −0.1 dBFS.
    func setLimiter(inputGain: Double) {
        guard !isExporting else { return }
        limiterInputGain = inputGain
        (limiter?.auAudioUnit as? LimiterAU)?.setInputGain(dB: inputGain)
    }

    /// Current limiter gain reduction in dB (positive), for its meter.
    func limiterGainReduction() -> Float {
        (limiter?.auAudioUnit as? LimiterAU)?.takeGainReduction() ?? 0
    }

    // MARK: Output meter

    /// Measures the final mix (after all processing) for the Output meter.
    private func installMeterTap() {
        let mixer = engine.mainMixerNode
        mixer.removeTap(onBus: 0)
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let channels = Int(buffer.format.channelCount)
            guard frames > 0, channels > 0 else { return }
            var peaks: [Float] = [0, 0]
            var rms: [Float] = [0, 0]
            for c in 0..<2 {
                let samples = data[min(c, channels - 1)]
                var peak: Float = 0
                var sum: Float = 0
                for i in 0..<frames {
                    let v = samples[i]
                    let a = abs(v)
                    if a > peak { peak = a }
                    sum += v * v
                }
                peaks[c] = peak
                rms[c] = (sum / Float(frames)).squareRoot()
            }
            self.meterLock.lock()
            self.meterPeak = peaks
            self.meterRMS = rms
            self.meterStamp = ProcessInfo.processInfo.systemUptime
            let volume = self.liveVolume
            self.meterLock.unlock()
            // Loudness of the mix itself, as it will export (the player volume taken back out).
            if volume > 0.05 { self.loudness.process(buffer, gain: 1 / volume) }
        }
    }

    /// Momentary / short-term / integrated LUFS of what's been playing.
    func loudnessReading() -> LUFSMeter.Reading { loudness.reading(staleAfter: 0.3) }

    /// True when the limiter is loaded and switched on (it's last in the chain, so nothing passes −0.1 dBFS).
    var limiterActive: Bool { limiter != nil && !bypassed.contains(.limiter) }

    /// Latest output levels (linear). Silence if nothing has played for a moment.
    func meterReading() -> (peak: [Float], rms: [Float]) {
        meterLock.lock(); defer { meterLock.unlock() }
        if ProcessInfo.processInfo.systemUptime - meterStamp > 0.15 { return ([0, 0], [0, 0]) }
        return (meterPeak, meterRMS)
    }

    // MARK: Voice isolation (main thread)

    /// Isolation amount (wet/dry mix), 0…100. 0 = off (the stage is taken out of the chain).
    private(set) var isolationAmount: Double = 0
    /// true = High Quality Voice model, false = standard Voice model.
    private(set) var isolationHighQuality = true
    private var isolationLoading = false

    /// Called continuously while you drag the Amount slider or flip the Model slider.
    /// `completion` gets an error if Apple's isolation can't be loaded (needs macOS 13+).
    func setIsolation(amount: Double, highQuality: Bool, completion: @escaping (Error?) -> Void) {
        guard !isExporting else {
            completion(RackError.message("Wait for the export to finish."))
            return
        }
        isolationAmount = min(100, max(0, amount))
        isolationHighQuality = highQuality
        let mode: IsolationMode = isolationAmount <= 0 ? .off : (highQuality ? .highQuality : .voice)

        // Already running in this mode: just update the knobs live, no audio interruption.
        if mode != .off, mode == isolationMode, isolationUnit != nil {
            applyIsolationParameters()
            latencyMayHaveChanged()
            completion(nil)
            return
        }
        if mode == .off || isolationUnit != nil {
            applyIsolation(mode)
            completion(nil)
            return
        }
        // First use: load Apple's engine once, then apply whatever the sliders say by then.
        guard !isolationLoading else { completion(nil); return }
        isolationLoading = true
        let desc = AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                             componentSubType: kAudioUnitSubType_AUSoundIsolation,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        AVAudioUnit.instantiate(with: desc, options: []) { [weak self] unit, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isolationLoading = false
                guard let unit else {
                    self.isolationAmount = 0
                    completion(error ?? RackError.message("Apple's voice isolation isn't available on this Mac."))
                    return
                }
                if self.isolationUnit == nil { self.isolationUnit = unit }
                let latest: IsolationMode = self.isolationAmount <= 0 ? .off
                    : (self.isolationHighQuality ? .highQuality : .voice)
                self.applyIsolation(latest)
                completion(nil)
            }
        }
    }

    private func applyIsolationParameters() {
        guard let tree = isolationUnit?.auAudioUnit.parameterTree else { return }
        tree.parameter(withAddress: AUParameterAddress(kAUSoundIsolationParam_WetDryMixPercent))?.value = AUValue(isolationAmount)
        let soundType: Int
        if #available(macOS 15.0, *), isolationHighQuality {
            soundType = kAUSoundIsolationSoundType_HighQualityVoice
        } else {
            soundType = kAUSoundIsolationSoundType_Voice
        }
        tree.parameter(withAddress: AUParameterAddress(kAUSoundIsolationParam_SoundToIsolate))?.value = AUValue(soundType)
    }

    private func applyIsolation(_ mode: IsolationMode) {
        isolationMode = mode
        if mode != .off { applyIsolationParameters() }
        rebuildChain()
    }

    // MARK: Offline rendering for export

    /// Switches the engine to faster-than-real-time rendering using the same plugins
    /// (same settings). Main thread. Always pair with endOfflineRender().
    func beginOfflineRender(maxFrames: AVAudioFrameCount) throws -> AVAudioFormat {
        guard let format else { throw RackError.message("No audio is loaded.") }
        isExporting = true
        stopAudio()
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.stop()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maxFrames)
        connectChain(format: format)
        engine.mainMixerNode.outputVolume = 1      // export at full level, whatever the player volume is
        engine.prepare()
        try engine.start()
        playerNode.play()
        return format
    }

    func scheduleForExport(_ buffer: AVAudioPCMBuffer) {
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }

    func renderForExport(_ frames: AVAudioFrameCount, into buffer: AVAudioPCMBuffer) throws -> AVAudioEngineManualRenderingStatus {
        try engine.renderOffline(frames, to: buffer)
    }

    /// Back to normal live playback. Main thread.
    func endOfflineRender() {
        playerNode.stop()
        engine.stop()
        if engine.isInManualRenderingMode { engine.disableManualRenderingMode() }
        isExporting = false
        rebuildChain()
    }

    // MARK: Keeping sound in step with the picture

    private func syncState() {
        guard !isExporting, let player else { return }
        let shouldPlay = player.timeControlStatus == .playing && abs(player.rate - 1) < 0.01
        if shouldPlay && !audioRunning {
            restartAudio(at: player.currentTime().seconds)
        } else if !shouldPlay && audioRunning {
            stopAudio()
        }
    }

    private func timeJumped() {
        guard !isExporting, audioRunning, let player else { return }
        restartAudio(at: player.currentTime().seconds)
    }

    private func checkDrift() {
        guard !isExporting, audioRunning, let player else { return }
        let videoPos = player.currentTime().seconds

        // A plugin's delay can change (bypass toggled, look-ahead setting changed…).
        if abs(totalLatency - appliedLead) > 0.002 {
            NSLog("1Shot: plugin delay changed to \(String(format: "%.1f", totalLatency * 1000)) ms, re-aligning")
            restartAudio(at: videoPos)
            return
        }

        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else { return }
        // Audio entering the plugin chain should be ahead of the picture by the chain's delay.
        let audioPos = startOffset + Double(playerTime.sampleTime) / playerTime.sampleRate
        let expected = videoPos + appliedLead
        if abs(audioPos - expected) > 0.12 {
            NSLog("1Shot: resyncing audio (off by \(String(format: "%.3f", audioPos - expected))s)")
            restartAudio(at: videoPos)
        }
    }

    /// Call after anything that may change plugin delay (e.g. bypass toggled).
    func latencyMayHaveChanged() {
        guard !isExporting, audioRunning, let player, abs(totalLatency - appliedLead) > 0.002 else { return }
        restartAudio(at: player.currentTime().seconds)
    }

    private func restartAudio(at time: Double) {
        stopAudio()
        guard let asset, let track, let format, engine.isRunning, time.isFinite else { return }
        // Start the audio early by the plugins' processing delay, so what comes OUT
        // of the plugins lines up with the picture.
        let lead = totalLatency
        let audioStart = time + lead
        guard let f = AudioFeeder(asset: asset, track: track, start: audioStart, node: playerNode, format: format) else {
            lastError = "couldn't read the video's audio"
            return
        }
        f.onBuffer = { [weak self] in self?.processedBlocks &+= 1 }
        f.fadeEnd = fadeOutEnd
        feeder = f
        appliedLead = lead
        startOffset = max(0, audioStart)
        f.prime(buffers: 6)
        // Priming reads from the file and takes a moment; the engine can stop meanwhile (e.g. the
        // output device changed). AVAudioPlayerNode.play() raises an Objective-C exception — which
        // Swift can't catch, so the app would crash — if the engine isn't running or the player
        // isn't connected. Check right before, and back off instead (the configuration-change
        // handler rebuilds the chain and picks playback up again).
        guard engineReadyToPlay() else {
            f.cancel()
            feeder = nil
            playerNode.stop()
            lastError = "audio output isn't ready — try playing again"
            NSLog("1Shot: skipped starting audio: engine running \(engine.isRunning), player connected \(playerConnected)")
            // One quiet retry: a device change usually settles within a fraction of a second.
            if !retryingStart {
                retryingStart = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self else { return }
                    self.syncState()
                    self.retryingStart = false
                }
            }
            return
        }
        playerNode.play()
        f.start()
        audioRunning = true
    }

    private var retryingStart = false

    private var playerConnected: Bool {
        playerNode.engine === engine && !engine.outputConnectionPoints(for: playerNode, outputBus: 0).isEmpty
    }

    /// True when playerNode.play() is safe to call: attached, connected, and the engine running
    /// (restarting it once if it has stopped).
    private func engineReadyToPlay() -> Bool {
        guard playerConnected else { return false }
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start() } catch { return false }
        }
        return engine.isRunning
    }

    private func stopAudio() {
        feeder?.cancel()
        feeder = nil
        playerNode.stop()     // also releases anything still queued
        audioRunning = false
    }

    private func updateVolume() {
        guard !isExporting, let player else { return }
        engine.mainMixerNode.outputVolume = player.isMuted ? 0 : player.volume
        meterLock.lock(); liveVolume = engine.mainMixerNode.outputVolume; meterLock.unlock()
    }
}

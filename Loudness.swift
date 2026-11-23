// Loudness — LUFS (ITU-R BS.1770 / EBU R128), the way YouTube measures loudness.
//   LUFSMeter      momentary (400 ms), short-term (3 s) and integrated (gated) loudness of any audio fed to it
//   LoudnessScan   renders the edit's audio through Sound Design offline (exactly as the export does) and measures it
// Used by the export's normalize-to−14-LUFS option and the MCP get_settings(measure: true) tool.
// YouTube plays everything at about −14 LUFS: louder videos are turned down, quieter ones are NOT turned up.

import Cocoa
import AVFoundation

// MARK: - The meter

final class LUFSMeter {
    static let target = -14.0

    struct Reading {
        var momentary: Double?      // LUFS, nil = no recent audio
        var shortTerm: Double?
        var integrated: Double?     // nil = nothing loud enough measured yet
        var peakDB: Double          // highest sample peak, dBFS
        var seconds: Double         // audio measured (for integrated)
    }

    private struct Biquad {
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var z1 = 0.0, z2 = 0.0
        mutating func run(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    private let lock = NSLock()
    private var shelf = [Biquad(), Biquad()]
    private var highPass = [Biquad(), Biquad()]
    private var blockSize = 4_800                // 100 ms
    private var blockSum = 0.0
    private var blockCount = 0
    private var recent: [Double] = []            // last 30 block powers (3 s)
    private var gating: [Double] = []            // 400 ms powers, one every 100 ms, since reset
    private var peak = 0.0
    private var blocksMeasured = 0
    private var lastAudio: TimeInterval = 0

    init(sampleRate: Double) { configure(sampleRate) }

    /// Clears everything and sets the K-weighting filters for this sample rate.
    func reset(sampleRate: Double? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let sampleRate { configure(sampleRate) } else { clearFilters() }
        blockSum = 0; blockCount = 0
        recent = []; gating = []
        peak = 0; blocksMeasured = 0; lastAudio = 0
    }

    private func configure(_ rate: Double) {
        let fs = max(8_000, rate)
        blockSize = max(1, Int((fs / 10).rounded()))
        // Stage 1: high shelf (head effects). Stage 2: high pass (RLB). Coefficients per BS.1770 for any rate.
        var s = Biquad()
        do {
            let f0 = 1681.974450955533, g = 3.999843853973347, q = 0.7071752369554196
            let k = tan(Double.pi * f0 / fs)
            let vh = pow(10, g / 20), vb = pow(vh, 0.4996667741545416)
            let a0 = 1 + k / q + k * k
            s.b0 = (vh + vb * k / q + k * k) / a0
            s.b1 = 2 * (k * k - vh) / a0
            s.b2 = (vh - vb * k / q + k * k) / a0
            s.a1 = 2 * (k * k - 1) / a0
            s.a2 = (1 - k / q + k * k) / a0
        }
        var h = Biquad()
        do {
            let f0 = 38.13547087602444, q = 0.5003270373238773
            let k = tan(Double.pi * f0 / fs)
            let a0 = 1 + k / q + k * k
            h.b0 = 1; h.b1 = -2; h.b2 = 1
            h.a1 = 2 * (k * k - 1) / a0
            h.a2 = (1 - k / q + k * k) / a0
        }
        shelf = [s, s]
        highPass = [h, h]
    }

    private func clearFilters() {
        for i in 0..<2 {
            shelf[i].z1 = 0; shelf[i].z2 = 0
            highPass[i].z1 = 0; highPass[i].z2 = 0
        }
    }

    /// Measures `count` frames of `buffer` starting at frame `from`, multiplied by `gain`.
    func process(_ buffer: AVAudioPCMBuffer, from: Int = 0, count: Int? = nil, gain: Float = 1) {
        guard let data = buffer.floatChannelData else { return }
        let channels = Int(buffer.format.channelCount)
        guard channels > 0 else { return }
        let n = min(count ?? Int(buffer.frameLength), Int(buffer.frameLength) - from)
        guard n > 0 else { return }
        let left = data[0] + from
        let right = data[min(1, channels - 1)] + from      // mono plays as both sides, like the export
        let g = Double(gain)
        lock.lock(); defer { lock.unlock() }
        for i in 0..<n {
            let l = Double(left[i]) * g, r = Double(right[i]) * g
            let a = abs(l), b = abs(r)
            if a > peak { peak = a }
            if b > peak { peak = b }
            let kl = highPass[0].run(shelf[0].run(l))
            let kr = highPass[1].run(shelf[1].run(r))
            blockSum += kl * kl + kr * kr
            blockCount += 1
            if blockCount == blockSize {
                finishBlock(blockSum / Double(blockSize))
                blockSum = 0
                blockCount = 0
            }
        }
        lastAudio = ProcessInfo.processInfo.systemUptime
    }

    private func finishBlock(_ power: Double) {
        recent.append(power)
        if recent.count > 30 { recent.removeFirst(recent.count - 30) }
        blocksMeasured += 1
        if recent.count >= 4 {
            let last4 = recent.suffix(4)
            gating.append(last4.reduce(0, +) / 4)
        }
    }

    private static func lufs(_ power: Double) -> Double { power > 1e-12 ? -0.691 + 10 * log10(power) : -120 }

    /// `staleAfter`: momentary/short-term go blank when no audio arrived for this long (live meters).
    func reading(staleAfter: TimeInterval? = nil) -> Reading {
        lock.lock(); defer { lock.unlock() }
        var live = true
        if let staleAfter { live = ProcessInfo.processInfo.systemUptime - lastAudio < staleAfter }
        var r = Reading(momentary: nil, shortTerm: nil, integrated: nil,
                        peakDB: peak > 0 ? 20 * log10(peak) : -120, seconds: Double(blocksMeasured) / 10)
        if live, recent.count >= 4 { r.momentary = Self.lufs(recent.suffix(4).reduce(0, +) / 4) }
        if live, recent.count >= 30 { r.shortTerm = Self.lufs(recent.reduce(0, +) / Double(recent.count)) }
        // Integrated: absolute gate at −70 LUFS, then relative gate 10 LU below the gated average.
        let loud = gating.filter { Self.lufs($0) > -70 }
        if !loud.isEmpty {
            let relative = Self.lufs(loud.reduce(0, +) / Double(loud.count)) - 10
            let kept = loud.filter { Self.lufs($0) > relative }
            if !kept.isEmpty { r.integrated = Self.lufs(kept.reduce(0, +) / Double(kept.count)) }
        }
        return r
    }
}

// MARK: - Measuring the whole edit after Sound Design

enum LoudnessScan {
    enum ScanError: LocalizedError {
        case cancelled, message(String)
        var errorDescription: String? {
            switch self {
            case .cancelled: return "Loudness measuring was cancelled."
            case .message(let m): return m
            }
        }
    }

    /// Renders the trimmed, cut edit through every Sound Design stage, offline and faster than real
    /// time (exactly like the export), and measures it. Call on the main thread; `completion` and
    /// `progress` run on the main thread. Playback pauses while it runs.
    static func run(rack: AudioRack, asset: AVAsset, audioTrack: AVAssetTrack,
                    start: Double, end: Double, cuts: [Cut], fadeEnd: Double?,
                    isCancelled: @escaping () -> Bool = { false },
                    progress: ((Double) -> Void)? = nil,
                    completion: @escaping (Result<LUFSMeter.Reading, Error>) -> Void) {
        let chunk: AVAudioFrameCount = 4096
        let format: AVAudioFormat
        do {
            format = try rack.beginOfflineRender(maxFrames: chunk)
        } catch {
            rack.endOfflineRender()
            completion(.failure(error))
            return
        }
        let latency = AVAudioFramePosition((rack.totalLatency * format.sampleRate).rounded())
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: Result<LUFSMeter.Reading, Error>
            do {
                outcome = .success(try measure(rack: rack, asset: asset, track: audioTrack, format: format,
                                               chunk: chunk, latency: latency, start: start, end: end,
                                               cuts: cuts, fadeEnd: fadeEnd, isCancelled: isCancelled, progress: progress))
            } catch {
                outcome = .failure(error)
            }
            DispatchQueue.main.async {
                rack.endOfflineRender()
                completion(outcome)
            }
        }
    }

    /// The same, with async/await.
    @MainActor
    static func measureEdit(rack: AudioRack, asset: AVAsset, audioTrack: AVAssetTrack,
                    start: Double, end: Double, cuts: [Cut], fadeEnd: Double?,
                    isCancelled: @escaping () -> Bool = { false },
                    progress: ((Double) -> Void)? = nil) async throws -> LUFSMeter.Reading {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<LUFSMeter.Reading, Error>) in
            run(rack: rack, asset: asset, audioTrack: audioTrack, start: start, end: end, cuts: cuts,
                fadeEnd: fadeEnd, isCancelled: isCancelled, progress: progress) { result in
                cont.resume(with: result)
            }
        }
    }

    private static func measure(rack: AudioRack, asset: AVAsset, track: AVAssetTrack, format: AVAudioFormat,
                                chunk: AVAudioFrameCount, latency: AVAudioFramePosition,
                                start: Double, end: Double, cuts: [Cut], fadeEnd: Double?,
                                isCancelled: () -> Bool, progress: ((Double) -> Void)?) throws -> LUFSMeter.Reading {
        let volume = rack.volumeMap   // A1 section levels (3.7.0)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: AudioFeeder.readerSettings(for: format))
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ScanError.message("Can't read the audio track.") }
        reader.add(output)
        let rate = format.sampleRate
        reader.timeRange = CMTimeRange(start: CMTime(value: CMTimeValue((start * rate).rounded()), timescale: CMTimeScale(rate)),
                                       duration: .positiveInfinity)
        guard reader.startReading() else {
            throw reader.error ?? ScanError.message("Couldn't start reading the audio.")
        }
        defer { reader.cancelReading() }

        let normalized = CutList.normalized(cuts, trim: (start, end))
        let segments = CutList.keptSegments(start: start, end: end, cuts: normalized)
        let keptSeconds = segments.reduce(0) { $0 + ($1.1 - $1.0) }
        let total = AVAudioFramePosition((keptSeconds * rate).rounded())
        guard total > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw ScanError.message("There's no audio inside the trim to measure.")
        }
        let meter = LUFSMeter(sampleRate: rate)
        var scheduled: AVAudioFramePosition = 0
        var rendered: AVAudioFramePosition = 0
        var measured: AVAudioFramePosition = 0
        var lastReport: AVAudioFramePosition = 0
        var sourceEnded = false

        while measured < total {
            if isCancelled() { throw ScanError.cancelled }
            // Keep a little decoded audio queued ahead of the renderer.
            while !sourceEnded && scheduled < rendered + AVAudioFramePosition(chunk) * 4 {
                guard let sample = output.copyNextSampleBuffer() else { sourceEnded = true; break }
                guard var pcm = AudioFeeder.pcmBuffer(from: sample, format: format) else { continue }
                let t0 = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                if !volume.isFlat { volume.apply(to: pcm, startingAt: t0) }
                if let fadeEnd { AudioFeeder.applyFadeOut(to: pcm, startingAt: t0, fadeEnd: fadeEnd) }
                if !normalized.isEmpty {
                    guard let kept = AudioFeeder.keepOnly(pcm, startingAt: t0, segments: segments) else { continue }
                    pcm = kept
                }
                rack.scheduleForExport(pcm)
                scheduled += AVAudioFramePosition(pcm.frameLength)
            }
            let remaining = total + latency - rendered
            if remaining <= 0 { break }
            let want = AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining))
            let status = try rack.renderForExport(want, into: buffer)
            if status == .cannotDoInCurrentContext { continue }
            guard status == .success else { throw ScanError.message("Sound Design couldn't render the audio (status \(status.rawValue)).") }
            let got = AVAudioFramePosition(buffer.frameLength)
            if got == 0 { break }
            let skip = max(0, min(got, latency - rendered))      // the plugins' processing delay
            rendered += got
            let usable = min(got - skip, total - measured)
            if usable > 0 {
                meter.process(buffer, from: Int(skip), count: Int(usable))
                measured += usable
            }
            if let progress, measured - lastReport > AVAudioFramePosition(rate) {
                lastReport = measured
                let fraction = Double(measured) / Double(total)
                DispatchQueue.main.async { progress(fraction) }
            }
        }
        return meter.reading()
    }
}

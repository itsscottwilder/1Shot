// Waveform — 3.2: a DAW-style audio waveform for the A1 lane (2026-11-12: "more resolution
// and detail all the way down to a single sample, the way DaVinci, Logic or Pro Tools draw it").
//
// The audio is read once (mono, 48 kHz float) into a peak pyramid: min, max and RMS for blocks
// of 32, 128, 512 … samples. Drawing picks the level that matches the zoom, so every screen pixel
// shows the true min/max (and RMS) of the samples under it — not a stretched-out bar. Zoomed in
// further than 32 samples per pixel, the actual samples are read on demand in one-second chunks:
// first as exact per-pixel min/max, then as a line through each sample, then with a dot on every
// sample once they're far enough apart (like Pro Tools' sample view).

import Cocoa
import AVFoundation

final class WaveformData {
    static let sampleRate: Double = 48_000
    static let baseBlock = 32
    static let levelFactor = 4

    struct Level {
        let block: Int           // samples per entry
        var mins: [Float]
        var maxs: [Float]
        var rms: [Float]
    }

    let sampleCount: Int
    let levels: [Level]          // levels[0] is the finest (32 samples)
    let gain: Float              // normalises the loudest peak to 1

    private let asset: AVAsset
    private let track: AVAssetTrack

    // Raw samples, one-second chunks, read on demand when zoomed in very far.
    static let chunkSamples = 48_000
    private var chunks: [Int: [Float]] = [:]
    private var chunkOrder: [Int] = []
    private var loading: Set<Int> = []
    /// Called on the main queue when a chunk of samples arrives (redraw).
    var onChunkLoaded: (() -> Void)?

    private init(asset: AVAsset, track: AVAssetTrack, sampleCount: Int, levels: [Level], gain: Float) {
        self.asset = asset
        self.track = track
        self.sampleCount = sampleCount
        self.levels = levels
        self.gain = gain
    }

    // MARK: Building

    private static func readerOutput(asset: AVAsset, track: AVAssetTrack, range: CMTimeRange?) -> (AVAssetReader, AVAssetReaderTrackOutput)? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        if let range { reader.timeRange = range }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        return (reader, output)
    }

    /// Calls `body` with each buffer of mono float samples, in order.
    private static func forEachBuffer(_ output: AVAssetReaderTrackOutput, _ body: (UnsafeBufferPointer<Float>) -> Void) {
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var lengthAtOffset = 0, total = 0
            var pointer: UnsafeMutablePointer<CChar>?
            if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
                                           totalLengthOut: &total, dataPointerOut: &pointer) == noErr,
               lengthAtOffset == total, let pointer {
                pointer.withMemoryRebound(to: Float.self, capacity: total / 4) { p in
                    body(UnsafeBufferPointer(start: p, count: total / 4))
                }
            } else {
                var bytes = [Float](repeating: 0, count: total / 4)
                let ok = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: $0.baseAddress!) }
                if ok == noErr { bytes.withUnsafeBufferPointer(body) }
            }
        }
    }

    /// Reads the whole track and builds the pyramid (background queue: several seconds for a long clip).
    static func build(asset: AVAsset, track: AVAssetTrack) -> WaveformData? {
        guard let (reader, output) = readerOutput(asset: asset, track: track, range: nil) else { return nil }
        let expected = Int(max(1, asset.duration.seconds) * sampleRate / Double(baseBlock)) + 16
        var mins = [Float](), maxs = [Float](), sums = [Float]()
        mins.reserveCapacity(expected); maxs.reserveCapacity(expected); sums.reserveCapacity(expected)
        var lo: Float = 0, hi: Float = 0, sq: Float = 0, n = 0, total = 0
        forEachBuffer(output) { buf in
            for v in buf {
                if n == 0 { lo = v; hi = v; sq = 0 }
                if v < lo { lo = v }
                if v > hi { hi = v }
                sq += v * v
                n += 1
                if n == baseBlock {
                    mins.append(lo); maxs.append(hi); sums.append(sq)
                    n = 0
                }
            }
            total += buf.count
        }
        if n > 0 { mins.append(lo); maxs.append(hi); sums.append(sq) }
        reader.cancelReading()
        guard total > 0 else { return nil }

        // Level 0, then each coarser level from the one below it.
        var levels = [Level(block: baseBlock, mins: mins, maxs: maxs,
                            rms: sums.map { ($0 / Float(baseBlock)).squareRoot() })]
        var sumsBelow = sums
        while levels.last!.mins.count > 64 {
            let below = levels.last!
            let count = (below.mins.count + levelFactor - 1) / levelFactor
            var m = [Float](repeating: 0, count: count), x = m, s = m
            for i in 0..<count {
                let a = i * levelFactor, b = min(below.mins.count, a + levelFactor)
                var l = below.mins[a], h = below.maxs[a], q: Float = 0
                for j in a..<b {
                    l = min(l, below.mins[j]); h = max(h, below.maxs[j]); q += sumsBelow[j]
                }
                m[i] = l; x[i] = h; s[i] = q
            }
            let block = below.block * levelFactor
            levels.append(Level(block: block, mins: m, maxs: x, rms: s.map { ($0 / Float(block)).squareRoot() }))
            sumsBelow = s
        }
        let peak = max(abs(levels.last!.mins.min() ?? 0), abs(levels.last!.maxs.max() ?? 0))
        return WaveformData(asset: asset, track: track, sampleCount: total, levels: levels,
                            gain: peak > 0.0001 ? 1 / peak : 1)
    }

    // MARK: Reading

    /// min, max and RMS of samples [s0, s1) from the pyramid (or from raw samples when loaded and
    /// the range is shorter than a level-0 block). Values are normalised.
    func summary(from s0: Int, to s1: Int) -> (min: Float, max: Float, rms: Float)? {
        let a = max(0, s0), b = min(sampleCount, max(s1, a + 1))
        guard a < b else { return nil }
        let span = b - a
        if span < Self.baseBlock * 2, let raw = samples(a, b) {
            var l = raw[0], h = raw[0], q: Float = 0
            for v in raw { l = min(l, v); h = max(h, v); q += v * v }
            return (l * gain, h * gain, (q / Float(raw.count)).squareRoot() * gain)
        }
        // The coarsest level that still has at least ~2 entries across this range.
        var level = levels[0]
        for l in levels where l.block * 2 <= span { level = l }
        let i0 = a / level.block, i1 = min(level.mins.count, max(i0 + 1, (b + level.block - 1) / level.block))
        var l = level.mins[i0], h = level.maxs[i0], q: Float = 0
        for i in i0..<i1 {
            l = min(l, level.mins[i]); h = max(h, level.maxs[i]); q += level.rms[i] * level.rms[i]
        }
        return (l * gain, h * gain, (q / Float(i1 - i0)).squareRoot() * gain)
    }

    /// Raw samples [s0, s1) if every chunk they touch is loaded; otherwise starts loading and returns nil.
    func samples(_ s0: Int, _ s1: Int) -> [Float]? {
        let c0 = s0 / Self.chunkSamples, c1 = (s1 - 1) / Self.chunkSamples
        var missing = false
        for c in c0...c1 where chunks[c] == nil { missing = true; load(chunk: c) }
        guard !missing else { return nil }
        var out = [Float]()
        out.reserveCapacity(s1 - s0)
        for c in c0...c1 {
            guard let chunk = chunks[c] else { return nil }
            let base = c * Self.chunkSamples
            let a = max(s0, base) - base, b = min(s1, base + chunk.count) - base
            if a < b { out.append(contentsOf: chunk[a..<b]) }
        }
        return out.isEmpty ? nil : out
    }

    /// One sample (normalised), or nil while its chunk loads.
    func sample(_ i: Int) -> Float? {
        guard i >= 0, i < sampleCount else { return nil }
        let c = i / Self.chunkSamples
        guard let chunk = chunks[c] else { load(chunk: c); return nil }
        let k = i - c * Self.chunkSamples
        return k < chunk.count ? chunk[k] * gain : nil
    }

    private func load(chunk c: Int) {
        guard !loading.contains(c), c >= 0, c * Self.chunkSamples < sampleCount else { return }
        loading.insert(c)
        let asset = self.asset, track = self.track
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let start = CMTime(value: CMTimeValue(c * Self.chunkSamples), timescale: CMTimeScale(Self.sampleRate))
            let length = CMTime(value: CMTimeValue(Self.chunkSamples), timescale: CMTimeScale(Self.sampleRate))
            var out = [Float]()
            out.reserveCapacity(Self.chunkSamples)
            if let (reader, output) = Self.readerOutput(asset: asset, track: track, range: CMTimeRange(start: start, duration: length)) {
                Self.forEachBuffer(output) { out.append(contentsOf: $0) }
                reader.cancelReading()
            }
            if out.count > Self.chunkSamples { out.removeLast(out.count - Self.chunkSamples) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading.remove(c)
                guard !out.isEmpty else { return }
                self.chunks[c] = out
                self.chunkOrder.append(c)
                if self.chunkOrder.count > 40 {            // keep about 40 s of raw samples (~8 MB)
                    let old = self.chunkOrder.removeFirst()
                    self.chunks[old] = nil
                }
                self.onChunkLoaded?()
            }
        }
    }
}

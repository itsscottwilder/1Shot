// Volume — A1 clip-gain sections (3.7.0): split points on the audio, and one volume level per
// section between them. Double-click A1 to split it; drag a section's line up or down to change
// its level. Applied before Sound Design (like clip gain in a DAW), in playback, the loudness
// scan and export. Times are original-clip seconds, like cuts.

import AVFoundation

struct VolumeMap: Codable, Equatable {
    var splits: [Double] = []   // sorted, original-clip seconds
    var gains: [Double] = [0]   // dB per section: gains[i] runs from splits[i-1] to splits[i]

    static let minDb = -30.0
    static let maxDb = 12.0
    /// Each split changes level over this many seconds (centred on it), so it never clicks.
    static let ramp = 0.02

    var isFlat: Bool { splits.isEmpty && abs(gains.first ?? 0) < 0.01 }

    /// Counts line up and splits are sorted (anything read from a file goes through this).
    var normalized: VolumeMap {
        var m = self
        let pairs = zip(splits, gains.dropFirst()).filter { $0.0.isFinite }.sorted { $0.0 < $1.0 }
        m.splits = pairs.map(\.0)
        m.gains = [gains.first ?? 0] + pairs.map(\.1)
        while m.gains.count < m.splits.count + 1 { m.gains.append(m.gains.last ?? 0) }
        m.gains = m.gains.map { min(Self.maxDb, max(Self.minDb, $0.isFinite ? $0 : 0)) }
        return m
    }

    /// Index of the section that contains `t`.
    func section(at t: Double) -> Int {
        var lo = 0, hi = splits.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if t < splits[mid] { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }

    func db(at t: Double) -> Double { gains[min(section(at: t), gains.count - 1)] }

    /// dB at `t`, with the short ramp across each split.
    func smoothDb(at t: Double) -> Double {
        let i = section(at: t)
        let r = Self.ramp / 2
        if i > 0, t - splits[i - 1] < r {
            let s = splits[i - 1]
            let f = (t - (s - r)) / (2 * r)
            return gains[i - 1] + (gains[i] - gains[i - 1]) * f
        }
        if i < splits.count, splits[i] - t < r {
            let s = splits[i]
            let f = (t - (s - r)) / (2 * r)
            return gains[i] + (gains[i + 1] - gains[i]) * f
        }
        return gains[i]
    }

    func linear(at t: Double) -> Float { Float(pow(10, smoothDb(at: t) / 20)) }

    /// Splits the section at `t` in two (both keep its level). Returns the new split's index.
    @discardableResult
    mutating func split(at t: Double) -> Int? {
        let i = section(at: t)
        if i > 0, t - splits[i - 1] < 0.05 { return nil }
        if i < splits.count, splits[i] - t < 0.05 { return nil }
        splits.insert(t, at: i)
        gains.insert(gains[i], at: i)
        return i
    }

    /// Removes split `i`; the two sections become one with the left one's level.
    mutating func removeSplit(_ i: Int) {
        guard splits.indices.contains(i) else { return }
        splits.remove(at: i)
        gains.remove(at: i + 1)
    }

    /// Moves split `i`, never past its neighbours.
    mutating func moveSplit(_ i: Int, to t: Double) {
        guard splits.indices.contains(i) else { return }
        let lo = i > 0 ? splits[i - 1] + 0.05 : 0
        let hi = i + 1 < splits.count ? splits[i + 1] - 0.05 : .greatestFiniteMagnitude
        splits[i] = min(max(t, lo), hi)
    }

    /// After the A-roll's clips change length: moves every split with the timeline (see ripple in
    /// applyAssetTrims). Splits that land on top of each other merge.
    func rippled(_ f: (Double) -> Double) -> VolumeMap {
        var m = VolumeMap(splits: [], gains: [gains.first ?? 0])
        for (i, s) in splits.enumerated() {
            let t = f(s)
            if let last = m.splits.last, t - last < 0.05 {
                m.gains[m.gains.count - 1] = gains[i + 1]
            } else {
                m.splits.append(t)
                m.gains.append(gains[i + 1])
            }
        }
        return m
    }

    /// Multiplies a buffer by the level at each moment. `start` is the buffer's first sample time on
    /// the clock `toClip` turns into original-clip seconds (playback runs on the edited timeline).
    func apply(to buffer: AVAudioPCMBuffer, startingAt start: Double, toClip: ((Double) -> Double)? = nil) {
        guard !isFlat, let data = buffer.floatChannelData, start.isFinite else { return }
        let rate = buffer.format.sampleRate
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let block = 32   // the level is worked out every 32 samples (0.7 ms)
        var i = 0
        while i < frames {
            let n = min(block, frames - i)
            let t = start + Double(i + n / 2) / rate
            let g = linear(at: toClip?(t) ?? t)
            if abs(g - 1) > 0.000_01 {
                for c in 0..<channels {
                    let p = data[c] + i
                    for k in 0..<n { p[k] *= g }
                }
            }
            i += n
        }
    }
}

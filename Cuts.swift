// Cuts — multi-cut editing: pieces removed from the middle of the clip (pauses, false starts,
// retakes). Times are seconds on the ORIGINAL clip, same as the edit transcript and the
// style-guide cut lists. Trim (in/out) stays separate; cuts live inside it.

import Foundation
import AVFoundation

struct Cut: Codable, Equatable {
    var start: Double
    var end: Double
    var reason: String?      // pause, false-start, retake, dead-air, manual, other
    var note: String?

    var length: Double { end - start }
}

enum CutList {
    static let minimumLength = 0.04     // shorter than ~1 frame isn't a cut

    /// Sorted, inside the trim, overlapping/touching cuts merged, slivers dropped.
    static func normalized(_ cuts: [Cut], trim: (start: Double, end: Double)?) -> [Cut] {
        var list = cuts.compactMap { c -> Cut? in
            var c = c
            if c.end < c.start { swap(&c.start, &c.end) }
            if let trim {
                c.start = max(c.start, trim.start)
                c.end = min(c.end, trim.end)
            }
            return c.end - c.start >= minimumLength ? c : nil
        }
        list.sort { $0.start < $1.start }
        var out: [Cut] = []
        for c in list {
            if let last = out.last, c.start <= last.end + 0.01 {
                out[out.count - 1].end = max(last.end, c.end)
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// The parts of start…end that are kept.
    static func keptSegments(start: Double, end: Double, cuts: [Cut]) -> [(Double, Double)] {
        var segments: [(Double, Double)] = []
        var t = start
        for c in cuts where c.end > start && c.start < end {
            if c.start > t { segments.append((t, c.start)) }
            t = max(t, c.end)
        }
        if end > t { segments.append((t, end)) }
        return segments
    }

    static func totalLength(_ cuts: [Cut]) -> Double { cuts.reduce(0) { $0 + $1.length } }

    /// How much has been cut out before `time` (original-clip seconds).
    static func removed(before time: Double, cuts: [Cut]) -> Double {
        cuts.reduce(0) { sum, c in
            time <= c.start ? sum : sum + (min(time, c.end) - c.start)
        }
    }

    /// Edited-timeline time → original-clip time (cuts sorted, as normalized() returns them).
    static func sourceTime(_ edited: Double, cuts: [Cut]) -> Double {
        var t = edited
        for c in cuts {
            if t >= c.start - 0.000_5 { t += c.length } else { break }
        }
        return t
    }

    static func cut(containing time: Double, in cuts: [Cut]) -> Cut? {
        cuts.first { time >= $0.start && time < $0.end }
    }

    // MARK: Reading a cut list (from an AI, a file, or the clipboard)

    enum ParseError: LocalizedError {
        case notFound
        var errorDescription: String? {
            "That doesn't look like a cut list. Expected JSON with a \"cuts\" list of {\"start\", \"end\"} times in seconds."
        }
    }

    /// Accepts the style-guide format ({"cuts": [...]}), a bare [...] list, and text around it
    /// (an AI reply with a ```json block, for example).
    static func parse(_ text: String) throws -> (cuts: [Cut], review: Int) {
        struct Wrapper: Decodable { let cuts: [Cut]; let review: [Review]? }
        struct Review: Decodable {}
        let decoder = JSONDecoder()
        var candidates: [String] = [text]
        if let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b {
            candidates.append(String(text[a...b]))
        }
        if let a = text.firstIndex(of: "["), let b = text.lastIndex(of: "]"), a < b {
            candidates.append(String(text[a...b]))
        }
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8) else { continue }
            if let w = try? decoder.decode(Wrapper.self, from: data) { return (w.cuts, w.review?.count ?? 0) }
            if let list = try? decoder.decode([Cut].self, from: data) { return (list, 0) }
        }
        throw ParseError.notFound
    }

    // MARK: Pauses from the edit transcript

    /// Longest non-speech sound (breath, click, road noise) that can sit inside one pause.
    static let maxBlip = 1.0

    /// Joins pauses that are separated only by a short sound that isn't speech — no word ends
    /// inside it — so one long pause with a breath in the middle becomes one pause (and one cut),
    /// not several cuts with slivers of silence between them.
    static func mergedPauses(_ t: EditTranscript) -> [EditTranscript.Silence] {
        let wordEnds = t.words.map(\.e).sorted()
        func speechInside(_ a: Double, _ b: Double) -> Bool {
            wordEnds.contains { $0 > a + 0.02 && $0 < b - 0.02 }
        }
        var out: [EditTranscript.Silence] = []
        for p in t.silences.sorted(by: { $0.s < $1.s }) {
            if let last = out.last, p.s - last.e <= maxBlip, !speechInside(last.e, p.s) {
                out[out.count - 1].e = max(last.e, p.e)
            } else {
                out.append(p)
            }
        }
        return out
    }

    /// Every pause longer than `over` seconds is shortened to `keep` seconds, cutting from the
    /// middle so the remaining silence sits evenly around the cut. (Matches the Default style guide.)
    static func pauseCuts(from t: EditTranscript, trim: (start: Double, end: Double)?,
                          keep: Double = 0.35, over: Double = 0.6, minCut: Double = 1.0) -> [Cut] {
        let lo = trim?.start ?? t.trimStart ?? 0
        let hi = trim?.end ?? t.trimEnd ?? t.duration
        return mergedPauses(t).compactMap { p in
            let s = max(p.s, lo), e = min(p.e, hi)
            // Style guide rule 8: a pause cut must remove at least minCut seconds.
            guard e - s > over, (e - s) - keep >= minCut else { return nil }
            return Cut(start: s + keep / 2, end: e - keep / 2, reason: "pause",
                       note: String(format: "%.1f s → %.2f s", e - s, keep))
        }
    }
}

extension AudioFeeder {
    /// Keeps only the samples inside `segments` (original-clip seconds), with a short fade at
    /// every segment edge so cuts don't click. Returns nil if nothing in this buffer is kept.
    static func keepOnly(_ buffer: AVAudioPCMBuffer, startingAt t0: Double,
                         segments: [(Double, Double)], fade: Double = 0.008) -> AVAudioPCMBuffer? {
        guard let src = buffer.floatChannelData, t0.isFinite else { return nil }
        let rate = buffer.format.sampleRate
        let n = Int(buffer.frameLength)
        let t1 = t0 + Double(n) / rate
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity),
              let dst = out.floatChannelData else { return nil }
        let channels = Int(buffer.format.channelCount)
        var w = 0
        for (s, e) in segments where e > t0 && s < t1 {
            let i0 = max(0, Int(((s - t0) * rate).rounded(.up)))
            let i1 = min(n, Int(((e - t0) * rate).rounded(.up)))
            guard i1 > i0 else { continue }
            for i in i0..<i1 {
                let t = t0 + Double(i) / rate
                let g = Float(min(1, (t - s) / fade, (e - t) / fade))
                for c in 0..<channels { dst[c][w] = src[c][i] * max(0, g) }
                w += 1
            }
        }
        guard w > 0 else { return nil }
        out.frameLength = AVAudioFrameCount(w)
        return out
    }
}

// MARK: Edited cut list (what you changed, for an AI to learn from)

/// Automation › Export Finalized Cut List: the cuts as they are now, the cut list that was suggested
/// (imported, pasted or made by Cut Pauses), and a cut-by-cut list of what changed.
/// `cuts` is in the normal cut-list format, so the file can be imported again.
struct EditedCutList: Encodable {
    struct Span: Encodable { let start: Double; let end: Double; let length: Double }
    struct Change: Encodable {
        let change: String          // unchanged, resized, removed, added
        let reason: String?
        let note: String?
        let suggested: Span?
        let edited: Span?
        let startMoved: Double?     // seconds; + = the cut now starts later
        let endMoved: Double?       // seconds; + = the cut now ends later
        let lengthChange: Double?   // seconds; + = the cut now removes more
    }
    struct Summary: Encodable {
        let suggestedCuts: Int
        let finalCuts: Int
        let unchanged: Int
        let resized: Int
        let removed: Int
        let added: Int
        let suggestedSecondsRemoved: Double
        let finalSecondsRemoved: Double
        let finalLength: Double
    }

    let kind = "1shot-edited-cut-list"
    let formatVersion = 1
    let howToRead = "cuts = the person's final edit. suggestedCuts = what was suggested before they edited it. " +
        "changes = each suggested cut matched to its edited version (edited): removed means they kept that part, " +
        "resized means they moved an edge, added means they cut something new. Times are seconds on the original clip."
    let clip: String
    let fps: Double
    let trimStart: Double
    let trimEnd: Double
    let styleGuide: String?
    let suggestedFrom: String?
    let exported: String
    let cuts: [Cut]
    let suggestedCuts: [Cut]
    let changes: [Change]
    let summary: Summary

    init(clip: String, fps: Double, trim: (start: Double, end: Double), styleGuide: String?,
         suggestedFrom: String?, suggested: [Cut], edited: [Cut]) {
        func r(_ x: Double) -> Double { (x * 100).rounded() / 100 }
        func span(_ c: Cut) -> Span { Span(start: r(c.start), end: r(c.end), length: r(c.length)) }
        func rounded(_ c: Cut) -> Cut { Cut(start: r(c.start), end: r(c.end), reason: c.reason, note: c.note) }

        // Pair each suggested cut with the edited cut it overlaps most.
        var used = Set<Int>()
        var changes: [(at: Double, change: Change)] = []
        var unchanged = 0, resized = 0, removed = 0
        for s in suggested {
            var best: (Int, Double)?
            for (j, f) in edited.enumerated() where !used.contains(j) {
                let overlap = min(s.end, f.end) - max(s.start, f.start)
                if overlap > 0, best == nil || overlap > best!.1 { best = (j, overlap) }
            }
            if let (j, _) = best {
                used.insert(j)
                let f = edited[j]
                let same = abs(f.start - s.start) < 0.01 && abs(f.end - s.end) < 0.01
                if same { unchanged += 1 } else { resized += 1 }
                changes.append((s.start, Change(change: same ? "unchanged" : "resized", reason: s.reason, note: s.note,
                                                suggested: span(s), edited: span(f),
                                                startMoved: same ? nil : r(f.start - s.start),
                                                endMoved: same ? nil : r(f.end - s.end),
                                                lengthChange: same ? nil : r(f.length - s.length))))
            } else {
                removed += 1
                changes.append((s.start, Change(change: "removed", reason: s.reason, note: s.note,
                                                suggested: span(s), edited: nil,
                                                startMoved: nil, endMoved: nil, lengthChange: r(-s.length))))
            }
        }
        var added = 0
        for (j, f) in edited.enumerated() where !used.contains(j) {
            added += 1
            changes.append((f.start, Change(change: "added", reason: f.reason, note: f.note,
                                            suggested: nil, edited: span(f),
                                            startMoved: nil, endMoved: nil, lengthChange: r(f.length))))
        }

        self.clip = clip
        self.fps = fps
        self.trimStart = r(trim.start)
        self.trimEnd = r(trim.end)
        self.styleGuide = styleGuide
        self.suggestedFrom = suggestedFrom
        self.exported = ISO8601DateFormatter().string(from: Date())
        self.cuts = edited.map(rounded)
        self.suggestedCuts = suggested.map(rounded)
        self.changes = changes.sorted { $0.at < $1.at }.map(\.change)
        let finalRemoved = CutList.totalLength(edited)
        self.summary = Summary(suggestedCuts: suggested.count, finalCuts: edited.count,
                               unchanged: unchanged, resized: resized, removed: removed, added: added,
                               suggestedSecondsRemoved: r(CutList.totalLength(suggested)),
                               finalSecondsRemoved: r(finalRemoved),
                               finalLength: r(trim.end - trim.start - finalRemoved))
    }
}

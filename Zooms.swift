// Zooms — punch-in zooms from a zoom list (see StyleGuides/Zooms - Talking Head.md).
// Each entry says "from this moment on, show the picture at this scale", in original-clip
// seconds, so zooms stay put when cuts are added or removed. Applied as an instant crop in the
// color pipeline, so the preview and the YouTube export both get them.

import Foundation

struct ZoomEvent: Codable, Equatable {
    var at: Double
    var scale: Double
    var type: String?       // punch-in, reset, cta
    var reason: String?
    var words: String?
    /// Point that stays put while zoomed (0–1, from the top-left of the frame): where the eyes are.
    /// Missing = the default eye line, centered and 42% down.
    var anchorX: Double? = nil
    var anchorY: Double? = nil
}

enum ZoomList {
    static let punchScale = 1.28
    static let ctaScale = 1.40
    /// Point of the frame that stays put while zoomed: centered, 42% down from the top, so the
    /// eyes stay near the upper third instead of sliding off the top.
    static let anchorFromTop = 0.42

    enum ParseError: LocalizedError {
        case notFound
        var errorDescription: String? {
            "No zoom list found. It should be JSON like {\"zooms\": [{\"at\": 31.3, \"scale\": 1.28}, …]}."
        }
    }

    /// Sorted, scales kept between 1× and 2×, and only one zoom per moment.
    static func normalized(_ list: [ZoomEvent]) -> [ZoomEvent] {
        var out: [ZoomEvent] = []
        for var z in list.sorted(by: { $0.at < $1.at }) where z.at.isFinite && z.scale.isFinite {
            z.at = max(0, z.at)
            z.scale = min(2, max(1, z.scale))
            if let last = out.last, abs(last.at - z.at) < 0.02 { out[out.count - 1] = z } else { out.append(z) }
        }
        return out
    }

    /// The scale in effect at clip time `t` (1 before the first zoom).
    static func scale(at t: Double, in list: [ZoomEvent]) -> Double {
        active(at: t, in: list)?.scale ?? 1
    }

    /// The zoom in effect at clip time `t`, if any.
    static func active(at t: Double, in list: [ZoomEvent]) -> ZoomEvent? {
        var current: ZoomEvent?
        for z in list {
            if z.at <= t { current = z } else { break }
        }
        return current
    }

    /// Seconds a punch-in added by hand (Z key, or right-click › Add Punch-In Here) stays in before
    /// going back to normal (3.3.3: 15 s, was 10 s for Z and open-ended from the menu). Drag its
    /// end, or edit Out in the Zooms tab, to make it longer.
    static let defaultHold = 15.0

    static func parse(_ text: String) throws -> [ZoomEvent] {
        struct Wrapper: Decodable { let zooms: [ZoomEvent] }
        let decoder = JSONDecoder()
        var candidates: [String] = [text]
        if let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b { candidates.append(String(text[a...b])) }
        if let a = text.firstIndex(of: "["), let b = text.lastIndex(of: "]"), a < b { candidates.append(String(text[a...b])) }
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8) else { continue }
            if let w = try? decoder.decode(Wrapper.self, from: data) { return w.zooms }
            if let list = try? decoder.decode([ZoomEvent].self, from: data) { return list }
        }
        throw ParseError.notFound
    }

    static func type(for scale: Double) -> String {
        scale >= ctaScale - 0.01 ? "cta" : (scale > 1.001 ? "punch-in" : "reset")
    }
}

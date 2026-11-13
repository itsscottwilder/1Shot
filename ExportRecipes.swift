// ExportRecipes — 3.2: the Export tab's presets. Each recipe sets the container, video codec,
// output size, bitrate (by frame rate) and audio, following the platform's published upload
// guidelines (YouTube "Recommended upload encoding settings", Vimeo/Facebook/X/LinkedIn/Instagram
// help pages, Apple ProRes white paper). Frame rate always stays the source's.

import Foundation
import AVFoundation

struct ExportRecipe: Equatable {
    enum Size: Equatable { case source, height(Int), width(Int) }

    let id: String
    let group: String            // menu section
    let name: String             // menu title
    let fileSuffix: String       // "(YouTube 4K)" in the file name
    let codec: AVVideoCodecType
    let size: Size
    let mbps: (standard: Double, high: Double)?   // nil = ProRes (fixed quality, no bitrate)
    let audioKbps: Int?          // nil = uncompressed PCM (24-bit, 48 kHz)
    let notes: String            // shown under the menu
    let maxSeconds: Double?      // platform length limit (warns, doesn't stop)

    var isProRes: Bool { mbps == nil }
    var fileType: AVFileType { isProRes ? .mov : .mp4 }
    var fileExtension: String { isProRes ? "mov" : "mp4" }

    /// Average video bitrate for this frame rate (bits/s); nil for ProRes.
    func bitrate(fps: Double) -> Int? {
        guard let mbps else { return nil }
        return Int((fps > 31 ? mbps.high : mbps.standard) * 1_000_000)
    }

    /// Output size for a source of `w`×`h` (keeps the shape, even numbers).
    func outputSize(sourceWidth w: Int, sourceHeight h: Int) -> (Int, Int) {
        func even(_ v: Double) -> Int { max(2, Int(v.rounded()) / 2 * 2) }
        switch size {
        case .source: return (w, h)
        case .height(let target): return (even(Double(w) * Double(target) / Double(max(1, h))), even(Double(target)))
        case .width(let target): return (even(Double(target)), even(Double(h) * Double(target) / Double(max(1, w))))
        }
    }

    var specs: String {
        let codecName: String
        switch codec {
        case .proRes422HQ: codecName = "Apple ProRes 422 HQ"
        case .proRes422: codecName = "Apple ProRes 422"
        case .proRes4444: codecName = "Apple ProRes 4444"
        case .hevc: codecName = "H.265 (HEVC)"
        default: codecName = "H.264 High"
        }
        let sizeText: String
        switch size {
        case .source: sizeText = "source resolution"
        case .height(let h): sizeText = h >= 4320 ? "7680×4320 (8K)" : h >= 2160 ? "3840×2160 (4K)" : h >= 1440 ? "2560×1440" : "\(h * 16 / 9)×\(h)"
        case .width(let w): sizeText = "\(w) wide"
        }
        let rate = mbps.map { m in m.standard == m.high ? "\(fmt(m.standard)) Mbps" : "\(fmt(m.standard)) Mbps (≤30 fps) / \(fmt(m.high)) Mbps (60 fps)" } ?? "fixed quality"
        let audio = audioKbps.map { "AAC-LC 48 kHz stereo \($0) kbps" } ?? "PCM 24-bit 48 kHz stereo"
        return "\(isProRes ? "MOV" : "MP4") · \(codecName) · \(sizeText)\n\(rate) · source frame rate\n\(audio)"
    }

    private func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }

    static let all: [ExportRecipe] = [
        .init(id: "master-hq", group: "Master", name: "Uncompressed-quality master (ProRes 422 HQ)", fileSuffix: "Master",
              codec: .proRes422HQ, size: .source, mbps: nil, audioKbps: nil,
              notes: "Visually lossless, for archiving or finishing in another editor. Big files (about 1.8 GB a minute at 1080p, 7 GB at 4K). True uncompressed video isn't offered: it's 5–10× bigger again with no visible gain.",
              maxSeconds: nil),
        .init(id: "master-4444", group: "Master", name: "Master, highest quality (ProRes 4444)", fileSuffix: "Master 4444",
              codec: .proRes4444, size: .source, mbps: nil, audioKbps: nil,
              notes: "Apple's top ProRes flavour: full colour detail. About 1.5× the size of 422 HQ.",
              maxSeconds: nil),
        .init(id: "yt-1080", group: "YouTube", name: "YouTube 1080p", fileSuffix: "YouTube",
              codec: .h264, size: .height(1080), mbps: (8, 12), audioKbps: 320,
              notes: "YouTube's recommended SDR upload settings for 1080p. Fast start for quick processing.",
              maxSeconds: nil),
        .init(id: "yt-1440", group: "YouTube", name: "YouTube 1440p (2K)", fileSuffix: "YouTube 1440p",
              codec: .h264, size: .height(1440), mbps: (16, 24), audioKbps: 320,
              notes: "Uploading above 1080p gets YouTube's better VP9/AV1 encode, so viewers on 1080p see a sharper picture too. Upscales a 1080p source.",
              maxSeconds: nil),
        .init(id: "yt-4k", group: "YouTube", name: "YouTube 4K", fileSuffix: "YouTube 4K",
              codec: .h264, size: .height(2160), mbps: (45, 68), audioKbps: 320,
              notes: "YouTube's recommended 4K SDR bitrates (35–45 Mbps, 53–68 Mbps at 60 fps). Best from a 4K source; upscales a smaller one.",
              maxSeconds: nil),
        .init(id: "yt-8k", group: "YouTube", name: "YouTube 8K", fileSuffix: "YouTube 8K",
              codec: .hevc, size: .height(4320), mbps: (120, 180), audioKbps: 320,
              notes: "H.265 (YouTube accepts it; H.264 can't encode 8K on a Mac). YouTube recommends 80–160 Mbps (120–240 at 60 fps). Very large files, and it upscales anything below 8K. Needs a Mac whose hardware can encode 8K HEVC.",
              maxSeconds: nil),
        .init(id: "vimeo-1080", group: "Other sites", name: "Vimeo 1080p", fileSuffix: "Vimeo",
              codec: .h264, size: .height(1080), mbps: (15, 20), audioKbps: 320,
              notes: "Vimeo recommends 10–20 Mbps for 1080p, AAC-LC 320 kbps.",
              maxSeconds: nil),
        .init(id: "vimeo-4k", group: "Other sites", name: "Vimeo 4K", fileSuffix: "Vimeo 4K",
              codec: .h264, size: .height(2160), mbps: (45, 60), audioKbps: 320,
              notes: "Vimeo recommends 30–60 Mbps for 4K.",
              maxSeconds: nil),
        .init(id: "facebook", group: "Social", name: "Facebook (1080p)", fileSuffix: "Facebook",
              codec: .h264, size: .height(1080), mbps: (8, 12), audioKbps: 192,
              notes: "MP4, H.264, square pixels, fixed frame rate, AAC stereo 128 kbps or more, as Facebook's upload guidelines ask.",
              maxSeconds: nil),
        .init(id: "x", group: "Social", name: "X / Twitter (1080p)", fileSuffix: "X",
              codec: .h264, size: .height(1080), mbps: (10, 15), audioKbps: 192,
              notes: "X takes up to 1920×1200, H.264 High, ≤60 fps, AAC-LC, up to 512 MB. Regular accounts are limited to 2:20; Premium allows longer.",
              maxSeconds: 140),
        .init(id: "linkedin", group: "Social", name: "LinkedIn (1080p)", fileSuffix: "LinkedIn",
              codec: .h264, size: .height(1080), mbps: (8, 10), audioKbps: 192,
              notes: "LinkedIn takes MP4 H.264 up to 1920×1080, AAC audio, up to 5 GB and 15 minutes (10 from the mobile app).",
              maxSeconds: 900),
        .init(id: "instagram", group: "Social", name: "Instagram (16:9, 1080 wide)", fileSuffix: "Instagram",
              codec: .h264, size: .width(1080), mbps: (5, 6), audioKbps: 128,
              notes: "Instagram shows video at most 1080 pixels wide; this keeps your 16:9 shape (1080×608). Vertical Reels need a 9:16 edit.",
              maxSeconds: 3600),
        .init(id: "small", group: "Other", name: "Small file for sharing (H.265 1080p)", fileSuffix: "Small",
              codec: .hevc, size: .height(1080), mbps: (5, 7), audioKbps: 192,
              notes: "About a third the size of the YouTube export with nearly the same look. Plays on any recent Apple device and most others.",
              maxSeconds: nil)
    ]

    static let defaultID = "yt-1080"

    static func find(_ id: String?) -> ExportRecipe {
        if id == CustomExport.id { return custom(CustomExport.saved) }
        return all.first { $0.id == id } ?? all.first { $0.id == defaultID }!
    }

    /// The Custom recipe (3.2): The user's own codec, size, bitrate and audio from the Export panel.
    static func custom(_ c: CustomExport) -> ExportRecipe {
        let codec: AVVideoCodecType
        switch c.codec {
        case "hevc": codec = .hevc
        case "prores422": codec = .proRes422
        case "prores422hq": codec = .proRes422HQ
        case "prores4444": codec = .proRes4444
        default: codec = .h264
        }
        let proRes = c.codec.hasPrefix("prores")
        var notes = "Your own settings. Frame rate stays the source's."
        if codec == .h264 && c.height > 2160 { notes += " ⚠︎ H.264 can't encode above 4K on a Mac: choose H.265 for 8K." }
        if proRes { notes += " ProRes is fixed quality, so there's no bitrate to set; files are large." }
        return ExportRecipe(id: CustomExport.id, group: "Custom", name: "Custom", fileSuffix: "Custom",
                            codec: codec, size: c.height > 0 ? .height(c.height) : .source,
                            mbps: proRes ? nil : (c.mbps, c.mbps), audioKbps: c.audioKbps > 0 ? c.audioKbps : nil,
                            notes: notes, maxSeconds: nil)
    }

    /// The recipe last chosen in the Export tab (⌘Y uses it).
    static var current: ExportRecipe {
        get { find(UserDefaults.standard.string(forKey: "ExportRecipe")) }
        set { UserDefaults.standard.set(newValue.id, forKey: "ExportRecipe") }
    }

    static func == (a: ExportRecipe, b: ExportRecipe) -> Bool { a.id == b.id }
}

/// The Custom export recipe's settings, remembered between launches.
struct CustomExport: Codable, Equatable {
    static let id = "custom"
    var codec = "h264"        // h264, hevc, prores422, prores422hq, prores4444
    var height = 0            // 0 = source size; else 720, 1080, 1440, 2160, 4320
    var mbps = 12.0           // video bitrate (H.264/H.265)
    var audioKbps = 320       // AAC kbps; 0 = uncompressed PCM

    static let codecs: [(id: String, name: String)] = [
        ("h264", "H.264"), ("hevc", "H.265 (HEVC)"), ("prores422", "Apple ProRes 422"),
        ("prores422hq", "Apple ProRes 422 HQ"), ("prores4444", "Apple ProRes 4444")]
    static let heights: [(height: Int, name: String)] = [
        (0, "Source size"), (720, "720p"), (1080, "1080p"), (1440, "1440p (2K)"), (2160, "2160p (4K)"), (4320, "4320p (8K)")]
    static let audio: [(kbps: Int, name: String)] = [
        (128, "AAC 128 kbps"), (192, "AAC 192 kbps"), (256, "AAC 256 kbps"), (320, "AAC 320 kbps"), (0, "Uncompressed PCM (24-bit)")]

    /// A sensible starting bitrate for a size (YouTube's SDR recommendations, 30 fps).
    static func suggestedMbps(height: Int) -> Double {
        switch height {
        case 720: return 5
        case 1440: return 16
        case 2160: return 45
        case 4320: return 120
        default: return 12
        }
    }

    static var saved: CustomExport {
        get {
            guard let d = UserDefaults.standard.data(forKey: "ExportCustom"),
                  let c = try? JSONDecoder().decode(CustomExport.self, from: d) else { return CustomExport() }
            return c
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "ExportCustom") }
    }
}

// Broll — 2.3: a V2 track of B-roll (photos and video) shown full-screen over the talking head.
// Times: `at` is original-clip seconds (like cuts and zooms); `length` and `sourceIn` are seconds
// of finished video, so a B-roll shot plays smoothly across any cuts under it.
// Sources: your own files, Unsplash photos (URLs in a B-roll list), Pixabay video searches
// (run on this Mac with your own key, kept in the Keychain).

import AppKit
import AVFoundation
import CoreImage
import Security

struct BrollClip: Codable, Equatable {
    var id = UUID().uuidString
    var at: Double                 // start, original-clip seconds
    var length: Double             // seconds on screen
    var kind: String = "video"     // video or photo
    var file: String?              // path inside the project folder once it's here
    var sourceIn: Double? = nil    // where in the B-roll video to start (seconds)
    // From a B-roll list, before download:
    var libraryFile: String? = nil // a clip from your Movies folder, copied in when the list is applied
    var url: String? = nil         // direct download (e.g. an Unsplash photo)
    var search: String? = nil      // Pixabay video search, e.g. "hands typing laptop"
    var pixabayId: Int? = nil      // one exact Pixabay video (picked from a candidate sheet)
    var credit: String? = nil
    var reason: String? = nil
    var words: String? = nil
    // Framing (3.2): zoom into the shot and pan across it. 1 = fill the frame; panX/panY −1…1
    // pick which part shows once zoomed in (−1 = left/top edge, 0 = centre, +1 = right/bottom).
    var zoom: Double? = nil
    var panX: Double? = nil
    var panY: Double? = nil
    var visualGroup: String? = nil   // Visual Design group (3.2); nil = the built-in "B-roll" group
    // Picture-in-picture (3.2): the shot shrunk into a box over the talking head. pipScale is the
    // box's size (nil/1 = full screen); pipX/pipY its centre in the 1920×1080 design (y down).
    var pipScale: Double? = nil
    var pipX: Double? = nil
    var pipY: Double? = nil
    var isPiP: Bool { (pipScale ?? 1) < 0.999 }

    var isPhoto: Bool { kind == "photo" }
}

enum BrollList {
    static let defaultPhotoLength = 4.0
    static let defaultVideoLength = 5.0
    static let photoPush = 0.08     // photos ease from 100% to 108% while on screen

    enum ParseError: LocalizedError {
        case notFound
        var errorDescription: String? {
            "No B-roll list found. It should be JSON like {\"broll\": [{\"at\": 120.5, \"length\": 4, \"kind\": \"photo\", \"url\": \"…\"}]}."
        }
    }

    static func parse(_ text: String) throws -> [BrollClip] {
        struct Item: Decodable {
            let at: Double; let length: Double?; let kind: String?; let file: String?; let sourceIn: Double?
            let url: String?; let search: String?; let pixabayId: Int?
            let credit: String?; let reason: String?; let words: String?
            let zoom: Double?; let panX: Double?; let panY: Double?
            let pipScale: Double?; let pipX: Double?; let pipY: Double?
        }
        struct Wrapper: Decodable { let broll: [Item] }
        var candidates = [text]
        if let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b { candidates.append(String(text[a...b])) }
        for c in candidates {
            guard let data = c.data(using: .utf8), let w = try? JSONDecoder().decode(Wrapper.self, from: data) else { continue }
            return w.broll.map { i in
                let guess = i.file.map { isPhotoFile(URL(fileURLWithPath: $0)) ? "photo" : "video" }
                let photo = (i.kind ?? guess ?? (i.search != nil || i.pixabayId != nil ? "video" : "photo")) == "photo"
                return BrollClip(at: i.at, length: i.length ?? (photo ? defaultPhotoLength : defaultVideoLength),
                                 kind: photo ? "photo" : "video", sourceIn: i.sourceIn,
                                 libraryFile: i.file, url: i.url, search: i.search, pixabayId: i.pixabayId,
                                 credit: i.credit, reason: i.reason, words: i.words,
                                 zoom: i.zoom, panX: i.panX, panY: i.panY,
                                 pipScale: i.pipScale, pipX: i.pipX, pipY: i.pipY)
            }
        }
        throw ParseError.notFound
    }

    static func isPhotoFile(_ url: URL) -> Bool {
        ["jpg", "jpeg", "png", "heic", "tif", "tiff", "webp"].contains(url.pathExtension.lowercased())
    }
}

/// Draws B-roll frames for the color pipeline (thread-safe; caches decoders and photos).
final class BrollRenderer {
    struct Shot {
        let url: URL; let at: Double; let length: Double; let sourceIn: Double; let photo: Bool
        var zoom: Double = 1; var panX: Double = 0; var panY: Double = 0
        var group: String? = nil      // Visual Design group (3.2)
        var id: String = ""
        var pip: PiP? = nil           // nil = full screen
    }

    /// A picture-in-picture box: size (0…1 of the frame) and centre in the 1920×1080 design (y down).
    struct PiP { var scale: Double; var x: Double; var y: Double }

    /// While a shot's box is dragged on screen: its live size/position, until the drag ends.
    private var _live: (id: String, pip: PiP?)?
    func setLive(_ id: String?, _ pip: PiP? = nil) {
        lock.lock(); _live = id.map { ($0, pip) }; lock.unlock()
    }

    private let lock = NSLock()
    private var _shots: [Shot] = []
    private var _cuts: [Cut] = []
    /// One frame reader per B-roll video, with the video's length (looked up once, not per frame).
    private struct Decoder { let generator: AVAssetImageGenerator; let duration: Double }
    private var decoders: [URL: Decoder] = [:]
    private var decoderOrder: [URL] = []          // least recently used first
    /// Each reader holds its own video decoders, so only the most recently used few are kept.
    private static let maxDecoders = 6
    /// The last frame decoded. While paused, every slider tick re-renders the same frame — this
    /// saves decoding it again each time.
    private var lastFrame: (url: URL, time: CMTime, image: CIImage)?
    private var photos: [URL: CIImage] = [:]

    func update(shots: [Shot], cuts: [Cut]) {
        lock.lock(); _shots = shots; _cuts = cuts; lock.unlock()
    }

    /// The B-roll picture for clip time `t`, filling `extent`, or nil when no B-roll is on.
    func image(at t: Double, extent: CGRect) -> (CIImage, String?, PiP?)? {
        lock.lock(); let shots = _shots; let cuts = _cuts; let live = _live; lock.unlock()
        let edited = t - CutList.removed(before: t, cuts: cuts)
        for s in shots {
            let startEdited = s.at - CutList.removed(before: s.at, cuts: cuts)
            let into = edited - startEdited
            guard into >= 0, into < s.length else { continue }
            guard var img = s.photo ? photo(s.url) : frame(s.url, at: s.sourceIn + into, extent: extent) else { return nil }
            var k = max(extent.width / img.extent.width, extent.height / img.extent.height)   // fill the frame
            if s.photo { k *= CGFloat(1 + BrollList.photoPush * min(1, into / max(0.1, s.length))) }
            k *= CGFloat(max(1, s.zoom))
            // Pan: slide the zoomed picture so the chosen part shows, never past its edges.
            let spareX = max(0, img.extent.width * k - extent.width) / 2
            let spareY = max(0, img.extent.height * k - extent.height) / 2
            let ox = -CGFloat(max(-1, min(1, s.panX))) * spareX
            let oy = CGFloat(max(-1, min(1, s.panY))) * spareY      // CIImage y runs up; +panY shows lower
            img = img.transformed(by: CGAffineTransform(translationX: -img.extent.midX, y: -img.extent.midY)
                .concatenating(CGAffineTransform(scaleX: k, y: k))
                .concatenating(CGAffineTransform(translationX: extent.midX + ox, y: extent.midY + oy)))
            let pip = live.flatMap { $0.id == s.id ? $0.pip : nil } ?? (live?.id == s.id ? nil : s.pip)
            return (img.cropped(to: extent), s.group, pip)
        }
        return nil
    }

    /// Shrinks a full-frame B-roll picture into its picture-in-picture box: rounded corners and a
    /// soft drop shadow, transparent everywhere else (composite it over the talking head).
    static func placeInPicture(_ img: CIImage, _ pip: PiP, extent: CGRect) -> CIImage {
        let W = extent.width, H = extent.height
        let k = min(W / 1920, H / 1080)
        let ox = (W - 1920 * k) / 2, oy = (H - 1080 * k) / 2
        let s = CGFloat(max(0.05, min(1, pip.scale)))
        let cx = extent.minX + ox + CGFloat(pip.x) * k, cy = extent.minY + H - oy - CGFloat(pip.y) * k
        let box = CGRect(x: cx - W * s / 2, y: cy - H * s / 2, width: W * s, height: H * s)
        let moved = img.cropped(to: extent).transformed(by: CGAffineTransform(translationX: -extent.midX, y: -extent.midY)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: cx, y: cy)))
        let radius = min(box.width, box.height) * 0.04
        func roundRect(_ r: CGRect, _ color: CIColor) -> CIImage? {
            guard let f = CIFilter(name: "CIRoundedRectangleGenerator") else { return nil }
            f.setValue(CIVector(cgRect: r), forKey: "inputExtent")
            f.setValue(radius, forKey: "inputRadius")
            f.setValue(color, forKey: "inputColor")
            return f.outputImage
        }
        guard let mask = roundRect(box, CIColor(red: 1, green: 1, blue: 1)) else { return moved.cropped(to: box) }
        let rounded = moved.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask]).cropped(to: box)
        // Soft drop shadow just below the box.
        let blur = W * 0.008
        guard let soft = roundRect(box.offsetBy(dx: 0, dy: -W * 0.004), CIColor(red: 0, green: 0, blue: 0, alpha: 0.55))?
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur]) else { return rounded }
        return rounded.composited(over: soft).cropped(to: extent)
    }

    private func photo(_ url: URL) -> CIImage? {
        lock.lock(); if let p = photos[url] { lock.unlock(); return p }; lock.unlock()
        guard let img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        lock.lock(); photos[url] = img; lock.unlock()
        return img
    }

    private func decoder(for url: URL, extent: CGRect) -> Decoder {
        lock.lock()
        if let d = decoders[url] {
            if decoderOrder.last != url {
                decoderOrder.removeAll { $0 == url }
                decoderOrder.append(url)
            }
            lock.unlock()
            return d
        }
        lock.unlock()
        // Made outside the lock: reading the length can take a moment, and the main thread
        // takes this lock too.
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        gen.maximumSize = CGSize(width: extent.width * 1.2, height: extent.height * 1.2)
        let made = Decoder(generator: gen, duration: gen.asset.duration.seconds)
        lock.lock(); defer { lock.unlock() }
        if let d = decoders[url] { return d }       // another render thread got there first
        decoders[url] = made
        decoderOrder.append(url)
        while decoderOrder.count > Self.maxDecoders { decoders.removeValue(forKey: decoderOrder.removeFirst()) }
        return made
    }

    private func frame(_ url: URL, at seconds: Double, extent: CGRect) -> CIImage? {
        let decoder = decoder(for: url, extent: extent)
        let duration = decoder.duration
        let t = duration.isFinite && duration > 0.1 ? min(seconds, duration - 0.05) : seconds
        let time = CMTime(seconds: max(0, t), preferredTimescale: 600)
        lock.lock()
        if let last = lastFrame, last.url == url, last.time == time { lock.unlock(); return last.image }
        lock.unlock()
        guard let cg = try? decoder.generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        let image = CIImage(cgImage: cg)
        lock.lock(); lastFrame = (url, time, image); lock.unlock()
        return image
    }
}

// MARK: Your library (videos anywhere in ~/Movies)

enum BrollLibrary {
    struct Entry: Encodable { let file: String; let folder: String; let name: String; let seconds: Double; let created: String }

    /// Every video in ~/Movies (skipping 1Shot's own exports and the B-roll it already copied).
    static func scan() async -> [Entry] {
        let fm = FileManager.default
        guard let movies = fm.urls(for: .moviesDirectory, in: .userDomainMask).first,
              let walker = fm.enumerator(at: movies, includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let videoTypes: Set<String> = ["mov", "mp4", "m4v"]
        var urls: [URL] = []
        for case let url as URL in walker {
            let path = url.path
            if path.contains("/Exports/") || path.contains("/Media/B-roll/") || path.contains("/B-roll Library/")
                || path.hasSuffix(".fcpxml") { continue }   // the library is stock, not your own footage
            if videoTypes.contains(url.pathExtension.lowercased()) { urls.append(url) }
        }
        let iso = ISO8601DateFormatter()
        var out: [Entry] = []
        for url in urls.prefix(2000) {
            let d = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate).flatMap { $0 }
            out.append(Entry(file: url.path, folder: url.deletingLastPathComponent().lastPathComponent,
                             name: url.deletingPathExtension().lastPathComponent,
                             seconds: (d * 10).rounded() / 10, created: created.map { iso.string(from: $0) } ?? ""))
        }
        return out
    }
}

// MARK: Downloads (Unsplash URLs, Pixabay video search)

enum BrollFetch {
    enum FetchError: LocalizedError {
        case noKey, noResults(String), badResponse, vertical(Int)
        var errorDescription: String? {
            switch self {
            case .vertical(let id): return "Pixabay video \(id) is vertical. B-roll is horizontal only (2026-11-10)."
            case .noKey: return "Add your Pixabay key: 1Shot menu › Settings… (⌘,)."
            case .noResults(let q): return "Pixabay found no videos for “\(q)”."
            case .badResponse: return "The download didn't come back as expected."
            }
        }
    }

    /// Downloads `url` into `folder`, named after `base`. Returns the saved file.
    static func download(_ url: URL, into folder: URL, base: String, ext: String) async throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (temp, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { throw FetchError.badResponse }
        var target = folder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(base) \(n).\(ext)"); n += 1
        }
        try FileManager.default.moveItem(at: temp, to: target)
        return target
    }

    /// First good Pixabay video for `query`: (download URL, credit line).
    static func pixabayVideo(_ query: String) async throws -> (URL, String) {
        let hits = try await pixabayHits(["q": query, "per_page": "20"])
        for hit in hits where !isVertical(hit) {
            if let found = downloadURL(hit) { return found }
        }
        throw FetchError.noResults(query)
    }

    /// One exact Pixabay video by its id (picked from a candidate sheet).
    static func pixabayVideo(id: Int) async throws -> (URL, String) {
        let hits = try await pixabayHits(["id": String(id)])
        guard let hit = hits.first, let found = downloadURL(hit) else { throw FetchError.noResults("video \(id)") }
        if isVertical(hit) { throw FetchError.vertical(id) }
        return found
    }

    /// A Pixabay video as a candidate: what it is, how long, who made it, and a thumbnail.
    struct Candidate {
        let id: Int
        let tags: String
        let duration: Int
        let user: String
        let pageURL: String
        let thumbnail: URL?
        let width: Int
        let height: Int
    }

    /// Up to `count` Pixabay videos for `query`, best match first (Pixabay's own order).
    /// Pixabay's API matches tags only, so a word like "tripod" can find just a few clips.
    /// When the main search comes up short it widens: each word of a multi-word search on
    /// its own, then the `also` searches (related scenes or objects), duplicates dropped.
    static func pixabaySearch(_ query: String, count: Int, also: [String] = []) async throws -> [Candidate] {
        var searches = [query]
        let words = query.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init).filter { $0.count > 2 }
        if words.count > 1 { searches += words }
        searches += also.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var seen = Set<Int>()
        var list: [Candidate] = []
        for (i, q) in searches.enumerated() {
            if i > 0 && list.count >= count { break }
            guard let hits = try? await pixabayHits(["q": q, "per_page": "200"]) else { continue }
            for c in hits.compactMap(candidate) {
                if seen.insert(c.id).inserted { list.append(c) }
            }
        }
        guard !list.isEmpty else { throw FetchError.noResults(query) }
        return Array(list.prefix(count))
    }

    /// The video id in a Pixabay link the user pasted: a page ("…/lotus-park-…-281279/", "…/id-164381/")
    /// or a download ("…/download/x-286879_medium.mp4"). nil if it isn't a Pixabay video link.
    static func pixabayId(fromLink link: String) -> Int? {
        guard link.lowercased().contains("pixabay.com"),
              let re = try? NSRegularExpression(pattern: "(\\d{3,})(?=[/_.?#]|$)") else { return nil }
        let path = URL(string: link)?.path ?? link
        let ns = path as NSString
        guard let m = re.matches(in: path, range: NSRange(location: 0, length: ns.length)).last else { return nil }
        return Int(ns.substring(with: m.range(at: 1)))
    }

    /// Specific Pixabay videos by id, in the order given (missing ones are skipped).
    static func pixabayCandidates(ids: [Int]) async -> [Candidate] {
        await withTaskGroup(of: (Int, Candidate?).self) { group in
            for (i, id) in ids.enumerated() {
                group.addTask {
                    let hit = try? await pixabayHits(["id": String(id)]).first
                    return (i, hit.flatMap(candidate))
                }
            }
            var found: [(Int, Candidate)] = []
            for await (i, c) in group { if let c { found.append((i, c)) } }
            return found.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    private static func pixabayHits(_ params: [String: String]) async throws -> [[String: Any]] {
        guard let key = Keychain.pixabayKey, !key.isEmpty else { throw FetchError.noKey }
        guard var c = URLComponents(string: "https://pixabay.com/api/videos/") else { throw FetchError.badResponse }
        c.queryItems = [URLQueryItem(name: "key", value: key), URLQueryItem(name: "safesearch", value: "true")] +
            params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = c.url else { throw FetchError.badResponse }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hits = json["hits"] as? [[String: Any]] else { throw FetchError.badResponse }
        return hits
    }

    private static func downloadURL(_ hit: [String: Any]) -> (URL, String)? {
        guard let videos = hit["videos"] as? [String: Any] else { return nil }
        for size in ["large", "medium", "small"] {
            if let v = videos[size] as? [String: Any], let s = v["url"] as? String, !s.isEmpty, let u = URL(string: s) {
                let user = hit["user"] as? String ?? "Pixabay"
                return (u, "Video by \(user) on Pixabay")
            }
        }
        return nil
    }

    /// No vertical videos, ever (2026-11-10): B-roll fills a 16:9 frame, so a portrait clip
    /// would be cropped to a sliver. Taller than wide = vertical. Applies to searches, candidate
    /// sheets and placing a clip by id.
    static func isVertical(_ hit: [String: Any]) -> Bool {
        guard let videos = hit["videos"] as? [String: Any] else { return false }
        for size in ["medium", "small", "tiny", "large"] {
            if let v = videos[size] as? [String: Any],
               let w = (v["width"] as? NSNumber)?.intValue, let h = (v["height"] as? NSNumber)?.intValue, w > 0, h > 0 {
                return h > w
            }
        }
        return false
    }

    private static func candidate(_ hit: [String: Any]) -> Candidate? {
        guard !isVertical(hit) else { return nil }
        guard let id = (hit["id"] as? NSNumber)?.intValue, let videos = hit["videos"] as? [String: Any] else { return nil }
        var thumb: URL?
        var w = 0, h = 0
        for size in ["medium", "small", "tiny", "large"] {
            guard let v = videos[size] as? [String: Any] else { continue }
            if w == 0 { w = (v["width"] as? NSNumber)?.intValue ?? 0; h = (v["height"] as? NSNumber)?.intValue ?? 0 }
            if thumb == nil, let s = v["thumbnail"] as? String, !s.isEmpty { thumb = URL(string: s) }
        }
        if thumb == nil, let pic = hit["picture_id"] as? String, !pic.isEmpty {
            thumb = URL(string: "https://i.vimeocdn.com/video/\(pic)_640x360.jpg")     // older API field
        }
        return Candidate(id: id, tags: hit["tags"] as? String ?? "",
                         duration: (hit["duration"] as? NSNumber)?.intValue ?? 0,
                         user: hit["user"] as? String ?? "Pixabay",
                         pageURL: hit["pageURL"] as? String ?? "https://pixabay.com/videos/id-\(id)/",
                         thumbnail: thumb, width: w, height: h)
    }
}

// MARK: Keychain + Settings

enum Keychain {
    private static let service = "1ShotPipeline.pixabay"

    private static let fallbackKey = "PixabayAPIKey"

    /// Keychain first. Because every ./build.sh re-signs the app, the Keychain can refuse to hand an
    /// older entry back, so the key is also kept in the app's preferences as a fallback.
    static var pixabayKey: String? {
        get {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            var out: AnyObject?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
               let s = String(data: d, encoding: .utf8), !s.isEmpty { return s }
            return UserDefaults.standard.string(forKey: fallbackKey)
        }
        set {
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            SecItemDelete(base as CFDictionary)
            guard let v = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else {
                UserDefaults.standard.removeObject(forKey: fallbackKey)
                return
            }
            var add = base
            add[kSecValueData as String] = Data(v.utf8)
            SecItemAdd(add as CFDictionary, nil)
            UserDefaults.standard.set(v, forKey: fallbackKey)
        }
    }
}

/// 1Shot › Settings… › B-roll: the Pixabay key.
final class SettingsWindow: NSObject {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private let field = NSSecureTextField()

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 170),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Settings — B-roll"
            w.isReleasedWhenClosed = false
            let v = NSView(frame: w.contentLayoutRect)
            let title = NSTextField(labelWithString: "Pixabay API key (for free stock video)")
            title.font = .boldSystemFont(ofSize: 13)
            title.frame = NSRect(x: 20, y: 125, width: 420, height: 20)
            let help = NSTextField(wrappingLabelWithString:
                "Get a free key at pixabay.com/api/docs. It's stored only on this Mac.")
            help.frame = NSRect(x: 20, y: 85, width: 420, height: 34)
            field.frame = NSRect(x: 20, y: 55, width: 420, height: 24)
            field.placeholderString = "Paste your key"
            let save = NSButton(title: "Save", target: self, action: #selector(save(_:)))
            save.keyEquivalent = "\r"
            save.frame = NSRect(x: 350, y: 14, width: 90, height: 30)
            [title, help, field, save].forEach(v.addSubview)
            w.contentView = v
            w.center()
            window = w
        }
        field.stringValue = Keychain.pixabayKey ?? ""
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func save(_ sender: Any?) {
        Keychain.pixabayKey = field.stringValue
        let ok = !(Keychain.pixabayKey ?? "").isEmpty
        let alert = NSAlert()
        alert.messageText = ok ? "Pixabay key saved" : "Key cleared"
        alert.informativeText = ok ? "Choose Automation › Download Missing B-roll to fetch any videos that are waiting." : ""
        alert.runModal()
        window?.close()
    }
}

// MARK: - Shared B-roll library (3.1.1)

/// Every stock clip the user approves (picked from a candidate sheet, or a link they pasted) is also kept in
/// ~/Movies/1Shot/B-roll Library, so every project can use it. Placing the same clip in another
/// project copies it from here (an instant, space-free clone on APFS) instead of downloading it again.
/// library.json lists each clip with its credit, its Pixabay page and the words it was first used for.
/// Unchecked search results and the user's own footage aren't added.
enum SharedBrollLibrary {
    struct Item: Codable {
        var file: String
        var source: String          // "pixabay" or "url"
        var pixabayId: Int?
        var url: String?
        var page: String?
        var credit: String?
        var words: String?
        var project: String?
        var added: String
    }

    static var folder: URL { Project.defaultLocation.appendingPathComponent("B-roll Library", isDirectory: true) }
    static var indexURL: URL { folder.appendingPathComponent("library.json") }

    static func load() -> [Item] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        return (try? JSONDecoder().decode([Item].self, from: data)) ?? []
    }

    /// The library's copy of a clip, if it has one (and the file is still there).
    static func item(for clip: BrollClip) -> (item: Item, file: URL)? {
        let items = load()
        let match: Item?
        if let id = clip.pixabayId { match = items.first { $0.pixabayId == id } }
        else if let u = clip.url { match = items.first { $0.url == u } }
        else { match = nil }
        guard let match else { return nil }
        let url = folder.appendingPathComponent(match.file)
        return FileManager.default.fileExists(atPath: url.path) ? (match, url) : nil
    }

    /// Copies an approved clip into the library once. Failures are only logged: the project's own
    /// copy is what plays, so the edit never depends on the library.
    @discardableResult
    static func add(_ source: URL, clip: BrollClip, project: String?) -> Bool {
        guard clip.pixabayId != nil || clip.url != nil else { return false }
        if item(for: clip) != nil { return true }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let base = source.deletingPathExtension().lastPathComponent, ext = source.pathExtension
            var target = folder.appendingPathComponent(source.lastPathComponent)
            var n = 2
            while fm.fileExists(atPath: target.path) {
                target = folder.appendingPathComponent("\(base) \(n).\(ext)"); n += 1
            }
            try fm.copyItem(at: source, to: target)
            var items = load()
            items.append(Item(file: target.lastPathComponent,
                              source: clip.pixabayId != nil ? "pixabay" : "url",
                              pixabayId: clip.pixabayId, url: clip.url,
                              page: clip.pixabayId.map { "https://pixabay.com/videos/id-\($0)/" } ?? clip.url,
                              credit: clip.credit, words: clip.words, project: project,
                              added: ISO8601DateFormatter().string(from: Date())))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(items).write(to: indexURL, options: .atomic)
            NSLog("1Shot: added \(target.lastPathComponent) to the B-roll Library")
            return true
        } catch {
            NSLog("1Shot: couldn't add \(source.lastPathComponent) to the B-roll Library: \(error)")
            return false
        }
    }

    /// Saves Pixabay clips the user wants to keep straight into the library, without placing them in an
    /// edit (MCP save_to_broll_library). Each result: id, saved / alreadyThere / error, file, credit.
    static func save(pixabayIds ids: [Int], words: String?, project: String?) async -> [[String: Any]] {
        var results: [[String: Any]] = []
        for id in ids {
            var clip = BrollClip(at: 0, length: 0)
            clip.pixabayId = id
            clip.words = words
            if let existing = item(for: clip) {
                results.append(["pixabayId": id, "alreadyThere": true, "file": existing.item.file,
                                 "credit": existing.item.credit ?? ""])
                continue
            }
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("1Shot-library-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            do {
                let (url, credit) = try await BrollFetch.pixabayVideo(id: id)   // refuses vertical clips
                let file = try await BrollFetch.download(url, into: temp, base: "Pixabay \(id)", ext: "mp4")
                clip.credit = credit
                if add(file, clip: clip, project: project), let saved = item(for: clip) {
                    results.append(["pixabayId": id, "saved": true, "file": saved.item.file, "credit": credit])
                } else {
                    results.append(["pixabayId": id, "error": "couldn't copy it into the library"])
                }
            } catch {
                results.append(["pixabayId": id, "error": error.localizedDescription])
            }
        }
        return results
    }

    /// Clones the library's copy into a project's B-roll folder (keeping an existing copy there).
    static func copy(_ file: URL, into folder: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(file.lastPathComponent)
        if !fm.fileExists(atPath: target.path) { try fm.copyItem(at: file, to: target) }
        return target
    }
}

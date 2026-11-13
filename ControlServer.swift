// ControlServer — 2.4: lets Claude drive 1Shot through MCP.
//
// The app listens on a private local socket that only your Mac user account can open:
//   ~/Library/Application Support/1Shot/mcp.sock
// The small "1shot-mcp" helper (MCP/main.swift) is what the Claude desktop app starts. It speaks MCP
// to Claude and passes each tool call to this socket as one line of JSON:
//   → {"id": 1, "command": "status", "args": {}}
//   ← {"id": 1, "ok": true, "result": {…}}      or      {"id": 1, "ok": false, "error": "…"}
// Nothing leaves the Mac. Every command runs on the main thread, exactly as if you'd used the menus.
//
// Times are seconds on the ORIGINAL clip everywhere (the same clock as transcripts, cut lists,
// zoom lists and B-roll lists).

import Cocoa
import AVFoundation
import ImageIO

// MARK: - The socket

final class ControlServer {
    static let shared = ControlServer()

    /// ~/Library/Application Support/1Shot
    static var supportFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("1Shot", isDirectory: true)
        Project.moveRenamedFolder(from: base.appendingPathComponent("1Shot Pipeline", isDirectory: true), to: folder)
        return folder
    }
    static var socketPath: String { supportFolder.appendingPathComponent("mcp.sock").path }

    private weak var controller: PlayerWindowController?
    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "1Shot.mcp.accept")

    func start(controller: PlayerWindowController) {
        self.controller = controller
        let folder = Self.supportFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Tells the helper where this copy of the app lives, so it can open it when it isn't running.
        try? Bundle.main.bundlePath.write(to: folder.appendingPathComponent("app-path"),
                                          atomically: true, encoding: .utf8)

        let path = Self.socketPath
        unlink(path)                       // a socket left over from the last run
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { NSLog("1Shot: MCP socket failed (\(errno))"); return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            NSLog("1Shot: MCP socket path is too long: \(path)")
            close(fd)
            return
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in raw.copyBytes(from: bytes) }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            NSLog("1Shot: MCP socket couldn't listen (\(errno))")
            close(fd)
            return
        }
        chmod(path, 0o600)                 // only you
        listenFD = fd
        acceptQueue.async { [weak self] in self?.acceptLoop(fd) }
        NSLog("1Shot: MCP control ready at \(path)")
    }

    func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(Self.socketPath)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return                      // the socket was closed (app quitting)
            }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            Thread.detachNewThread { [weak self] in self?.serve(client) }
        }
    }

    /// One connection: read lines, answer each one (answers can arrive out of order; they carry the id).
    private func serve(_ fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        let writeLock = NSLock()
        let pending = DispatchGroup()
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !line.isEmpty else { continue }
                pending.enter()
                handle(line) { reply in
                    writeLock.lock()
                    Self.writeAll(fd, reply)
                    writeLock.unlock()
                    pending.leave()
                }
            }
        }
        pending.wait()
        close(fd)
    }

    private func handle(_ line: Data, reply: @escaping (Data) -> Void) {
        guard let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let command = request["command"] as? String else {
            reply(Self.encode(["id": NSNull(), "ok": false, "error": "That request wasn't valid JSON with a \"command\"."]))
            return
        }
        let id: Any = request["id"] ?? NSNull()
        let args = request["args"] as? [String: Any] ?? [:]
        DispatchQueue.main.async { [weak self] in
            guard let controller = self?.controller else {
                reply(Self.encode(["id": id, "ok": false, "error": "1Shot's window isn't ready yet. Try again in a moment."]))
                return
            }
            controller.mcpHandle(command, args) { outcome in
                switch outcome {
                case .success(let value):
                    reply(Self.encode(["id": id, "ok": true, "result": value]))
                case .failure(let error):
                    reply(Self.encode(["id": id, "ok": false, "error": error.localizedDescription]))
                }
            }
        }
    }

    static func encode(_ object: [String: Any]) -> Data {
        var data: Data
        if JSONSerialization.isValidJSONObject(object),
           let d = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) {
            data = d
        } else {
            let id = (object["id"] as? NSNumber).map { "\($0)" } ?? "null"
            data = Data("{\"id\":\(id),\"ok\":false,\"error\":\"The app couldn't encode its answer.\"}".utf8)
        }
        data.append(0x0A)
        return data
    }

    private static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var p = raw.baseAddress else { return }
            var left = raw.count
            while left > 0 {
                let n = write(fd, p, left)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return }
                p = p.advanced(by: n)
                left -= n
            }
        }
    }
}

// MARK: - Helpers

typealias MCPOutcome = Result<Any, Error>
typealias MCPReply = (MCPOutcome) -> Void

struct MCPError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A long job (transcript, B-roll downloads). Main thread only. The tool call waits up to
/// `MCP.waitLimit` seconds; after that Claude gets "still running" and checks back with `status`.
final class MCPJob {
    let name: String
    let started = Date()
    var message = "Starting…"
    var fraction: Double?
    private(set) var finished = false
    private(set) var outcome: MCPOutcome?
    private var waiters: [MCPReply] = []

    init(name: String) { self.name = name }

    func finish(_ outcome: MCPOutcome) {
        guard !finished else { return }
        finished = true
        self.outcome = outcome
        let list = waiters
        waiters = []
        list.forEach { $0(outcome) }
    }

    func addWaiter(_ w: @escaping MCPReply) { waiters.append(w) }

    var json: [String: Any] {
        var j: [String: Any] = ["job": name, "running": !finished,
                                "seconds": MCP.r(Date().timeIntervalSince(started), 1)]
        if !finished {
            j["message"] = message
            j["progress"] = MCP.orNull(fraction.map { MCP.r($0, 2) })
        } else if case .failure(let e)? = outcome {
            j["error"] = e.localizedDescription
        } else {
            j["finished"] = true
        }
        return j
    }
}

enum MCP {
    /// Longest a tool call waits for a job before answering "still running".
    static let waitLimit = 45.0
    static var job: MCPJob?

    static func r(_ x: Double, _ places: Int = 2) -> Double {
        guard x.isFinite else { return 0 }
        let k = pow(10, Double(places))
        return (x * k).rounded() / k
    }

    static func num(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    static func orNull(_ v: Any?) -> Any { v ?? NSNull() }

    static func tc(_ t: Double) -> String { TrimBar.format(t) }

    /// Any Codable value as plain JSON (dictionaries, arrays, numbers…).
    static func json<T: Encodable>(_ value: T) -> Any {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return NSNull() }
        return object
    }

    /// Text for a list that may arrive as a JSON string, an object, or a bare array.
    static func text(of value: Any) throws -> String {
        if let s = value as? String { return s }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let s = String(data: data, encoding: .utf8) else { throw MCPError("That list isn't valid JSON.") }
        return s
    }

    /// The JSON object inside a list's text (to read fields the parsers ignore, like `review`).
    static func object(in text: String) -> [String: Any]? {
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b,
              let data = String(text[a...b]).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Checks `condition` every 0.1 s on the main thread until it's true or time runs out.
    static func poll(until deadline: Date, _ condition: @escaping () -> Bool, then: @escaping (Bool) -> Void) {
        if condition() { then(true); return }
        if Date() >= deadline { then(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MCP.poll(until: deadline, condition, then: then) }
    }

    /// Answers `done` when the job finishes, or with "still running" after `seconds`.
    static func wait(for job: MCPJob, upTo seconds: Double, _ done: @escaping MCPReply) {
        if job.finished, let outcome = job.outcome { done(outcome); return }
        final class Once { var fired = false }
        let once = Once()
        job.addWaiter { outcome in
            guard !once.fired else { return }
            once.fired = true
            done(outcome)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds)) {
            guard !once.fired else { return }
            once.fired = true
            var j = job.json
            j["hint"] = "Still working. Call status with wait: 45 to wait for it to finish."
            done(.success(j))
        }
    }

    /// JPEG of a frame, at most `maxWidth` wide.
    static func jpeg(_ image: CGImage, maxWidth: Int) -> (data: Data, width: Int, height: Int)? {
        var img = image
        if image.width > maxWidth {
            let w = maxWidth
            let h = max(1, Int((Double(image.height) * Double(maxWidth) / Double(image.width)).rounded()))
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            if let scaled = ctx.makeImage() { img = scaled }
        }
        guard let data = NSBitmapImageRep(cgImage: img).representation(using: .jpeg, properties: [.compressionFactor: 0.82])
        else { return nil }
        return (data, img.width, img.height)
    }

    static func db(_ linear: Float) -> Double {
        linear > 0.000_01 ? r(20 * log10(Double(linear)), 1) : -100
    }
}

// MARK: - Commands

extension PlayerWindowController {

    func mcpHandle(_ command: String, _ args: [String: Any], _ done: @escaping MCPReply) {
        // Follow along (2026-11-11): each pipeline step switches the app to its own tab,
        // so the panel and timeline show what Claude just changed.
        let stepTab: [String: WorkspaceTab] = [
            "set_visual": .visualDesign, "set_sound": .soundDesign,
            "apply_cuts": .cuts, "apply_zooms": .zooms,
            "apply_broll": .broll, "broll_candidates": .broll, "save_to_broll_library": .broll,
            "graphics_preview": .graphics, "apply_graphics": .graphics,
            "adjust_graphics": .graphics, "graphics_style": .graphics
        ]
        if let tab = stepTab[command], player != nil { selectTab(tab) }
        if command == "set_visual" || command == "get_settings" { activateArollGroup() }
        do {
            switch command {
            case "status":            try mcpStatusCommand(args, done)
            case "open_project":      try mcpOpenProject(args, done)
            case "snapshot_frame":    try mcpSnapshot(args, done)
            case "get_settings":      try mcpGetSettings(args, done)
            case "set_visual":        done(.success(try mcpSetVisual(args)))
            case "set_sound":         done(.success(try mcpSetSound(args)))
            case "set_trim":          done(.success(try mcpSetTrim(args)))
            case "create_transcript": try mcpCreateTranscript(args, done)
            case "read_transcript":   done(.success(try mcpReadTranscript(args)))
            case "apply_cuts":        done(.success(try mcpApplyCuts(args)))
            case "apply_zooms":       done(.success(try mcpApplyZooms(args)))
            case "apply_broll":       try mcpApplyBroll(args, done)
            case "broll_candidates":  try mcpBrollCandidates(args, done)
            case "save_to_broll_library": try mcpSaveToBrollLibrary(args, done)
            case "seek":              try mcpSeek(args, done)
            case "graphics_templates": done(.success(mcpGraphicsTemplates()))
            case "graphics_preview":  try mcpGraphicsPreview(args, done)
            case "apply_graphics":    try mcpApplyGraphics(args, done)
            case "adjust_graphics":   done(.success(try mcpAdjustGraphics(args)))
            case "graphics_style":    done(.success(try mcpGraphicsStyle(args)))
            default: throw MCPError("1Shot doesn't know the command “\(command)”.")
            }
        } catch {
            done(.failure(error))
        }
    }

    // MARK: Checks

    /// Commands that change things wait for exports, dialogs and running jobs.
    private func mcpRequireIdle() throws {
        if isExporting { throw MCPError("An export or a loudness measurement is running in 1Shot. Wait for it to finish.") }
        if let job = MCP.job, !job.finished {
            throw MCPError("“\(job.name)” is still running (\(job.message)). Call status with wait: 45 until it's done.")
        }
        if window?.attachedSheet != nil || NSApp.modalWindow != nil {
            throw MCPError("A dialog or sheet is open in 1Shot. Ask the user to close it, then try again.")
        }
        if pendingRestore != nil { throw MCPError("The project is still loading. Try again in a moment.") }
    }

    @discardableResult
    private func mcpRequireClip() throws -> (asset: AVAsset, duration: Double) {
        guard player != nil, let asset = sourceAsset, trimBar.duration > 0, pendingRestore == nil else {
            throw MCPError("No video is open yet. Use open_project first.")
        }
        return (asset: asset, duration: trimBar.duration)
    }

    private var mcpTrim: (start: Double, end: Double) {
        trimRange ?? (start: 0, end: trimBar.duration)
    }

    // MARK: status

    private func mcpStatusCommand(_ args: [String: Any], _ done: @escaping MCPReply) throws {
        let wait = min(MCP.waitLimit, max(0, MCP.num(args["wait"]) ?? 0))
        guard wait > 0, let job = MCP.job, !job.finished else { done(.success(mcpStatus())); return }
        MCP.wait(for: job, upTo: wait) { [weak self] outcome in
            guard let self else { return }
            var s = self.mcpStatus()
            switch outcome {
            case .success(let value): if job.finished { s["jobResult"] = value }
            case .failure(let error): s["jobError"] = error.localizedDescription
            }
            done(.success(s))
        }
    }

    func mcpStatus() -> [String: Any] {
        var s: [String: Any] = [
            "app": "1Shot",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        ]
        if let project {
            s["project"] = ["name": project.name, "folder": project.folder.path,
                            "video": MCP.orNull(project.data.video),
                            "transcript": MCP.orNull(currentTranscript() == nil ? nil : project.data.transcript),
                            "transcriptOutOfDate": transcriptIsOutOfDate] as [String: Any]
        } else {
            s["project"] = NSNull()
        }
        if sourceAsset != nil, trimBar.duration > 0 {
            let trim = mcpTrim
            let removed = CutList.totalLength(CutList.normalized(cuts, trim: trim))
            // A composition built from the Assets tab (3.1.0) has no single file of its own.
            s["clip"] = [
                "file": currentVideo?.lastPathComponent ?? "\(project?.name ?? "Untitled") (A-roll)",
                "path": MCP.orNull(currentVideo?.path),
                "duration": MCP.r(trimBar.duration), "durationTC": MCP.tc(trimBar.duration),
                "fps": MCP.r(TrimBar.frameRate, 3)
            ] as [String: Any]
            s["trim"] = ["start": MCP.r(trim.start), "end": MCP.r(trim.end),
                         "startTC": MCP.tc(trim.start), "endTC": MCP.tc(trim.end), "trimmed": isTrimmed] as [String: Any]
            s["edit"] = ["cuts": cuts.count, "secondsCut": MCP.r(removed),
                         "editedLength": MCP.r(trim.end - trim.start - removed),
                         "editedLengthTC": MCP.tc(trim.end - trim.start - removed),
                         "zooms": zooms.count, "broll": broll.count, "graphics": graphics.count,
                         "brollNotDownloaded": broll.filter { $0.file == nil }.count] as [String: Any]
            s["playhead"] = MCP.r(trimBar.playhead)
            s["playing"] = (player?.rate ?? 0) != 0
        } else {
            s["clip"] = NSNull()
        }
        s["workspaceTab"] = currentTab.title
        s["exporting"] = isExporting
        s["dialogOpen"] = window?.attachedSheet != nil || NSApp.modalWindow != nil
        s["loading"] = pendingRestore != nil
        s["job"] = MCP.orNull(MCP.job?.json)
        return s
    }

    // MARK: open_project

    private func mcpOpenProject(_ args: [String: Any], _ done: @escaping MCPReply) throws {
        try mcpRequireIdle()
        let fm = FileManager.default
        func url(_ key: String) -> URL? {
            guard let s = args[key] as? String, !s.isEmpty else { return nil }
            return URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        }

        if let path = url("path") {
            // Check it first, so a problem comes back to Claude instead of as an alert on screen.
            let check = try Project.open(path)
            // A project built from the Assets tab (3.1.0) has clips there instead of a single video.
            let hasAssets = check.data.assets?.contains(where: { !$0.rejected }) == true
            let video = check.videoURL
            guard hasAssets || (video != nil && fm.fileExists(atPath: video!.path)) else {
                throw MCPError("“\(check.name)” has no video in its Media folder yet. Make a new project with name + video instead.")
            }
            showWindow(nil)
            openProject(path)
            mcpFinishOpen(expect: hasAssets ? nil : video, done)

        } else if let name = args["name"] as? String, let video = url("video") {
            guard fm.fileExists(atPath: video.path) else { throw MCPError("There's no video at \(video.path).") }
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            guard !clean.isEmpty else { throw MCPError("Give the project a name.") }
            let parent = url("location") ?? Project.defaultLocation
            saveProject()
            let created = try Project.create(at: parent.appendingPathComponent(clean, isDirectory: true))
            showWindow(nil)
            project = created
            pendingRestore = nil
            RecentFiles.add(created.fileURL)
            updateWindowTitle()
            resetAllSettings()                         // a new project starts from the default settings
            NSLog("1Shot: MCP made a new project at \(created.folder.path)")
            created.importVideo(video) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    done(.failure(MCPError("The project was made, but the video couldn't be copied in: \(error.localizedDescription)")))
                case .success(let copy):
                    guard self.project === created else { done(.failure(MCPError("Another project was opened meanwhile."))); return }
                    created.data.video = created.relativePath(of: copy)
                    self.load(copy)
                    self.saveProject()
                    self.mcpFinishOpen(expect: copy, done)
                }
            }

        } else if let video = url("video") {
            guard fm.fileExists(atPath: video.path) else { throw MCPError("There's no video at \(video.path).") }
            if project != nil { closeProject() }
            showWindow(nil)
            load(video)
            mcpFinishOpen(expect: video, done)

        } else {
            throw MCPError("Pass path (an existing project), name + video (a new project), or video alone (no project).")
        }
    }

    /// Waits for the clip to load and the project's settings to come back, then pauses it
    /// (opening a video normally starts playing) and answers with the status and the first frame.
    /// `video` is nil for a project built from the Assets tab (3.1.0) — there's no single file
    /// to wait for, so this just waits for something (the assembled composition) to be loaded.
    private func mcpFinishOpen(expect video: URL?, _ done: @escaping MCPReply) {
        let want = video?.standardizedFileURL
        MCP.poll(until: Date().addingTimeInterval(30), { [weak self] in
            guard let self else { return true }
            guard self.trimBar.duration > 0, self.pendingRestore == nil else { return false }
            guard let want else { return self.sourceAsset != nil }
            return (self.sourceAsset as? AVURLAsset)?.url.standardizedFileURL == want
        }, then: { [weak self] loaded in
            guard let self else { return }
            guard loaded else { done(.failure(MCPError("The video took more than 30 seconds to open. Call status to check on it."))); return }
            self.player?.pause()
            let at = self.mcpTrim.start
            self.mcpFrame(at: at, graded: true, maxWidth: 960) { frame in
                var s = self.mcpStatus()
                switch frame {
                case .success(let image): s["image"] = image; s["frameAt"] = MCP.r(at)
                case .failure(let error): s["frameError"] = error.localizedDescription
                }
                done(.success(s))
            }
        })
    }

    // MARK: snapshot_frame

    private func mcpSnapshot(_ args: [String: Any], _ done: @escaping MCPReply) throws {
        let (_, duration) = try mcpRequireClip()
        let graded = args["graded"] as? Bool ?? true
        let maxWidth = Int(min(1920, max(320, MCP.num(args["maxWidth"]) ?? 1280)))
        var times: [Double] = []
        if let list = args["times"] as? [Any] { times = list.compactMap { MCP.num($0) } }
        if let t = MCP.num(args["at"]) { times = [t] }
        if times.isEmpty { times = [trimBar.playhead] }
        guard times.count <= 6 else { throw MCPError("At most 6 frames at a time.") }
        times = times.map { min(max(0, $0), max(0, duration - 0.02)) }

        var images: [[String: Any]] = []
        func next(_ i: Int) {
            guard i < times.count else {
                var out: [String: Any] = ["graded": graded]
                if images.count == 1 { out["image"] = images[0] } else { out["images"] = images }
                done(.success(out))
                return
            }
            let t = times[i]
            mcpFrame(at: t, graded: graded, maxWidth: maxWidth) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error): done(.failure(error))
                case .success(var image):
                    image["at"] = MCP.r(t)
                    image["atTC"] = MCP.tc(t)
                    image["insideCut"] = CutList.cut(containing: t, in: self.cuts) != nil
                    image["zoomScale"] = MCP.r(ZoomList.scale(at: t, in: self.zooms))
                    image["brollShowing"] = self.mcpBrollShowing(at: t)
                    images.append(image)
                    next(i + 1)
                }
            }
        }
        next(0)
    }

    private func mcpBrollShowing(at t: Double) -> Bool {
        let edited = t - CutList.removed(before: t, cuts: cuts)
        return broll.contains { c in
            let start = c.at - CutList.removed(before: c.at, cuts: cuts)
            return edited >= start && edited < start + c.length && c.file != nil
        }
    }

    /// One frame as the export would show it (graded = true: stabilization, zoom, LUTs, color, B-roll)
    /// or as recorded (graded = false: stabilized only, like the eyedropper sees it).
    func mcpFrame(at t: Double, graded: Bool, maxWidth: Int, _ done: @escaping (Result<[String: Any], Error>) -> Void) {
        guard let asset = sourceAsset else { done(.failure(MCPError("No video is open."))); return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.videoComposition = graded ? grade.makeVideoComposition(for: asset, honorsBypass: false)
                                            : grade.makeEyedropperComposition(for: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = CMTime(seconds: t, preferredTimescale: 60_000)
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, result, error in
            let encoded = (result == .succeeded) ? image.flatMap { MCP.jpeg($0, maxWidth: maxWidth) } : nil
            DispatchQueue.main.async {
                _ = generator          // keep it alive until it's done
                guard let encoded else {
                    done(.failure(MCPError("Couldn't grab the frame at \(MCP.tc(t)): \(error?.localizedDescription ?? "unknown error")")))
                    return
                }
                done(.success(["mimeType": "image/jpeg", "data": encoded.data.base64EncodedString(),
                               "width": encoded.width, "height": encoded.height]))
            }
        }
    }

    // MARK: get_settings

    private func mcpGetSettings(_ args: [String: Any], _ done: @escaping MCPReply) throws {
        var out: [String: Any] = [:]
        let visual = exportDrawer.snapshot
        out["visualDesign"] = [
            "settings": MCP.json(visual),
            "stabilizer": ["analyzed": stabilizer.isAnalyzed, "on": stabilizer.enabled,
                           "zoomPercent": MCP.orNull(stabilizer.zoomPercent.map { MCP.r($0, 1) })] as [String: Any],
            "lutLibrary": CubeLUT.libraryFiles().map { $0.lastPathComponent },
            "howToRead": "Order: stabilize → zoom → white balance (Color = temperature, Tint) → Camera LUT → Creative LUT → Levels and the other sliders. Sliders run −100…+100 (Sharpen and Denoise 0…100), 0 = untouched; they're deliberately gentle (±100 is about half of Core Image's full range). blackPoint/whitePoint are Levels (0…1). 'bypassed' lists sliders switched off (red). colorBypass is a preview-only before/after; export is always graded. fade = 0.5 s fade to black at the end plus 2 s of black."
        ] as [String: Any]
        let sound = drawer.snapshot
        out["soundDesign"] = [
            "settings": MCP.json(sound),
            "readable": mcpReadable(sound),
            "chain": "voice isolation → high pass → noise gate → compressor → de-esser → limiter (ceiling −0.1 dB) → output"
        ] as [String: Any]
        let meter = rack.meterReading()
        out["outputMeterNow"] = ["peakDB": meter.peak.map { MCP.db($0) }, "rmsDB": meter.rms.map { MCP.db($0) },
                                 "note": "Live, only while playing; −100 = silence."] as [String: Any]
        let live = rack.loudnessReading()
        out["loudnessMeterNow"] = ["momentaryLUFS": MCP.orNull(live.momentary.map { MCP.r($0, 1) }),
                                   "shortTermLUFS": MCP.orNull(live.shortTerm.map { MCP.r($0, 1) }),
                                   "integratedLUFS": MCP.orNull(live.integrated.map { MCP.r($0, 1) }),
                                   "secondsPlayed": MCP.r(live.seconds, 1),
                                   "note": "Live meters in Sound Design: integrated covers only what has been played since the clip or edit last changed. Use measure: true for the whole edit."] as [String: Any]
        out["exportNormalizesTo"] = MCP.orNull(UserDefaults.standard.bool(forKey: "NormalizeLoudness") ? LUFSMeter.target : nil)

        guard args["measure"] as? Bool == true else { done(.success(out)); return }
        let (asset, _) = try mcpRequireClip()
        let trim = mcpTrim
        let kept = CutList.keptSegments(start: trim.start, end: trim.end, cuts: CutList.normalized(cuts, trim: trim))
        let base = out
        Task { @MainActor in
            do {
                let loudness = try await Task.detached(priority: .userInitiated) {
                    try await Loudness.measure(asset: asset, keep: kept)
                }.value
                var result = base
                result["originalAudio"] = loudness
                // Then the whole edit through Sound Design, exactly as the export renders it.
                self.scanEditLoudness { scan in
                    switch scan {
                    case .success(let r):
                        result["afterSoundDesign"] = [
                            "integratedLUFS": MCP.orNull(r.integrated.map { MCP.r($0, 1) }),
                            "offTargetLU": MCP.orNull(r.integrated.map { MCP.r($0 - LUFSMeter.target, 1) }),
                            "target": LUFSMeter.target,
                            "samplePeakDBFS": MCP.r(r.peakDB, 1),
                            "howToRead": "The whole trimmed, cut edit rendered through every Sound Design stage, like the export. Export for YouTube can normalize to −14 LUFS (a checkbox in its save sheet, on by default): it raises the level through the limiter, so peaks still stay under −0.1 dB."
                        ] as [String: Any]
                    case .failure(let error):
                        result["afterSoundDesignError"] = error.localizedDescription
                    }
                    done(.success(result))
                }
            } catch {
                done(.failure(error))
            }
        }
    }

    /// The Sound Design sliders in plain units.
    private func mcpReadable(_ s: SoundDesignPanel.Snapshot) -> [String: Any] {
        func v(_ k: String) -> Double { s.values[k] ?? 0 }
        let hp = v("highPass") < 0.5 ? 0 : 20 * pow(400.0 / 20.0, (v("highPass") - 1) / 99)
        let ratio = (v("compRatio") * 10).rounded() / 10
        return [
            "voiceIsolation": v("isolationAmount").rounded() < 1 ? "off" : "\(Int(v("isolationAmount").rounded()))% wet",
            "isolationModel": v("isolationModel") >= 0.5 ? "High Quality Voice" : "Voice",
            "highPass": hp == 0 ? "off" : "\(Int(hp.rounded())) Hz",
            "gate": v("gateRange").rounded() > -0.5 ? "off"
                : "threshold \(Int(v("gateThreshold").rounded())) dB, range \(Int(v("gateRange").rounded())) dB",
            "compressor": ratio <= 1.01 ? "off"
                : String(format: "threshold %ld dB, ratio %.1f:1, make-up +%.1f dB",
                         Int(v("compThreshold").rounded()), ratio, (v("compMakeup") * 2).rounded() / 2),
            "deEsser": v("deEssAmount").rounded() < 1 ? "off"
                : String(format: "%.1f kHz, amount %ld", (v("deEssFrequency") * 10).rounded() / 10, Int(v("deEssAmount").rounded())),
            "limiter": String(format: "input +%.1f dB into a −0.1 dB ceiling", (v("limiterInput") * 2).rounded() / 2),
            "bypassedSections": s.bypassed
        ]
    }

    // MARK: set_visual

    private func mcpSetVisual(_ args: [String: Any]) throws -> Any {
        try mcpRequireIdle()
        var snap = exportDrawer.snapshot
        let names = snap.sliders.keys.sorted()
        func sliderName(_ k: String) throws -> String {
            guard let n = names.first(where: { $0.caseInsensitiveCompare(k) == .orderedSame }) else {
                throw MCPError("There's no “\(k)” slider. Sliders: \(names.joined(separator: ", ")).")
            }
            return n
        }
        if let sliders = args["sliders"] as? [String: Any] {
            for (k, value) in sliders {
                let n = try sliderName(k)
                guard let d = MCP.num(value) else { throw MCPError("\(n) needs a number.") }
                let low = (n == "Sharpen" || n == "Denoise") ? 0.0 : -100.0
                snap.sliders[n] = min(100, max(low, d.rounded()))
            }
        }
        if let off = args["bypassed"] as? [String] { snap.bypassed = try off.map(sliderName) }
        if let b = MCP.num(args["blackPoint"]) { snap.blackPoint = min(0.5, max(0, b)) }
        if let w = MCP.num(args["whitePoint"]) { snap.whitePoint = min(1, max(0.5, w)) }

        let library = CubeLUT.libraryFiles().map { $0.lastPathComponent }
        func lut(_ key: String) throws -> String?? {
            guard let value = args[key] else { return .none }                 // not given: leave it
            if value is NSNull { return .some(nil) }
            guard let name = value as? String else { throw MCPError("\(key) should be a LUT file name or null.") }
            if name.isEmpty || name.lowercased() == "none" { return .some(nil) }
            guard library.contains(name) || self.project?.lutCopy(named: name) != nil else {
                throw MCPError("No LUT named “\(name)”. LUTs: \(library.joined(separator: ", ")).")
            }
            return .some(name)
        }
        if let camera = try lut("cameraLUT") { snap.cameraLUT = camera }
        if let creative = try lut("creativeLUT") { snap.creativeLUT = creative }
        if let x = MCP.num(args["smoothness"]) { snap.smoothness = min(100, max(0, x.rounded())) }
        if let x = MCP.num(args["maxCrop"]) { snap.maxCrop = min(20, max(2, x.rounded())) }
        if let x = args["fade"] as? Bool { snap.fade = x }
        if let x = args["colorBypass"] as? Bool { snap.colorBypass = x }

        let openProject = self.project
        exportDrawer.restore(snap) { name in
            if let inLibrary = CubeLUT.libraryFiles().first(where: { $0.lastPathComponent == name }) { return inLibrary }
            guard let kept = openProject?.lutCopy(named: name) else { return nil }
            return try? CubeLUT.importToLibrary(kept)
        }
        var note: String?
        if let on = args["stabilize"] as? Bool {
            if on && !stabilizer.isAnalyzed {
                try mcpRequireClip()
                analyzeStabilization()
                note = "Stabilization is analyzing the clip (progress shows in Visual Design); it turns on when done."
            } else {
                stabilizer.enabled = on && stabilizer.isAnalyzed
                updateStabilizeUI()
                refreshFrame()
            }
        }
        saveProject()
        var out: [String: Any] = ["visualDesign": MCP.json(exportDrawer.snapshot),
                                  "stabilizer": ["analyzed": stabilizer.isAnalyzed, "on": stabilizer.enabled]]
        if let note { out["note"] = note }
        return out
    }

    // MARK: set_sound

    private func mcpSetSound(_ args: [String: Any]) throws -> Any {
        try mcpRequireIdle()
        var snap = drawer.snapshot
        let ranges: [String: ClosedRange<Double>] = [
            "isolationAmount": 0...100, "isolationModel": 0...1, "highPass": 0...100,
            "gateThreshold": -80...0, "gateRange": -40...0,
            "compThreshold": -40...0, "compRatio": 1...10, "compMakeup": 0...24,
            "deEssFrequency": 4...10, "deEssAmount": 0...100, "limiterInput": 0...24
        ]
        for (key, value) in args where key != "bypassed" {
            if key == "highPassHz" {
                guard let hz = MCP.num(value) else { throw MCPError("highPassHz needs a number (0 = off).") }
                snap.values["highPass"] = hz < 20 ? 0 : 1 + 99 * log(min(400, hz) / 20) / log(400.0 / 20.0)
                continue
            }
            if key == "isolationModel", let name = value as? String {
                snap.values[key] = name.lowercased().contains("h") ? 1 : 0       // "HQV" / "High Quality Voice" or "Voice"
                continue
            }
            guard let range = ranges[key] else {
                throw MCPError("Unknown Sound Design setting “\(key)”. Settings: highPassHz, \(ranges.keys.sorted().joined(separator: ", ")), bypassed.")
            }
            guard let d = MCP.num(value) else { throw MCPError("\(key) needs a number.") }
            snap.values[key] = min(range.upperBound, max(range.lowerBound, d))
        }
        if let off = args["bypassed"] as? [String] {
            let stages = ["isolation", "gate", "compressor", "deEsser", "limiter"]
            snap.bypassed = try off.map { (name: String) throws -> String in
                guard let s = stages.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
                    throw MCPError("“\(name)” can't be bypassed. Sections: \(stages.joined(separator: ", ")).")
                }
                return s
            }
        }
        drawer.restore(snap)
        saveProject()
        let now = drawer.snapshot
        return ["soundDesign": MCP.json(now), "readable": mcpReadable(now)] as [String: Any]
    }

    // MARK: set_trim

    private func mcpSetTrim(_ args: [String: Any]) throws -> Any {
        try mcpRequireIdle()
        let (_, duration) = try mcpRequireClip()
        if args["reset"] as? Bool == true {
            resetTrim()
        } else {
            let current = mcpTrim
            let s = MCP.num(args["start"]) ?? current.start
            let e = min(duration, MCP.num(args["end"]) ?? current.end)
            guard s >= 0, e - s > 0.05 else {
                throw MCPError("The trim has to start at 0 or later and end after it starts (clip is \(MCP.r(duration)) s).")
            }
            trimBar.start = s
            trimBar.end = e
            trimChanged(start: s, end: e, movingStart: false, finished: true)
        }
        saveProject()
        let trim = mcpTrim
        var out: [String: Any] = ["start": MCP.r(trim.start), "end": MCP.r(trim.end),
                                  "startTC": MCP.tc(trim.start), "endTC": MCP.tc(trim.end),
                                  "length": MCP.r(trim.end - trim.start), "lengthTC": MCP.tc(trim.end - trim.start)]
        if let t = mcpLoadTranscript()?.transcript {
            let inside = t.words.filter { $0.s >= trim.start - 0.01 && $0.e <= trim.end + 0.01 }
            out["firstWords"] = inside.prefix(10).map(\.w).joined(separator: " ")
            out["lastWords"] = inside.suffix(10).map(\.w).joined(separator: " ")
            out["firstWordAt"] = MCP.orNull(inside.first.map { MCP.r($0.s) })
            out["lastWordEndsAt"] = MCP.orNull(inside.last.map { MCP.r($0.e) })
        }
        let outside = cuts.filter { $0.end <= trim.start || $0.start >= trim.end }.count
        if outside > 0 { out["note"] = "\(outside) cut\(outside == 1 ? " is" : "s are") outside the new trim and won't be used." }
        return out
    }

    // MARK: Transcript

    func mcpLoadTranscript() -> (transcript: EditTranscript, url: URL)? { currentTranscript() }

    private func mcpCreateTranscript(_ args: [String: Any], _ done: @escaping MCPReply) throws {
        try mcpRequireIdle()
        try mcpRequireClip()
        guard let project else { throw MCPError("Edit transcripts are saved in a project. Use open_project with name + video first.") }
        guard let target = transcriptSource else {
            throw MCPError(currentVideo != nil
                ? "The open video isn't in this project's Media folder yet."
                : "Nothing to transcribe yet: build the A-roll in the Assets tab first.")
        }
        guard TranscriptMaker.isAvailable else { throw TranscriptMaker.TranscriptError.needsMacOS26 }
        guard let window else { throw MCPError("The app window isn't available.") }
        player?.pause()
        let trim = isTrimmed ? trimRange : nil
        let fps = TrimBar.frameRate
        let job = MCPJob(name: "create_transcript")
        MCP.job = job
        let sheet = TaskProgressSheet(title: "Claude is making the edit transcript for “\(target.name)”")
        window.beginSheet(sheet.window, completionHandler: nil)
        let started = Date()
        Task { @MainActor in
            let say: (String, Double?) -> Void = { message, fraction in
                sheet.update(message, fraction)
                job.message = message
                job.fraction = fraction
            }
            do {
                say("Listening for pauses (voice isolation at 100%)…", 0)
                let isolated = try await TranscriptMaker.isolatedLevels(asset: target.asset) { fraction in
                    DispatchQueue.main.async { say("Listening for pauses (voice isolation at 100%)…", fraction) }
                }
                let transcript = try await TranscriptMaker.make(asset: target.asset, name: target.name,
                                                                source: target.source, fps: fps, trim: trim,
                                                                isolatedLevels: isolated) { message, fraction in
                    say(message, fraction)
                }
                let json = try TranscriptMaker.write(transcript, to: project.transcriptsFolder)
                window.endSheet(sheet.window)
                project.data.transcript = project.relativePath(of: json)
                self.saveProject()
                NSLog("1Shot: MCP transcript done — %d words, %d pauses", transcript.words.count, transcript.silences.count)
                job.finish(.success([
                    "transcript": project.relativePath(of: json),
                    "words": transcript.words.count, "pauses": transcript.silences.count,
                    "seconds": MCP.r(Date().timeIntervalSince(started), 0),
                    "next": "Call read_transcript to get it."
                ] as [String: Any]))
            } catch {
                window.endSheet(sheet.window)
                job.finish(.failure(error))
            }
        }
        MCP.wait(for: job, upTo: MCP.waitLimit, done)
    }

    private func mcpReadTranscript(_ args: [String: Any]) throws -> Any {
        guard let loaded = mcpLoadTranscript() else {
            throw MCPError(transcriptIsOutOfDate
                ? "This project's edit transcript is out of date (made before the A-roll was rebuilt, or for another clip). Call create_transcript again."
                : "This project has no edit transcript yet. Call create_transcript first.")
        }
        var t = loaded.transcript
        let url = loaded.url
        let made = (t.trimStart, t.trimEnd)
        // The style guides read trimStart/trimEnd as the project's in/out, so give the trim as it is NOW.
        if player != nil, trimBar.duration > 0 {
            let trim = mcpTrim
            t.trimStart = trim.start
            t.trimEnd = trim.end
        }
        let from = MCP.num(args["from"]) ?? -Double.infinity
        let to = MCP.num(args["to"]) ?? Double.infinity
        if from.isFinite || to.isFinite {
            t.words = t.words.filter { $0.e > from && $0.s < to }
            t.segments = t.segments.filter { $0.e > from && $0.s < to }
            t.silences = t.silences.filter { $0.e > from && $0.s < to }
        }
        let stale = currentVideo.map { $0.lastPathComponent != t.clip } ?? false
        if (args["format"] as? String)?.lowercased() == "text" {
            var text = TranscriptMaker.readable(t)
            if stale { text = "NOTE: this transcript is for \(t.clip), not the open video.\n" + text }
            return ["file": url.path, "text": text] as [String: Any]
        }
        var out: [String: Any] = ["file": url.path, "transcript": MCP.json(t),
                                  "trimWhenMade": ["start": MCP.orNull(made.0), "end": MCP.orNull(made.1)] as [String: Any],
                                  "note": "trimStart/trimEnd are the project's trim right now. Times are original-clip seconds."]
        if stale { out["warning"] = "This transcript is for \(t.clip), not the open video. Make a new one with create_transcript." }
        return out
    }

    // MARK: apply_cuts

    private func mcpApplyCuts(_ args: [String: Any]) throws -> Any {
        try mcpRequireIdle()
        try mcpRequireClip()
        let mode = (args["mode"] as? String)?.lowercased() ?? "replace"
        guard ["replace", "add", "clear"].contains(mode) else { throw MCPError("mode is replace, add or clear.") }
        let before = cuts
        if mode == "clear" {
            setCuts([])
        } else {
            guard let payload = args["cutList"] ?? args["cuts"].map({ ["cuts": $0] as Any }) else {
                throw MCPError("Pass cuts (a list of {start, end, reason, note}) or cutList (the style guide's whole JSON).")
            }
            let text = try MCP.text(of: payload)
            let (incoming, _) = try CutList.parse(text)
            let object = MCP.object(in: text)
            setCuts(mode == "add" ? before + incoming : incoming)
            suggestedCuts = cuts
            suggestedFrom = "Claude (MCP)"
            suggestedStyleGuide = args["styleGuide"] as? String ?? object?["styleGuide"] as? String ?? suggestedStyleGuide
        }
        saveProject()

        let trim = mcpTrim
        let transcript = mcpLoadTranscript()?.transcript
        var warnings: [String] = []
        let list: [[String: Any]] = cuts.map { c -> [String: Any] in
            var item: [String: Any] = ["start": MCP.r(c.start), "end": MCP.r(c.end), "length": MCP.r(c.length),
                                       "startTC": MCP.tc(c.start), "reason": MCP.orNull(c.reason), "note": MCP.orNull(c.note)]
            if let words = transcript?.words {
                let removed = words.filter { ($0.s + $0.e) / 2 >= c.start && ($0.s + $0.e) / 2 < c.end }
                item["removesWords"] = removed.map(\.w).joined(separator: " ")
                for edge in [c.start, c.end] {
                    if let w = words.first(where: { edge > $0.s + 0.02 && edge < $0.e - 0.02 && $0.e - $0.s < 1.5 }) {
                        warnings.append("The cut at \(MCP.tc(c.start)) has an edge inside the word “\(w.w)”.")
                    }
                }
            }
            if c.length < 1.0, !["false-start", "retake"].contains(c.reason ?? "") {
                warnings.append("The cut at \(MCP.tc(c.start)) is \(MCP.r(c.length)) s, under 1 s, and isn't marked false-start or retake.")
            }
            return item
        }
        let removed = CutList.totalLength(cuts)
        var out: [String: Any] = [
            "cutCount": cuts.count, "secondsRemoved": MCP.r(removed),
            "newLength": MCP.r(trim.end - trim.start - removed), "newLengthTC": MCP.tc(trim.end - trim.start - removed),
            "cuts": list
        ]
        if !warnings.isEmpty { out["warnings"] = warnings }
        if mode != "clear" {
            out["note"] = "Cuts were kept inside the trim; overlapping or touching cuts were merged into one."
        }
        return out
    }

    // MARK: apply_zooms

    private func mcpApplyZooms(_ args: [String: Any]) throws -> Any {
        try mcpRequireIdle()
        try mcpRequireClip()
        if (args["mode"] as? String)?.lowercased() == "clear" {
            setZooms([])
        } else {
            guard let payload = args["zoomList"] ?? args["zooms"].map({ ["zooms": $0] as Any }) else {
                throw MCPError("Pass zooms (a list of {at, scale, type, reason, words}) or zoomList (the style guide's whole JSON).")
            }
            setZooms(try ZoomList.parse(try MCP.text(of: payload)))
        }
        saveProject()

        let trim = mcpTrim
        var warnings: [String] = []
        let list: [[String: Any]] = zooms.map { z -> [String: Any] in
            if ![1.0, ZoomList.punchScale, ZoomList.ctaScale].contains(where: { abs($0 - z.scale) < 0.011 }) {
                warnings.append("The zoom at \(MCP.tc(z.at)) is \(MCP.r(z.scale))×; the style guide uses 1.00, 1.28 and 1.40.")
            }
            if let c = CutList.cut(containing: z.at, in: cuts) {
                warnings.append("The zoom at \(MCP.tc(z.at)) sits inside a cut, so it shows from \(MCP.tc(c.end)).")
            }
            if z.at < trim.start || z.at > trim.end { warnings.append("The zoom at \(MCP.tc(z.at)) is outside the trim.") }
            return ["at": MCP.r(z.at), "atTC": MCP.tc(z.at), "scale": MCP.r(z.scale),
                    "type": MCP.orNull(z.type), "reason": MCP.orNull(z.reason), "words": MCP.orNull(z.words)]
        }
        var out: [String: Any] = ["punchIns": zooms.filter { $0.scale > 1.001 && $0.scale < ZoomList.ctaScale - 0.01 }.count,
                                  "resets": zooms.filter { $0.scale <= 1.001 }.count,
                                  "cta": zooms.filter { $0.scale >= ZoomList.ctaScale - 0.01 }.count,
                                  "zooms": list]
        if !warnings.isEmpty { out["warnings"] = warnings }
        return out
    }

    // MARK: apply_broll

    private func mcpApplyBroll(_ args: [String: Any], _ done: @escaping MCPReply) throws {
        try mcpRequireIdle()
        try mcpRequireClip()
        let mode = (args["mode"] as? String)?.lowercased() ?? "replace"
        if mode == "clear" {
            setBroll(broll.filter { $0.reason == "manual" })        // The user's own clips stay
            saveProject()
            done(.success(mcpBrollSummary(problems: [])))
            return
        }
        guard let payload = args["brollList"] ?? args["broll"].map({ ["broll": $0] as Any }) else {
            throw MCPError("Pass broll (a list of shots) or brollList (the style guide's whole JSON).")
        }
        var text = try MCP.text(of: payload)
        // A Pixabay link in url (page or download link the user pasted) means that exact clip.
        if var obj = MCP.object(in: text), var items = obj["broll"] as? [[String: Any]] {
            var changed = false
            for i in items.indices {
                if let u = items[i]["url"] as? String, let id = BrollFetch.pixabayId(fromLink: u) {
                    items[i]["url"] = nil
                    items[i]["credit"] = nil
                    items[i]["pixabayId"] = id
                    items[i]["kind"] = "video"
                    changed = true
                }
            }
            if changed {
                obj["broll"] = items
                if let data = try? JSONSerialization.data(withJSONObject: obj), let t = String(data: data, encoding: .utf8) { text = t }
            }
        }
        // Stock-only policy (2026-11-09): nothing from their own drive or Movies folder for now.
        if let items = MCP.object(in: text)?["broll"] as? [[String: Any]] {
            if let own = items.first(where: { $0["file"] != nil }) {
                throw MCPError("B-roll is stock only for now (Pixabay video, Unsplash photos). Remove “file” from the shot at \(MCP.num(own["at"]).map { MCP.tc($0) } ?? "?").")
            }
            if let bad = items.first(where: { item in
                ["search", "url", "pixabayId"].filter { item[$0] != nil && !(item[$0] is NSNull) }.count != 1
            }) {
                throw MCPError("Each shot needs exactly one of pixabayId (a video picked from a candidate sheet), search (Pixabay's top match) or url (Unsplash photo). Check the shot at \(MCP.num(bad["at"]).map { MCP.tc($0) } ?? "?").")
            }
        }
        let incoming = try BrollList.parse(text)
        setBroll(broll.filter { $0.reason == "manual" } + incoming)
        saveProject()
        addApprovedBrollToLibrary()
        guard args["download"] as? Bool ?? true, broll.contains(where: { $0.file == nil }) else {
            done(.success(mcpBrollSummary(problems: [])))
            return
        }
        guard project != nil else {
            done(.success(mcpBrollSummary(problems: ["No project is open, so nothing was downloaded."])))
            return
        }
        let job = MCPJob(name: "apply_broll (downloading)")
        job.message = "Downloading \(broll.filter { $0.file == nil }.count) shots…"
        MCP.job = job
        Task { @MainActor in
            let (_, problems) = await self.downloadPendingBroll()
            job.finish(.success(self.mcpBrollSummary(problems: problems)))
        }
        MCP.wait(for: job, upTo: MCP.waitLimit, done)
    }

    private func mcpBrollSummary(problems: [String]) -> [String: Any] {
        var out: [String: Any] = [
            "shots": broll.count,
            "secondsCovered": MCP.r(broll.reduce(0) { $0 + $1.length }),
            "broll": broll.map { c -> [String: Any] in
                ["at": MCP.r(c.at), "atTC": MCP.tc(c.at), "length": MCP.r(c.length), "kind": c.kind,
                 "search": MCP.orNull(c.search), "url": MCP.orNull(c.url), "pixabayId": MCP.orNull(c.pixabayId),
                 "downloaded": c.file != nil, "file": MCP.orNull(c.file), "credit": MCP.orNull(c.credit),
                 "words": MCP.orNull(c.words), "yours": c.reason == "manual"]
            }
        ]
        if !problems.isEmpty { out["problems"] = problems }
        return out
    }

    // MARK: save_to_broll_library (3.1.1)

    /// Keeps clips the user likes in the shared B-roll Library without placing them in this edit.
    private func mcpSaveToBrollLibrary(_ args: [String: Any], _ done: @escaping MCPReply) throws {
        let ids = (args["ids"] as? [Any])?.compactMap { item -> Int? in
            if let s = item as? String, let id = BrollFetch.pixabayId(fromLink: s) { return id }
            return MCP.num(item).map { Int($0) }
        } ?? []
        guard !ids.isEmpty else { throw MCPError("Pass ids: Pixabay video ids or links to keep in the B-roll Library.") }
        let words = (args["words"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let projectName = project?.name
        Task { @MainActor in
            let results = await SharedBrollLibrary.save(pixabayIds: ids, words: words, project: projectName)
            done(.success(["library": SharedBrollLibrary.folder.path, "results": results] as [String: Any]))
        }
    }

    // MARK: broll_candidates

    /// Searches Pixabay (or looks up chosen ids) and draws a numbered contact sheet of thumbnails,
    /// saved in the project's "B-roll Candidates" folder, so the user can pick the exact clip.
    private func mcpBrollCandidates(_ args: [String: Any], _ done: @escaping MCPReply) throws {
        let search = (args["search"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // ids may be numbers or Pixabay links the user pasted (page or download links).
        let ids = (args["ids"] as? [Any])?.compactMap { item -> Int? in
            if let s = item as? String, let id = BrollFetch.pixabayId(fromLink: s) { return id }
            return MCP.num(item).map { Int($0) }
        } ?? []
        let also = (args["also"] as? [Any])?.compactMap { $0 as? String } ?? []
        guard !search.isEmpty || !ids.isEmpty else {
            throw MCPError("Pass search (words to look for on Pixabay) or ids (Pixabay video ids or links, in the order to show them).")
        }
        let count = Int(min(40, max(1, MCP.num(args["count"]) ?? 20)))
        let title = (args["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (search.isEmpty ? "Picks" : search)
        let folder = project?.folder.appendingPathComponent("B-roll Candidates", isDirectory: true)
        Task { @MainActor in
            do {
                let list: [BrollFetch.Candidate]
                if ids.isEmpty {
                    list = try await BrollFetch.pixabaySearch(search, count: count, also: also)
                } else {
                    list = await BrollFetch.pixabayCandidates(ids: ids)
                }
                guard !list.isEmpty else { throw MCPError("Pixabay didn't return any of those videos.") }
                guard let sheet = await CandidateSheet.make(list, title: title) else {
                    throw MCPError("Couldn't draw the contact sheet.")
                }
                var out: [String: Any] = [
                    "candidates": list.enumerated().map { i, c -> [String: Any] in
                        ["n": i + 1, "pixabayId": c.id, "seconds": c.duration, "by": c.user,
                         "tags": c.tags, "page": c.pageURL, "size": "\(c.width)×\(c.height)"]
                    },
                    "howToUse": "Numbers on the sheet match n. Put the chosen clip in apply_broll as pixabayId (instead of search). Pixabay's API searches tags only and finds fewer clips than pixabay.com: if this sheet is thin, try also (related scenes or objects), or ask the user for the link to a clip they see on the site."
                ]
                if let folder {
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let name = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                    let file = folder.appendingPathComponent(name + ".jpg")
                    if (try? sheet.data.write(to: file)) != nil { out["sheet"] = file.path }
                }
                out["image"] = ["mimeType": "image/jpeg", "data": sheet.data.base64EncodedString(),
                                "width": sheet.width, "height": sheet.height] as [String: Any]
                done(.success(out))
            } catch {
                done(.failure(error))
            }
        }
    }

    // MARK: Motion graphics (step 8)

    private func mcpGraphicsTemplates() -> [String: Any] {
        [
            "templates": GraphicsTemplates.all.map { t -> [String: Any] in
                ["name": t.name, "kind": t.fullScreen ? "full-screen" : "overlay", "fields": t.fields, "example": t.example]
            },
            "red": GraphicsStyle.redHex,
            "style": GraphicsTuningStore.asDictionary(GraphicsTuningStore.current),
            "styleFile": GraphicsTuningStore.url.path,
            "rules": "Keep plates off the speaker's face (unless it's a deliberate comedic beat). The app does NOT check their face (2026-11-11): a plate goes exactly where side, scale and dx/dy put it (side defaults to left), so choose the side away from them and a size that fits; look at the graphics_preview sheet. The user fine-tunes size and position themself in the Graphics tab. Playful style (2026-11-09): animate elements beside the speaker; don't take over the screen. Full-screen templates (statement, title, chapter, bigNumber) only for the 1–2 most important points in a video; use keyword, circle, stamp, bullets, tip and bigNumberOverlay instead. Put overlays in the open space beside the speaker (side = where the graphic goes). About one plate every 15–20 s of edited video, through the whole video. Mark the key word with *asterisks* (one word or phrase per plate). Bullets: at most 4 items, up to 6 words each. On screen at least words ÷ 3 + 1 s and 2 s. Charts and numbers: The user's real numbers only. No overlay on top of B-roll; a full-screen plate covers whatever is under it. Times are original-clip seconds (like cuts and B-roll). For bullets that build, builds = the clip time of the word where each item is said (from read_transcript).",
            "notYet": "These 13 templates are in the playful style. Charts, comparisons, timeline, layout frames and the whoosh come in later versions."
        ]
    }

    /// Plates from args["graphics"] (a list of plate objects), checked against the templates.
    private func mcpParsePlates(_ args: [String: Any]) throws -> (plates: [GraphicPlate], warnings: [String]) {
        guard let raw = args["graphics"] as? [Any] else { throw MCPError("Pass graphics: a list of plates, e.g. [{\"at\": 64.2, \"template\": \"bullets\", \"title\": \"…\", \"items\": [\"…\"]}]. Call graphics_templates for the fields.") }
        let data = try JSONSerialization.data(withJSONObject: raw)
        let plates: [GraphicPlate]
        do { plates = try JSONDecoder().decode([GraphicPlate].self, from: data) }
        catch { throw MCPError("Couldn't read the plates: \(error.localizedDescription). Each needs at least at (seconds) and template.") }
        var out: [GraphicPlate] = []
        var warnings: [String] = []
        for var p in plates {
            guard let t = GraphicsTemplates.find(p.template) else {
                throw MCPError("No template named “\(p.template)” at \(MCP.tc(p.at)). Call graphics_templates for the list.")
            }
            p.template = t.name
            if p.build == true && (p.builds?.isEmpty ?? true) {
                throw MCPError("The plate at \(MCP.tc(p.at)) builds, so it needs builds: the clip time each item is said.")
            }
            if p.length <= 0 { p.length = p.minimumLength(cuts: cuts) }
            if p.length < p.minimumLength(cuts: cuts) - 0.05 {
                warnings.append("\(MCP.tc(p.at)) \(p.template): \(MCP.r(p.length)) s is short for \(p.wordCount) words (rule: \(MCP.r(p.minimumLength(cuts: cuts))) s).")
            }
            if let items = p.items {
                if items.count > 4 { warnings.append("\(MCP.tc(p.at)): \(items.count) items (rule: at most 4).") }
                for i in items where i.replacingOccurrences(of: "*", with: "").split(separator: " ").count > 6 {
                    warnings.append("\(MCP.tc(p.at)): “\(i)” is over 6 words.")
                }
            }
            if !t.fullScreen && mcpBrollShowing(at: p.at + 0.1) {
                warnings.append("\(MCP.tc(p.at)) \(p.template): B-roll is on screen there (rule: no overlays on B-roll).")
            }
            out.append(p)
        }
        return (out, warnings)
    }

    /// Draws proposed plates (nothing is placed) over their frames as one numbered sheet.
    private func mcpGraphicsPreview(_ args: [String: Any], _ done: @escaping MCPReply) throws {
        try mcpRequireClip()
        let (proposed, parsedWarnings) = try mcpParsePlates(args)
        guard !proposed.isEmpty else { throw MCPError("No plates to preview.") }
        guard let asset = sourceAsset else { throw MCPError("No video is open.") }
        if let hex = args["red"] as? String {
            guard GraphicsStyle.color(hex: hex) != nil else { throw MCPError("red should be a hex color like #E3242B.") }
            GraphicsStyle.redHex = hex
            syncGraphics()
        }
        let title = (args["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Proposed plates"
        let folder = project?.folder.appendingPathComponent("Graphics Previews", isDirectory: true)
        let red = GraphicsStyle.red
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        let faceComposition = grade.makeVideoComposition(for: asset, honorsBypass: false, includeGraphics: false)
        generator.videoComposition = faceComposition     // frames as the viewer sees them (zoom, color), no graphics
        let cutsNow = cuts
        DispatchQueue.global(qos: .userInitiated).async {
            let plates = FaceFinder.find(proposed, asset: asset, composition: faceComposition, cuts: cutsNow)
            var warnings = parsedWarnings
            for p in plates where PlateDrawing.coversFace(p) {
                warnings.append("\(MCP.tc(p.at)) \(p.template): still covers the speaker's face even at 60%. Try the other side, fewer words, or overFace: true if it's on purpose.")
            }
            let frames: [CGImage?] = plates.map { p in
                try? generator.copyCGImage(at: CMTime(seconds: p.at + min(1, p.length / 2), preferredTimescale: 600), actualTime: nil)
            }
            DispatchQueue.main.async {
                guard let sheet = GraphicsSheet.make(plates, frames: frames, title: title, red: red) else {
                    done(.failure(MCPError("Couldn't draw the preview sheet."))); return
                }
                var out: [String: Any] = [
                    "plates": plates.enumerated().map { i, p -> [String: Any] in
                        ["n": i + 1, "at": MCP.r(p.at), "atTC": MCP.tc(p.at), "length": MCP.r(p.length), "template": p.template,
                         "kind": p.isFullScreen ? "full-screen" : "overlay", "side": MCP.orNull(p.side),
                         "faceFound": p.avoid != nil]
                    },
                    "howToUse": "Nothing is placed yet. Show the user the sheet; after they pick and edit, call apply_graphics with the plates they approved.",
                    "red": GraphicsStyle.redHex
                ]
                if !warnings.isEmpty { out["warnings"] = warnings }
                if let folder {
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let name = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                    let file = folder.appendingPathComponent(name + ".jpg")
                    if (try? sheet.data.write(to: file)) != nil { out["sheet"] = file.path }
                }
                out["image"] = ["mimeType": "image/jpeg", "data": sheet.data.base64EncodedString(),
                                "width": sheet.width, "height": sheet.height] as [String: Any]
                done(.success(out))
            }
        }
    }

    private func mcpApplyGraphics(_ args: [String: Any], _ done: @escaping MCPReply) throws {
        try mcpRequireIdle()
        try mcpRequireClip()
        if let hex = args["red"] as? String {
            guard GraphicsStyle.color(hex: hex) != nil else { throw MCPError("red should be a hex color like #E3242B.") }
            GraphicsStyle.redHex = hex
        }
        func finish(_ warnings: [String]) {
            saveProject()
            var out: [String: Any] = [
                "plates": graphics.count,
                "red": GraphicsStyle.redHex,
                "graphics": graphics.map { p -> [String: Any] in
                    ["at": MCP.r(p.at), "atTC": MCP.tc(p.at), "length": MCP.r(p.length), "template": p.template,
                     "side": MCP.orNull(p.side), "faceFound": p.avoid != nil,
                     "title": MCP.orNull(p.title), "items": MCP.orNull(p.items), "words": MCP.orNull(p.words)]
                }
            ]
            if !warnings.isEmpty { out["warnings"] = warnings }
            done(.success(out))
        }
        if (args["mode"] as? String)?.lowercased() == "clear" {
            setGraphics([])
            finish([])
            return
        }
        let parsed = try mcpParsePlates(args)
        guard let asset = sourceAsset else { throw MCPError("No video is open.") }
        let faceComposition = grade.makeVideoComposition(for: asset, honorsBypass: false, includeGraphics: false)
        let cutsNow = cuts
        DispatchQueue.global(qos: .userInitiated).async {
            let plates = FaceFinder.find(parsed.plates, asset: asset, composition: faceComposition, cuts: cutsNow)
            var warnings = parsed.warnings
            for p in plates where PlateDrawing.coversFace(p) {
                warnings.append("\(MCP.tc(p.at)) \(p.template): still covers the speaker's face even at 60%. Try the other side, fewer words, or overFace: true if it's on purpose.")
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.setGraphics(plates)
                finish(warnings)
            }
        }
    }

    /// Reads or changes Graphics Style.json (global sizes, face room, timing, red). Takes effect at once.
    private func mcpGraphicsStyle(_ args: [String: Any]) throws -> [String: Any] {
        var changes = args
        changes.removeValue(forKey: "reset")
        if args["reset"] as? Bool == true {
            try? FileManager.default.removeItem(at: GraphicsTuningStore.url)
            GraphicsTuningStore.ensureFile()
        }
        if !changes.isEmpty { try GraphicsTuningStore.update(changes) }
        syncGraphics()
        return ["style": GraphicsTuningStore.asDictionary(GraphicsTuningStore.current), "file": GraphicsTuningStore.url.path,
                "note": "Changes show on the next frame, no rebuild. The user can also edit the file in any text editor."]
    }

    /// Size and nudge for plates already placed (no face search, instant). n = number from the graphics list (1-based).
    private func mcpAdjustGraphics(_ args: [String: Any]) throws -> [String: Any] {
        try mcpRequireIdle()
        guard let list = args["adjust"] as? [[String: Any]], !list.isEmpty else {
            throw MCPError("Pass adjust: a list like [{\"n\": 5, \"scale\": 1.3}, {\"n\": 2, \"dx\": -40, \"dy\": 20}]. n is the plate's number (1 = first in time). reset: true puts a plate back to its automatic size and place.")
        }
        var plates = graphics
        for a in list {
            var i: Int?
            if let n = MCP.num(a["n"]) { i = Int(n) - 1 }
            else if let at = MCP.num(a["at"]) { i = plates.firstIndex { abs($0.at - at) < 0.05 } }
            guard let idx = i, plates.indices.contains(idx) else { throw MCPError("No plate \(a["n"] ?? a["at"] ?? "?"). There are \(plates.count).") }
            var p = plates[idx]
            if a["reset"] as? Bool == true { p.scale = nil; p.dx = nil; p.dy = nil }
            if let v = MCP.num(a["scale"]) { p.scale = max(0.2, min(4, v)) }
            if let v = MCP.num(a["dx"]) { p.dx = v }
            if let v = MCP.num(a["dy"]) { p.dy = v }
            if let v = a["side"] as? String, v == "left" || v == "right" { p.side = v }
            if let v = a["overFace"] as? Bool { p.overFace = v }
            if let v = MCP.num(a["length"]), v > 0.2 { p.length = v }
            plates[idx] = p
        }
        setGraphics(plates)
        saveProject()
        var warnings: [String] = []
        for p in graphics where PlateDrawing.coversFace(p) {
            warnings.append("\(MCP.tc(p.at)) \(p.template): now covers the speaker's face.")
        }
        var out: [String: Any] = ["graphics": graphics.enumerated().map { i, p -> [String: Any] in
            ["n": i + 1, "atTC": MCP.tc(p.at), "template": p.template, "title": MCP.orNull(p.title),
             "scale": p.scale ?? 1, "dx": p.dx ?? 0, "dy": p.dy ?? 0, "side": MCP.orNull(p.side)]
        }]
        if !warnings.isEmpty { out["warnings"] = warnings }
        return out
    }

    // MARK: seek

    private func mcpSeek(_ args: [String: Any], _ done: @escaping MCPReply) throws {
        let (_, duration) = try mcpRequireClip()
        guard let p = player, !isExporting else { throw MCPError("Can't move the playhead during an export.") }
        let trim = mcpTrim
        let t: Double
        if let n = MCP.num(args["to"]) {
            t = min(max(0, n), duration)
        } else if let name = (args["to"] as? String)?.lowercased() {
            switch name {
            case "trimstart", "start", "in": t = trim.start
            case "trimend", "end", "out": t = max(trim.start, trim.end - 0.05)
            default: throw MCPError("to is a time in seconds, \"trimStart\" or \"trimEnd\".")
            }
        } else {
            throw MCPError("Pass to: a time in seconds on the original clip.")
        }
        let play = args["play"] as? Bool ?? false
        p.pause()
        p.seek(to: CMTime(seconds: toComp(t), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if play { p.play() }
                var out: [String: Any] = ["playhead": MCP.r(t), "playheadTC": MCP.tc(t), "playing": play]
                if let c = CutList.cut(containing: t, in: self.cuts) {
                    out["note"] = "That time is inside a cut; playback continues from \(MCP.tc(c.end))."
                }
                done(.success(out))
            }
        }
    }
}

// MARK: - Loudness of the original recording

/// BS.1770 integrated loudness (as YouTube measures it) plus peak, noise floor and speech level,
/// read from the clip's own audio inside the trim with the cuts taken out — before Sound Design.
enum Loudness {
    private struct Biquad {
        let b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0
        init(_ b0: Double, _ b1: Double, _ b2: Double, _ a1: Double, _ a2: Double) {
            self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
        }
        mutating func run(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    static func measure(asset: AVAsset, keep: [(Double, Double)]) async throws -> [String: Any] {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw MCPError("This video has no audio track.")
        }
        let rate = 48_000.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
            throw MCPError("Couldn't set up the audio format.")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: AudioFeeder.readerSettings(for: format))
        guard reader.canAdd(output) else { throw MCPError("Couldn't read the audio.") }
        reader.add(output)
        guard reader.startReading() else { throw MCPError(reader.error?.localizedDescription ?? "Couldn't read the audio.") }

        // K-weighting at 48 kHz (ITU-R BS.1770-4): high shelf, then high pass. One pair per channel.
        func kFilters() -> [Biquad] {
            [Biquad(1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585),
             Biquad(1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621)]
        }
        var leftK = kFilters(), rightK = kFilters()
        let step = 4_800                                    // 100 ms blocks
        var blockK = 0.0, blockRaw = 0.0, blockPeak = 0.0, blockCount = 0
        var sample = 0
        // Per 100 ms block: start time, K-weighted power (summed over channels), plain RMS power, peak.
        var blocks: [(t: Double, k: Double, raw: Double, peak: Double)] = []

        func isKept(_ t: Double) -> Bool { keep.contains { t >= $0.0 && t < $0.1 } }

        while let buffer = output.copyNextSampleBuffer() {
            guard let pcm = AudioFeeder.pcmBuffer(from: buffer, format: format), let ch = pcm.floatChannelData else { continue }
            let n = Int(pcm.frameLength)
            let left = ch[0], right = ch[1]
            for i in 0..<n {
                let l = Double(left[i]), r = Double(right[i])
                let sl = leftK[0].run(l)
                let kl = leftK[1].run(sl)
                let sr = rightK[0].run(r)
                let kr = rightK[1].run(sr)
                blockK += kl * kl + kr * kr
                blockRaw += (l * l + r * r) / 2
                blockPeak = max(blockPeak, abs(l), abs(r))
                blockCount += 1
                if blockCount == step {
                    let t = Double(sample) / rate
                    blocks.append((t, blockK / Double(step), blockRaw / Double(step), blockPeak))
                    sample += step
                    blockK = 0; blockRaw = 0; blockPeak = 0; blockCount = 0
                }
            }
        }
        if reader.status == .failed { throw MCPError(reader.error?.localizedDescription ?? "Couldn't read the audio.") }

        let kept = blocks.filter { isKept($0.t + 0.05) }
        guard kept.count >= 4 else { throw MCPError("Not enough audio inside the trim to measure.") }

        // 400 ms gating blocks with 75% overlap = four 100 ms blocks in a row.
        var gating: [Double] = []
        for i in 0...(kept.count - 4) where kept[i + 3].t - kept[i].t < 0.35 {
            gating.append((kept[i].k + kept[i + 1].k + kept[i + 2].k + kept[i + 3].k) / 4)
        }
        func lufs(_ power: Double) -> Double { power > 0 ? -0.691 + 10 * log10(power) : -100 }
        let absolute = gating.filter { lufs($0) > -70 }
        var integrated = -100.0
        if !absolute.isEmpty {
            let relative = lufs(absolute.reduce(0, +) / Double(absolute.count)) - 10
            let gated = absolute.filter { lufs($0) > relative }
            if !gated.isEmpty { integrated = lufs(gated.reduce(0, +) / Double(gated.count)) }
        }
        let levels = kept.map { $0.raw > 0 ? 10 * log10($0.raw) : -100 }.sorted()
        func pct(_ p: Double) -> Double { levels[min(levels.count - 1, Int(Double(levels.count) * p))] }
        let peak = kept.map { $0.peak }.max() ?? 0

        return [
            "integratedLUFS": MCP.r(integrated, 1),
            "samplePeakDBFS": peak > 0 ? MCP.r(20 * log10(peak), 1) : -100,
            "noiseFloorDBFS": MCP.r(pct(0.10), 1),
            "speechLevelDBFS": MCP.r(pct(0.90), 1),
            "secondsMeasured": MCP.r(Double(kept.count) / 10, 1),
            "howToRead": "Measured on the original recording (inside the trim, cuts taken out), BEFORE Sound Design, as stereo like the export. noiseFloor = the quietest 10% of 100 ms moments (room/road noise); speechLevel = the loudest 10%. YouTube turns down anything louder than about −14 LUFS."
        ]
    }
}

// MARK: - B-roll contact sheets

/// A numbered grid of Pixabay thumbnails (number, length, tags under each), as a JPEG.
enum CandidateSheet {
    static func make(_ items: [BrollFetch.Candidate], title: String) async -> (data: Data, width: Int, height: Int)? {
        // Thumbnails, fetched in parallel.
        let thumbs: [Int: Data] = await withTaskGroup(of: (Int, Data?).self) { group in
            for (i, c) in items.enumerated() {
                group.addTask {
                    guard let u = c.thumbnail, let got = try? await URLSession.shared.data(from: u) else { return (i, nil) }
                    return (i, got.0)
                }
            }
            var out: [Int: Data] = [:]
            for await (i, d) in group { if let d { out[i] = d } }
            return out
        }

        let small = items.count > 10
        let tw = small ? 240 : 320, th = small ? 135 : 180
        let cols = min(5, max(1, items.count))
        let rows = (items.count + cols - 1) / cols
        let gap = 10, caption = 34, header = 44
        let width = cols * tw + (cols + 1) * gap
        let height = header + rows * (th + caption + gap) + gap
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18, weight: .semibold),
                                                         .foregroundColor: NSColor.white]
        NSAttributedString(string: "B-roll candidates: \(title)", attributes: titleAttrs)
            .draw(at: NSPoint(x: gap, y: height - header + 12))
        let numberAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: small ? 16 : 20, weight: .bold),
                                                          .foregroundColor: NSColor.white]
        let captionAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11),
                                                           .foregroundColor: NSColor(white: 0.8, alpha: 1)]

        for (i, c) in items.enumerated() {
            let col = i % cols, row = i / cols
            let x = gap + col * (tw + gap)
            let top = height - header - row * (th + caption + gap)
            let rect = CGRect(x: x, y: top - th, width: tw, height: th)
            ctx.setFillColor(CGColor(gray: 0.2, alpha: 1))
            ctx.fill(rect)
            if let d = thumbs[i], let src = CGImageSourceCreateWithData(d as CFData, nil),
               let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                let k = max(CGFloat(tw) / CGFloat(img.width), CGFloat(th) / CGFloat(img.height))   // fill the tile
                let w = CGFloat(img.width) * k, h = CGFloat(img.height) * k
                ctx.saveGState()
                ctx.clip(to: rect)
                ctx.interpolationQuality = .high
                ctx.draw(img, in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
                ctx.restoreGState()
            }
            // Number badge, top-left.
            let label = NSAttributedString(string: "\(i + 1)", attributes: numberAttrs)
            let size = label.size()
            let badge = CGRect(x: rect.minX + 6, y: rect.maxY - size.height - 10, width: size.width + 14, height: size.height + 4)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.7))
            ctx.fill(badge)
            label.draw(at: NSPoint(x: badge.minX + 7, y: badge.minY + 2))
            // Length and tags underneath.
            let text = "\(c.duration) s · \(c.tags)"
            NSAttributedString(string: text, attributes: captionAttrs)
                .draw(with: NSRect(x: rect.minX, y: rect.minY - CGFloat(caption) + 2, width: CGFloat(tw), height: CGFloat(caption - 4)),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let image = ctx.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else { return nil }
        return (data, width, height)
    }
}

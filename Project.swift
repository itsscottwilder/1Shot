// Project — a folder that holds everything for one video:
//
//   My Video/
//     My Video.1shot     settings (trim, color, LUTs, stabilize, fade, audio) — saved automatically
//     Media/             the video, copied in (an instant, space-free clone on the same APFS drive)
//     LUTs/              copies of the LUTs the project uses
//     Exports/           YouTube exports go here by default
//     Transcripts/       edit transcripts (words + timing + pauses), made with File › Create Edit Transcript

import Cocoa

struct ProjectData: Codable {
    var version = 1
    var video: String?              // path inside the project folder, e.g. "Media/IMG_0022.mov"
    var trimStart: Double?
    var trimEnd: Double?
    var color: VisualDesignPanel.Snapshot?
    var audio: SoundDesignPanel.Snapshot?
    var transcript: String?         // e.g. "Transcripts/IMG_0022.json"
    var cuts: [Cut]?                // pieces removed from inside the trim (original-clip seconds)
    var suggestedCuts: [Cut]?       // the last cut list imported/pasted/made, before your manual changes
    var suggestedFrom: String?      // where that list came from
    var suggestedStyleGuide: String?
    var zooms: [ZoomEvent]?         // punch-in zooms (original-clip seconds)
    var broll: [BrollClip]?         // V2 B-roll shots
    var graphics: [GraphicPlate]?   // V3 motion graphics plates
    var assets: [AssetEntry]?       // Assets tab (3.1.0): source clips for the assembled A-roll
    var visualGroups: [VisualGroup]? // Visual Design groups (3.2): a look per group of clips
}

final class Project {
    static let fileExtension = "1shot"

    enum ProjectError: LocalizedError {
        case alreadyExists(String), noProjectFile
        var errorDescription: String? {
            switch self {
            case .alreadyExists(let name): return "A folder named “\(name)” already exists there. Choose another name."
            case .noProjectFile: return "That folder doesn't contain a 1Shot project (.1shot file)."
            }
        }
    }

    let folder: URL
    let fileURL: URL
    var data: ProjectData
    private var lastSaved: Data?

    var name: String { fileURL.deletingPathExtension().lastPathComponent }
    var mediaFolder: URL { folder.appendingPathComponent("Media", isDirectory: true) }
    var lutFolder: URL { folder.appendingPathComponent("LUTs", isDirectory: true) }
    var exportsFolder: URL { folder.appendingPathComponent("Exports", isDirectory: true) }
    var transcriptsFolder: URL { folder.appendingPathComponent("Transcripts", isDirectory: true) }

    var videoURL: URL? {
        data.video.map { folder.appendingPathComponent($0) }
    }

    private init(folder: URL, fileURL: URL, data: ProjectData) {
        self.folder = folder
        self.fileURL = fileURL
        self.data = data
    }

    /// ~/Movies/1Shot (created if needed).
    static var defaultLocation: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        let url = movies.appendingPathComponent("1Shot", isDirectory: true)
        moveRenamedFolder(from: movies.appendingPathComponent("1Shot Pipeline", isDirectory: true), to: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The app was called "1Shot Pipeline" before 3.2. If a folder still has the old name and
    /// nothing has the new one yet, move it over (same disk, so it's instant and keeps everything).
    static func moveRenamedFolder(from old: URL, to new: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        do {
            try fm.moveItem(at: old, to: new)
            NSLog("1Shot: moved \(old.path) to \(new.path)")
        } catch {
            NSLog("1Shot: couldn't move \(old.path) to \(new.path): \(error)")
        }
    }

    /// ~/Movies/1Shot/Style Guides — editing style guides any AI can follow.
    static var styleGuidesFolder: URL {
        defaultLocation.appendingPathComponent("Style Guides", isDirectory: true)
    }

    /// Creates the Style Guides folder and adds the starter guides that come with the app.
    /// Never overwrites a guide that's already there (so your edits are safe).
    static func installStyleGuides() {
        let fm = FileManager.default
        let folder = styleGuidesFolder
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("StyleGuides"),
              let files = try? fm.contentsOfDirectory(at: bundled, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension.lowercased() == "md" {
            let target = folder.appendingPathComponent(file.lastPathComponent)
            if !fm.fileExists(atPath: target.path) {
                try? fm.copyItem(at: file, to: target)
            } else if guideVersion(of: file) > guideVersion(of: target) {
                // The app has a newer version of a starter guide: keep the old one beside it, then update.
                let base = target.deletingPathExtension().lastPathComponent
                let backup = folder.appendingPathComponent("\(base) (previous v\(guideVersion(of: target))).md")
                try? fm.removeItem(at: backup)
                try? fm.moveItem(at: target, to: backup)
                try? fm.copyItem(at: file, to: target)
            }
        }
    }

    /// `guide_version:` from a style guide's front matter (1 if it has none).
    private static func guideVersion(of url: URL) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        for line in text.split(separator: "\n").prefix(20) where line.hasPrefix("guide_version:") {
            return Int(line.dropFirst("guide_version:".count).trimmingCharacters(in: .whitespaces)) ?? 1
        }
        return 1
    }

    /// Makes the project folder (named after the project) with its subfolders and settings file.
    static func create(at folder: URL) throws -> Project {
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.path) { throw ProjectError.alreadyExists(folder.lastPathComponent) }
        let name = folder.lastPathComponent
        let project = Project(folder: folder,
                              fileURL: folder.appendingPathComponent(name).appendingPathExtension(fileExtension),
                              data: ProjectData())
        for dir in [folder, project.mediaFolder, project.lutFolder, project.exportsFolder] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try project.save()
        return project
    }

    /// Opens a .1shot file, or a project folder containing one.
    static func open(_ url: URL) throws -> Project {
        var file = url
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            guard let found = contents.first(where: { $0.pathExtension.lowercased() == fileExtension }) else {
                throw ProjectError.noProjectFile
            }
            file = found
        }
        let raw = try Data(contentsOf: file)
        let data = try JSONDecoder().decode(ProjectData.self, from: raw)
        let project = Project(folder: file.deletingLastPathComponent(), fileURL: file, data: data)
        project.lastSaved = raw
        // Older or hand-made folders may be missing a subfolder.
        for dir in [project.mediaFolder, project.lutFolder, project.exportsFolder] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return project
    }

    /// Writes the settings file if anything changed.
    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let raw = try encoder.encode(data)
        guard raw != lastSaved else { return }
        try raw.write(to: fileURL, options: .atomic)
        lastSaved = raw
    }

    // MARK: Assets

    /// True if the file already lives inside this project's folder.
    func contains(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
    }

    func relativePath(of url: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1))
    }

    /// Copies a video into Media/ (in the background). Completion on the main thread.
    func importVideo(_ source: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        if contains(source) { completion(.success(source)); return }
        let destination = Self.uniqueURL(for: source.lastPathComponent, in: mediaFolder, matching: source)
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            do {
                if !fm.fileExists(atPath: destination.path) {
                    try fm.copyItem(at: source, to: destination)   // APFS clones this instantly when it can
                }
                DispatchQueue.main.async { completion(.success(destination)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// Keeps a copy of a LUT in LUTs/ so the project is self-contained.
    func keepCopy(ofLUT url: URL) {
        let destination = lutFolder.appendingPathComponent(url.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        try? FileManager.default.copyItem(at: url, to: destination)
    }

    func lutCopy(named name: String) -> URL? {
        let url = lutFolder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// A free file name in `folder` (adds " 2", " 3"…). Reuses an existing file of the same size,
    /// so importing the same clip twice doesn't make a second copy.
    private static func uniqueURL(for fileName: String, in folder: URL, matching source: URL) -> URL {
        let fm = FileManager.default
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        let sourceSize = (try? fm.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value
        var n = 1
        while true {
            let name = n == 1 ? fileName : "\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)")
            let candidate = folder.appendingPathComponent(name)
            guard fm.fileExists(atPath: candidate.path) else { return candidate }
            let size = (try? fm.attributesOfItem(atPath: candidate.path)[.size] as? NSNumber)?.int64Value
            if size != nil, size == sourceSize { return candidate }
            n += 1
        }
    }
}

/// A small "please wait" sheet with a spinner.
enum BusySheet {
    static func make(message: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 90),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingMiddle
        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        window.contentView = stack
        return window
    }
}

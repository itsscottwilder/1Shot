// Assets — the Assets tab's data model (3.1.0): source clips imported for a multi-clip A-roll,
// each with its own trim and keep/reject state. See AssetsPanel.swift for the UI.

import Cocoa
import AVFoundation

/// One source clip imported into a project's Assets tab: a candidate shot for the assembled
/// A-roll, with its own trim and keep/reject state. `path` is Media/-relative, same convention
/// as the classic single-clip `ProjectData.video`.
struct AssetEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var path: String
    var inPoint: Double
    var outPoint: Double
    var rejected: Bool = false
    var sortDate: Date      // recording time if known, else file creation date, else import time
    var duration: Double
    var visualGroup: String? = nil   // Visual Design group (3.2); nil = the built-in "A-roll" group

    /// Probes a just-imported file for its duration and the best sort key we can get: the
    /// clip's own recording-time metadata (QuickTime "creation date"), falling back to the
    /// file's filesystem creation date, then "now" (so it still sorts after earlier imports).
    static func make(path: String, url: URL) async -> AssetEntry {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        var sortDate: Date?
        if let item = try? await asset.load(.creationDate) {
            sortDate = item.dateValue
        }
        if sortDate == nil {
            sortDate = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
        }
        let safeDuration = duration.isFinite && duration > 0 ? duration : 0
        return AssetEntry(path: path, inPoint: 0, outPoint: safeDuration,
                          sortDate: sortDate ?? Date(), duration: safeDuration)
    }
}

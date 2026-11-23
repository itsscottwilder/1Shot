// Undo — Edit › Undo (⌘Z) and Redo (⇧⌘Z) for every edit, by snapshots.
//
// A few times a second the window takes a picture of the edit: trim, cuts, zooms, B-roll and every
// Visual and Sound Design setting. When the picture changes and then holds still for about half a
// second (and the mouse is up), the picture from before becomes one undo step. So a whole slider
// drag, a dragged cut edge or a pasted cut list is one step, and changes Claude makes through MCP
// are undoable too. Undo puts the earlier picture back; Redo puts the later one back.
//
// Left out on purpose: the Stabilize On switch (it flips by itself when analysis finishes) and the
// Color Bypass before/after switch (a preview setting). B-roll downloads aren't steps either, and an
// undo never "un-downloads" a shot. Opening another project or video starts the history over.

import Cocoa
import AVFoundation

struct EditState: Equatable {
    var color: VisualDesignPanel.Snapshot
    var audio: SoundDesignPanel.Snapshot
    var cuts: [Cut]
    var zooms: [ZoomEvent]
    var broll: [BrollClip]
    var graphics: [GraphicPlate] = []
    var trim: [Double]?            // [in, out] on the original clip; nil = not trimmed
    var volume = VolumeMap()       // A1 sections (3.7.0)

    /// The parts that count as edits (see the note at the top).
    fileprivate var comparable: EditState {
        var s = self
        s.color.stabilize = false
        s.color.colorBypass = false
        s.broll = broll.map { c in
            var c = c
            c.file = nil
            c.credit = nil
            return c
        }
        return s
    }

    static func == (a: EditState, b: EditState) -> Bool {
        let x = a.plain, y = b.plain
        return x.color == y.color && x.audio == y.audio && x.cuts == y.cuts &&
            x.zooms == y.zooms && x.broll == y.broll && x.graphics == y.graphics && x.trim == y.trim && x.volume == y.volume
    }

    /// Field-by-field equality without the custom == above (which would call itself).
    private struct Plain {
        let color: VisualDesignPanel.Snapshot
        let audio: SoundDesignPanel.Snapshot
        let cuts: [Cut]
        let zooms: [ZoomEvent]
        let broll: [BrollClip]
        let graphics: [GraphicPlate]
        let trim: [Double]?
        let volume: VolumeMap
    }

    private var plain: Plain {
        let c = comparable
        return Plain(color: c.color, audio: c.audio, cuts: c.cuts, zooms: c.zooms, broll: c.broll, graphics: c.graphics, trim: c.trim, volume: c.volume)
    }
}

final class EditHistory {
    let undoManager = UndoManager()
    private weak var controller: PlayerWindowController?
    private var timer: Timer?
    private var settled: EditState?        // the state the last undo step leads back from
    private var seen: EditState?           // the latest picture, to tell when changes stop
    private var changedAt: TimeInterval = 0
    private var identity: [URL?] = []      // project + video; a new one starts the history over
    private var aroll: ObjectIdentifier?   // the assembled A-roll; rebuilding it starts the history over too
    private var restoring = false

    init() {
        undoManager.levelsOfUndo = 200
    }

    func attach(to controller: PlayerWindowController) {
        self.controller = controller
        timer = Timer.everyMode(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        guard let c = controller, !restoring, let now = c.editState() else { return }
        let id: [URL?] = [c.project?.fileURL.standardizedFileURL, c.currentVideo?.standardizedFileURL]
        let built = c.currentVideo == nil ? c.sourceAsset.map(ObjectIdentifier.init) : nil
        if id != identity || built != aroll || settled == nil {
            identity = id
            aroll = built
            settled = now
            seen = now
            undoManager.removeAllActions()
            return
        }
        if let settled, now == settled { seen = now; return }
        if seen.map({ now != $0 }) ?? true {
            seen = now
            changedAt = ProcessInfo.processInfo.systemUptime
            return
        }
        // Changed, and has held still for a moment with the mouse up: that's one step.
        guard ProcessInfo.processInfo.systemUptime - changedAt >= 0.45,
              NSEvent.pressedMouseButtons == 0, let old = settled else { return }
        settled = now
        let name = Self.describe(from: old, to: now)
        undoManager.registerUndo(withTarget: self) { history in
            history.restore(old, opposite: now, name: name)
        }
        undoManager.setActionName(name)
    }

    /// Puts `state` back and records the way to return to `opposite` (so Undo and Redo swap).
    private func restore(_ state: EditState, opposite: EditState, name: String) {
        undoManager.registerUndo(withTarget: self) { history in
            history.restore(opposite, opposite: state, name: name)
        }
        undoManager.setActionName(name)
        guard let c = controller else { return }
        restoring = true
        c.applyEditState(state)
        // Cuts rebuild playback and LUTs load in the background; read the result once it's settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            let now = self.controller?.editState() ?? state
            self.settled = now
            self.seen = now
            self.restoring = false
        }
    }

    // MARK: Menu names ("Undo Add Cut", "Undo Exposure"…)

    static func describe(from a: EditState, to b: EditState) -> String {
        let x = a.comparable, y = b.comparable
        var parts: [String] = []
        if x.trim != y.trim { parts.append("Trim") }
        if x.cuts != y.cuts { parts.append(change(x.cuts.count, y.cuts.count, "Cut")) }
        if x.zooms != y.zooms { parts.append(change(x.zooms.count, y.zooms.count, "Zoom")) }
        if x.broll != y.broll { parts.append(change(x.broll.count, y.broll.count, "B-roll Shot")) }
        if x.graphics != y.graphics { parts.append(change(x.graphics.count, y.graphics.count, "Graphic")) }
        if x.color != y.color { parts.append(visualName(x.color, y.color)) }
        if x.audio != y.audio { parts.append("Sound Design") }
        if x.volume != y.volume { parts.append("Volume") }
        return parts.count == 1 ? parts[0] : "Changes"
    }

    private static func change(_ from: Int, _ to: Int, _ noun: String) -> String {
        if to == from + 1 { return "Add \(noun)" }
        if to == from - 1 { return "Remove \(noun)" }
        if to == from { return "Change \(noun)" }
        return to == 0 ? "Clear \(noun)s" : "\(noun) List"
    }

    private static func visualName(_ a: VisualDesignPanel.Snapshot, _ b: VisualDesignPanel.Snapshot) -> String {
        var names: [String] = []
        for key in Set(a.sliders.keys).union(b.sliders.keys) where a.sliders[key] != b.sliders[key] { names.append(key) }
        if a.bypassed != b.bypassed { names.append("Bypass \(Set(a.bypassed).symmetricDifference(b.bypassed).sorted().joined(separator: ", "))") }
        if a.blackPoint != b.blackPoint || a.whitePoint != b.whitePoint { names.append("Levels") }
        if a.cameraLUT != b.cameraLUT { names.append("Camera LUT") }
        if a.creativeLUT != b.creativeLUT { names.append("Creative LUT") }
        if a.smoothness != b.smoothness || a.maxCrop != b.maxCrop { names.append("Stabilize Settings") }
        if a.fade != b.fade { names.append("Fade to Black") }
        return names.count == 1 ? names[0] : "Visual Design"
    }
}

// MARK: - Taking and applying the picture

extension PlayerWindowController {

    /// The edit as it is right now, or nil while there's nothing to undo (loading, exporting, no video).
    func editState() -> EditState? {
        guard player != nil, trimBar.duration > 0, pendingRestore == nil, !isExporting,
              let asset = sourceAsset else { return nil }
        if let video = currentVideo {
            // A single file: only once that file is the one playing.
            guard (asset as? AVURLAsset)?.url.standardizedFileURL == video.standardizedFileURL else { return nil }
        } else {
            // An assembled A-roll from the Assets tab (3.3.2: before this, multi-clip projects had no undo).
            guard asset is AVComposition else { return nil }
        }
        // The trim strip's own values (the player's in/out points pick up rounding when cuts change).
        let trim: [Double]? = isTrimmed ? [trimBar.start, trimBar.end] : nil
        return EditState(color: exportDrawer.snapshot, audio: drawer.snapshot,
                         cuts: cuts, zooms: zooms, broll: broll, graphics: graphics, trim: trim, volume: volume)
    }

    /// Puts an earlier picture back. Only what differs is touched.
    func applyEditState(_ s: EditState) {
        guard player != nil, !isExporting else { NSSound.beep(); return }

        // Trim first: cuts are kept inside it.
        let currentTrim: [Double]? = isTrimmed ? [trimBar.start, trimBar.end] : nil
        if s.trim != currentTrim {
            if let t = s.trim, t.count == 2, t[1] - t[0] > 0.05 {
                trimBar.start = max(0, t[0])
                trimBar.end = min(t[1], trimBar.duration)
                trimChanged(start: trimBar.start, end: trimBar.end, movingStart: false, finished: true)
            } else {
                resetTrim()
            }
        }
        if s.cuts != cuts { setCuts(s.cuts) }
        if s.volume != volume { setVolume(s.volume) }
        if s.zooms != zooms { setZooms(s.zooms) }

        // B-roll: keep any shot that has downloaded since (an undo never "un-downloads").
        var have: [String: BrollClip] = [:]
        for c in broll { have[c.id] = c }
        let merged = s.broll.map { c -> BrollClip in
            var c = c
            if c.file == nil, let now = have[c.id], now.file != nil {
                c.file = now.file
                c.credit = now.credit
            }
            return c
        }
        if merged != broll { setBroll(merged) }
        if s.graphics != graphics { setGraphics(s.graphics) }

        // Visual Design (the Stabilize On and Bypass switches stay as they are).
        let currentColor = exportDrawer.snapshot
        var color = s.color
        color.stabilize = currentColor.stabilize
        color.colorBypass = currentColor.colorBypass
        if color != currentColor {
            let project = self.project
            exportDrawer.restore(color) { name in
                if let inLibrary = CubeLUT.libraryFiles().first(where: { $0.lastPathComponent == name }) { return inLibrary }
                guard let kept = project?.lutCopy(named: name) else { return nil }
                return try? CubeLUT.importToLibrary(kept)
            }
        }

        if s.audio != drawer.snapshot { drawer.restore(s.audio) }
        saveProject()
    }
}

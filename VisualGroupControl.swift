// VisualGroupControl — 3.2: the window side of Visual Design groups. In the Visual Design tab,
// clicking a clip on the timeline (an A-roll clip on V1 or a B-roll shot on V2) loads that clip's
// group into the panel, colours the panel header and the clip in the group's colour, and sends
// every slider/LUT change to that group. See VisualGroups.swift for the model.

import Cocoa
import AVFoundation

extension PlayerWindowController {

    // MARK: Setup / persistence

    func setUpVisualGroups() {
        exportDrawer.onAssignGroup = { [weak self] id in self?.assignSelectedClip(to: id) }
        exportDrawer.onNewGroup = { [weak self] in self?.newGroupForSelectedClip() }
        exportDrawer.onRenameGroup = { [weak self] in self?.renameActiveGroup() }
        trimBar.onPickClip = { [weak self] pick in self?.pickVisualClip(pick) }
        updateGroupHeader(clip: "")
    }

    /// After a project's drawers are restored: its groups, with the A-roll group holding the panel's look.
    func loadVisualGroups(from project: Project) {
        var groups = project.data.visualGroups ?? VisualGroup.defaults
        for d in VisualGroup.defaults where !groups.contains(where: { $0.id == d.id }) { groups.insert(d, at: min(groups.count, d.colorIndex)) }
        if let i = groups.firstIndex(where: { $0.id == VisualGroup.arollID }) {
            groups[i].look = exportDrawer.look
            if groups[i].name == "A-roll" { groups[i].name = "Default" }   // 3.2 betas called it A-roll
        }
        visualGroups = groups
        activeVisualGroup = VisualGroup.arollID
        selectedVisualClip = nil
        trimBar.clipHighlight = nil
        updateGroupHeader(clip: "")
        syncVisualGroups()
    }

    /// What the project file keeps for colour: the A-roll look in the classic `color` snapshot
    /// (so older versions and the MCP tools still read it), every group in `visualGroups`.
    func colorSnapshotForSaving() -> VisualDesignPanel.Snapshot {
        let snap = exportDrawer.snapshot
        guard activeVisualGroup != VisualGroup.arollID,
              let aroll = visualGroups.first(where: { $0.id == VisualGroup.arollID })?.look else { return snap }
        return VisualDesignPanel.snapshot(snap, with: aroll)
    }

    // MARK: Routing the panel's changes to the active group

    /// The panel's Color/Levels changed: they belong to the group being edited.
    func gradeChangedInPanel(_ s: ColorGrade.Settings) {
        if activeVisualGroup == VisualGroup.arollID { grade.settings = s }
        else { grade.setGroupSettings(activeVisualGroup, s) }
        rememberActiveLook()
        refreshFrame()
    }

    /// A LUT was chosen in the panel (already loaded): it belongs to the group being edited.
    func lutChangedInPanel(_ lut: CubeLUT?, slot: VisualDesignPanel.LUTSlot) {
        if activeVisualGroup == VisualGroup.arollID {
            switch slot {
            case .camera: grade.lut = lut
            case .creative: grade.creativeLUT = lut
            }
        } else {
            grade.setGroupLUT(activeVisualGroup, camera: slot == .camera, lut)
        }
        rememberActiveLook()
    }

    private func rememberActiveLook() {
        guard let i = visualGroups.firstIndex(where: { $0.id == activeVisualGroup }) else { return }
        visualGroups[i].look = exportDrawer.look
    }

    /// Hands every group's look and the A-roll clip → group map to the renderer.
    func syncVisualGroups() {
        var grades: [String: ColorGrade.GroupGrade] = [:]
        for g in visualGroups where g.id != VisualGroup.arollID {
            let l = g.look ?? VisualDesignPanel.Look()
            grades[g.id] = ColorGrade.GroupGrade(settings: VisualDesignPanel.settings(from: l),
                                                 lut: cachedLUT(l.cameraLUT), creativeLUT: cachedLUT(l.creativeLUT))
        }
        grade.setGroupGrades(grades)
        assetsPanel.setGroups(visualGroups.map { ($0.id, $0.name, $0.color) })
        grade.setArollGroups(boundaries: trimBar.sourceClipBoundaries,
                             groups: arollClips().map { $0.visualGroup ?? VisualGroup.arollID })
        refreshFrame()
    }

    private func cachedLUT(_ name: String?) -> CubeLUT? {
        guard let name else { return nil }
        // Normally it's in the library and already loaded: one file check, no folder listing.
        if let lut = try? CubeLUT.cached(url: CubeLUT.libraryFolder.appendingPathComponent(name)) { return lut }
        guard let url = lutURL(named: name) else { return nil }      // only the project has it: bring it over
        return try? CubeLUT.cached(url: url)
    }

    func lutURL(named name: String) -> URL? {
        if let inLibrary = CubeLUT.libraryFiles().first(where: { $0.lastPathComponent == name }) { return inLibrary }
        guard let kept = project?.lutCopy(named: name) else { return nil }
        return try? CubeLUT.importToLibrary(kept)
    }

    // MARK: Picking a clip

    /// The A-roll's clips in timeline order (the same order Build uses). Empty for a single video.
    func arollClips() -> [AssetEntry] {
        guard trimBar.sourceClipCount > 0 else { return [] }
        return assets.filter { !$0.rejected }.sorted { $0.sortDate < $1.sortDate }
    }

    func pickVisualClip(_ pick: TrimBar.ClipPick) {
        guard currentTab == .visualDesign else { return }
        switch pick {
        case .broll(let i):
            guard broll.indices.contains(i) else { return }
            selectVisualClip(.broll(i))
        case .aroll(let t):
            // A B-roll shot covering this moment wins only when it was clicked on V2; V1 is the A-roll.
            let edges = trimBar.sourceClipBoundaries
            selectVisualClip(.aroll(edges.filter { t >= $0 }.count))
        }
    }

    /// Called when the Visual Design tab opens: picks the clip under the playhead.
    func pickClipAtPlayhead() {
        let t = trimBar.playhead
        if let i = broll.firstIndex(where: { t >= $0.at && t < clipTimeFor(edited: edited($0.at) + $0.length) }) {
            selectVisualClip(.broll(i))
        } else {
            selectVisualClip(.aroll(trimBar.sourceClipBoundaries.filter { t >= $0 }.count))
        }
    }

    func selectVisualClip(_ clip: VisualClip) {
        selectedVisualClip = clip
        let (group, label) = groupAndLabel(for: clip)
        if group != activeVisualGroup {
            activeVisualGroup = group
            let look = visualGroups.first(where: { $0.id == group })?.look ?? VisualDesignPanel.Look()
            exportDrawer.applyLook(look) { [weak self] name in self?.lutURL(named: name) }
        }
        updateGroupHeader(clip: label)
        highlightSelectedClip()
    }

    private func groupAndLabel(for clip: VisualClip) -> (String, String) {
        switch clip {
        case .aroll(let i):
            let clips = arollClips()
            guard clips.indices.contains(i) else {
                let name = currentVideo?.lastPathComponent ?? project?.name ?? "A-roll"
                return (VisualGroup.arollID, "A-roll · \(name)")
            }
            let name = ((clips[i].path as NSString).lastPathComponent as NSString).deletingPathExtension
            return (clips[i].visualGroup ?? VisualGroup.arollID, "A-roll clip \(i + 1) · \(name)")
        case .broll(let i):
            guard broll.indices.contains(i) else { return (VisualGroup.brollID, "B-roll") }
            let c = broll[i]
            let name = c.file.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
                ?? c.pixabayId.map { "Pixabay \($0)" } ?? "B-roll"
            return (c.visualGroup ?? VisualGroup.brollID, "B-roll shot \(i + 1) · \(name)")
        }
    }

    func highlightSelectedClip() {
        guard currentTab == .visualDesign, let clip = selectedVisualClip,
              let color = visualGroups.first(where: { $0.id == activeVisualGroup })?.color else {
            trimBar.clipHighlight = nil
            return
        }
        switch clip {
        case .aroll(let i):
            let edges = [0.0] + trimBar.sourceClipBoundaries + [trimBar.duration]
            let k = min(max(0, i), edges.count - 2)
            trimBar.clipHighlight = (.v1(start: edges[k], end: edges[k + 1]), color)
        case .broll(let i):
            trimBar.clipHighlight = (.broll(i), color)
        }
    }

    func updateGroupHeader(clip: String) {
        let g = visualGroups.first(where: { $0.id == activeVisualGroup }) ?? VisualGroup.defaults[0]
        exportDrawer.setGroup(name: g.name, color: g.color, clip: clip,
                              groups: visualGroups.map { ($0.id, $0.name, $0.color) }, current: g.id)
    }

    /// MCP set_visual / get_settings work on the A-roll look: make sure that's the one in the panel.
    func activateArollGroup() {
        guard activeVisualGroup != VisualGroup.arollID else { return }
        let i = arollClips().firstIndex { ($0.visualGroup ?? VisualGroup.arollID) == VisualGroup.arollID } ?? 0
        selectVisualClip(.aroll(i))
    }

    // MARK: Group menu

    func assignSelectedClip(to id: String) {
        guard let clip = selectedVisualClip, visualGroups.contains(where: { $0.id == id }) else { return }
        switch clip {
        case .aroll(let i):
            let clips = arollClips()
            guard clips.indices.contains(i), let k = assets.firstIndex(where: { $0.id == clips[i].id }) else {
                NSSound.beep()   // a single-video project has just the A-roll group
                return
            }
            assets[k].visualGroup = id == VisualGroup.arollID ? nil : id
        case .broll(let i):
            guard broll.indices.contains(i) else { return }
            var list = broll
            list[i].visualGroup = id == VisualGroup.brollID ? nil : id
            setBroll(list)
        }
        syncVisualGroups()
        selectVisualClip(clip)
        saveProject()
    }

    func newGroupForSelectedClip() {
        guard let clip = selectedVisualClip else { return }
        let (_, label) = groupAndLabel(for: clip)
        let suggested = label.components(separatedBy: " · ").last ?? "Group \(visualGroups.count + 1)"
        askGroupName(suggested: suggested) { [weak self] name in
            guard let self else { return }
            let next = (self.visualGroups.map(\.colorIndex).max() ?? 0) + 1
            // Starts from the clip's current look, so nothing jumps; change it from there.
            let start = self.visualGroups.first(where: { $0.id == self.activeVisualGroup })?.look
            self.visualGroups.append(VisualGroup(id: UUID().uuidString, name: name, colorIndex: next, look: start))
            self.assignSelectedClip(to: self.visualGroups.last!.id)
        }
    }

    /// Asks for a new group's name (a sheet with the suggestion selected); nil-safe on Cancel.
    func askGroupName(suggested: String, title: String = "New Visual Design group", then done: @escaping (String) -> Void) {
        guard let window else { done(suggested); return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Give the group a name, like “Camera A”, “Screen recording” or “Outdoor”."
        let field = NSTextField(string: suggested)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            done(name.isEmpty ? suggested : name)
        }
        alert.window.initialFirstResponder = field
    }

    /// Renamed in the Assets tab's group list.
    func renameGroup(_ id: String, to name: String) {
        guard let i = visualGroups.firstIndex(where: { $0.id == id }) else { return }
        visualGroups[i].name = name
        assetsPanel.setGroups(visualGroups.map { ($0.id, $0.name, $0.color) })
        updateGroupHeader(clip: selectedVisualClip.map { groupAndLabel(for: $0).1 } ?? "")
        saveProject()
    }

    /// Assets tab › right-click a group › Delete Group… Asks first (the group's look goes with it).
    func confirmDeleteGroup(_ id: String) {
        guard id != VisualGroup.arollID, id != VisualGroup.brollID,
              let g = visualGroups.first(where: { $0.id == id }) else { return }
        let clips = assets.filter { $0.visualGroup == id }.count
        let shots = broll.filter { $0.visualGroup == id }.count
        guard let window else { deleteGroup(id); return }
        let alert = NSAlert()
        alert.messageText = "Delete the “\(g.name)” group?"
        var info = "Its Visual Design look is deleted with it."
        if clips > 0 {
            let def = visualGroups.first(where: { $0.id == VisualGroup.arollID })?.name ?? "Default"
            info += clips == 1 ? " Its clip moves to “\(def)”." : " Its \(clips) clips move to “\(def)”."
        }
        if shots > 0 {
            let b = visualGroups.first(where: { $0.id == VisualGroup.brollID })?.name ?? "B-roll"
            info += shots == 1 ? " Its B-roll shot moves to “\(b)”." : " Its \(shots) B-roll shots move to “\(b)”."
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.deleteGroup(id)
        }
    }

    /// Removes a group (never Default or B-roll). Its A-roll clips go back to Default, its B-roll
    /// shots back to the B-roll group (both stored as nil).
    func deleteGroup(_ id: String) {
        guard id != VisualGroup.arollID, id != VisualGroup.brollID,
              visualGroups.contains(where: { $0.id == id }) else { return }
        for k in assets.indices where assets[k].visualGroup == id { assets[k].visualGroup = nil }
        if broll.contains(where: { $0.visualGroup == id }) {
            var list = broll
            for k in list.indices where list[k].visualGroup == id { list[k].visualGroup = nil }
            setBroll(list)
        }
        visualGroups.removeAll { $0.id == id }
        assetsPanel.setAssets(assets, selectedID: selectedAssetID)
        syncVisualGroups()
        if let clip = selectedVisualClip {
            selectVisualClip(clip)                  // loads the clip's new group into the panel
        } else if activeVisualGroup == id {
            activeVisualGroup = VisualGroup.arollID
            let look = visualGroups.first(where: { $0.id == VisualGroup.arollID })?.look ?? VisualDesignPanel.Look()
            exportDrawer.applyLook(look) { [weak self] name in self?.lutURL(named: name) }
            updateGroupHeader(clip: "")
        } else {
            updateGroupHeader(clip: "")
        }
        saveProject()
    }

    func renameActiveGroup() {
        guard let i = visualGroups.firstIndex(where: { $0.id == activeVisualGroup }), let window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Visual Design group"
        let field = NSTextField(string: visualGroups[i].name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            self.visualGroups[i].name = name
            self.assetsPanel.setGroups(self.visualGroups.map { ($0.id, $0.name, $0.color) })
            self.updateGroupHeader(clip: self.selectedVisualClip.map { self.groupAndLabel(for: $0).1 } ?? "")
            self.saveProject()
        }
        alert.window.initialFirstResponder = field
    }
}

extension VisualDesignPanel {
    /// The renderable settings of a look (bypassed controls count as 0).
    static func settings(from l: Look) -> ColorGrade.Settings {
        var s = ColorGrade.Settings()
        for row in rows where !l.bypassed.contains(row.title) { s[keyPath: row.key] = l.sliders[row.title] ?? 0 }
        s.blackPoint = l.blackPoint
        s.whitePoint = l.whitePoint
        return s
    }
}


// MARK: Assets tab: right-click a clip (or ⌘-click several) to group them

extension PlayerWindowController {

    /// "Move to New Visual Design Group": one new group for all these clips, starting from the
    /// look they show now (the first clip's group), so nothing jumps until you change it.
    func moveAssetsToNewGroup(_ ids: [UUID]) {
        let picked = assets.filter { ids.contains($0.id) }
        guard let first = picked.first else { return }
        let suggested = picked.count == 1
            ? ((first.path as NSString).lastPathComponent as NSString).deletingPathExtension
            : "Group \(visualGroups.count)"
        askGroupName(suggested: suggested) { [weak self] name in
            guard let self else { return }
            let start = self.visualGroups.first(where: { $0.id == (first.visualGroup ?? VisualGroup.arollID) })?.look
            let next = (self.visualGroups.map(\.colorIndex).max() ?? 0) + 1
            let group = VisualGroup(id: UUID().uuidString, name: name, colorIndex: next, look: start)
            self.visualGroups.append(group)
            self.moveAssets(ids, toGroup: group.id)
        }
    }

    /// Puts these clips into an existing group (the Default group is stored as nil).
    func moveAssets(_ ids: [UUID], toGroup id: String) {
        guard visualGroups.contains(where: { $0.id == id }) else { return }
        for k in assets.indices where ids.contains(assets[k].id) {
            assets[k].visualGroup = id == VisualGroup.arollID ? nil : id
        }
        assetsPanel.setAssets(assets, selectedID: selectedAssetID)
        syncVisualGroups()
        if let clip = selectedVisualClip { selectVisualClip(clip) }
        saveProject()
    }
}


// MARK: Groups by name, for the MCP tools (3.3.3)
// set_visual / get_settings / list_groups / snapshot_frame read and write any group's look
// directly, without touching what the panel shows or which clip is selected.

extension PlayerWindowController {

    /// The group a call works on when it names none: the selected clip's group (what the Visual
    /// Design panel shows), else the A-roll clip's under the playhead.
    func defaultTargetGroupID() -> String {
        if let clip = selectedVisualClip { return groupAndLabel(for: clip).0 }
        return arollGroupID(at: trimBar.playhead)
    }

    /// The group that grades the A-roll (V1) at original-clip time `t`.
    func arollGroupID(at t: Double) -> String {
        let clips = arollClips()
        let i = trimBar.sourceClipBoundaries.filter { t >= $0 }.count
        guard clips.indices.contains(i) else { return VisualGroup.arollID }
        return clips[i].visualGroup ?? VisualGroup.arollID
    }

    func groupName(_ id: String) -> String {
        visualGroups.first(where: { $0.id == id })?.name ?? id
    }

    /// A group by its name (any case) or id; the error lists the names there are.
    func groupID(named name: String) throws -> String {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let g = visualGroups.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame })
            ?? visualGroups.first(where: { $0.id == wanted }) {
            return g.id
        }
        let names = visualGroups.map { "“\($0.name)”" }.joined(separator: ", ")
        throw MCPError("There's no Visual Design group named “\(wanted)”. Groups: \(names).")
    }

    /// A group's look. The group in the panel is read from the panel (it's the live copy).
    func look(ofGroup id: String) -> VisualDesignPanel.Look {
        if id == activeVisualGroup { return exportDrawer.look }
        return visualGroups.first(where: { $0.id == id })?.look ?? VisualDesignPanel.Look()
    }

    /// Gives a group a new look. The group in the panel goes through the panel (so the panel
    /// shows it); any other group is updated behind the scenes. The selection never changes.
    func setLook(_ l: VisualDesignPanel.Look, ofGroup id: String) {
        guard let i = visualGroups.firstIndex(where: { $0.id == id }) else { return }
        if id == activeVisualGroup {
            exportDrawer.applyLook(l) { [weak self] name in self?.lutURL(named: name) }
            return
        }
        visualGroups[i].look = l
        if id == VisualGroup.arollID {
            // The Default group renders from the grade's own settings and LUTs.
            grade.settings = VisualDesignPanel.settings(from: l)
            grade.lut = cachedLUT(l.cameraLUT)
            grade.creativeLUT = cachedLUT(l.creativeLUT)
        }
        syncVisualGroups()   // hands the other groups' looks to the renderer and refreshes the frame
    }

    /// The A-roll clips in a group (1-based index on V1, file, start and end in timeline seconds),
    /// and the B-roll shots in it.
    func timelineClips(inGroup id: String) -> (aroll: [[String: Any]], broll: [[String: Any]]) {
        var a: [[String: Any]] = []
        let clips = arollClips()
        if clips.isEmpty {
            if id == VisualGroup.arollID, trimBar.duration > 0 {      // a single video: Default grades all of it
                let file = currentVideo?.lastPathComponent ?? project?.name ?? "video"
                a.append(["index": 1, "file": file, "start": 0, "end": MCP.r(trimBar.duration),
                          "startTC": MCP.tc(0), "endTC": MCP.tc(trimBar.duration)])
            }
        } else {
            let edges = [0.0] + trimBar.sourceClipBoundaries + [trimBar.duration]
            for (k, c) in clips.enumerated() where (c.visualGroup ?? VisualGroup.arollID) == id && k + 1 < edges.count {
                a.append(["index": k + 1, "file": (c.path as NSString).lastPathComponent,
                          "start": MCP.r(edges[k]), "end": MCP.r(edges[k + 1]),
                          "startTC": MCP.tc(edges[k]), "endTC": MCP.tc(edges[k + 1])])
            }
        }
        var b: [[String: Any]] = []
        for (k, c) in broll.enumerated() where (c.visualGroup ?? VisualGroup.brollID) == id {
            b.append(["index": k + 1, "at": MCP.r(c.at), "atTC": MCP.tc(c.at), "length": MCP.r(c.length),
                      "file": MCP.orNull(c.file.map { ($0 as NSString).lastPathComponent })])
        }
        return (a, b)
    }

    /// Imported clips in a group (whether or not they're on the built A-roll).
    func assetFiles(inGroup id: String) -> [String] {
        assets.filter { !$0.rejected && ($0.visualGroup ?? VisualGroup.arollID) == id }
            .sorted { $0.sortDate < $1.sortDate }
            .map { ($0.path as NSString).lastPathComponent }
    }
}

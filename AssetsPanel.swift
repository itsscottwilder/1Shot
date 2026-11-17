// AssetsPanel — the Assets tab's permanent right-side panel (3.1.0): import source clips,
// review/reject them, trim each one (reusing TrimPanel), and build the assembled A-roll.

import Cocoa
import AVFoundation

final class AssetsPanel: NSVisualEffectView {
    static let width: CGFloat = RightPanel.width

    // AssetsPanel owns no project state itself — the window does, and pushes updates in via
    // setAssets(_:selectedID:). These report user actions back to the window.
    var onImport: (([URL]) -> Void)?
    var onSelect: ((UUID) -> Void)?
    var onToggleReject: ((UUID) -> Void)?
    var onRemove: ((UUID) -> Void)?
    var onBuild: (() -> Void)?
    /// Right-click › Move to New Visual Design Group / Move to Visual Design Group › (every
    /// selected clip when the clicked row is part of a ⌘-click selection).
    var onMoveToNewGroup: (([UUID]) -> Void)?
    var onMoveToGroup: (([UUID], String) -> Void)?
    var onRenameGroup: ((String, String) -> Void)?
    /// Right-click › Delete Group… (every group but Default).
    var onDeleteGroup: ((String) -> Void)?
    /// Reused as-is: edits the currently selected asset's in/out (the window retargets its
    /// closures; the control itself doesn't know or care what it's trimming).
    let trimPanel = TrimPanel()

    private let tableView = NSTableView()
    private var assets: [AssetEntry] = []
    private var selectedID: UUID?
    private var groups: [(id: String, name: String, color: NSColor)] = []
    private let groupsStack = NSStackView()
    private let groupsScroll = NSScrollView()
    private var groupsHeight: NSLayoutConstraint!

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: AssetsPanel.width, height: 400))
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        registerForDraggedTypes([.fileURL])

        let title = NSTextField(labelWithString: "Assets")
        title.font = .boldSystemFont(ofSize: 15)
        let subtitle = NSTextField(labelWithString: "Oldest to newest — drag clips in, or Import…")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 0

        let importButton = NSButton(title: "Import…", target: self, action: #selector(importClicked))
        importButton.bezelStyle = .rounded
        importButton.controlSize = .small
        importButton.refusesFirstResponder = true
        let header = NSStackView(views: [title, NSView(), importButton])
        header.orientation = .horizontal

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("asset"))
        column.width = AssetsPanel.width - 36
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 36
        tableView.dataSource = self
        tableView.delegate = self
        tableView.menu = makeRowMenu()
        tableView.allowsMultipleSelection = true
        tableView.intercellSpacing = NSSize(width: 0, height: 2)

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let buildButton = NSButton(title: "Build A-roll", target: self, action: #selector(buildClicked))
        buildButton.bezelStyle = .rounded
        buildButton.controlSize = .regular
        buildButton.refusesFirstResponder = true
        buildButton.toolTip = "Assembles every non-rejected clip, oldest to newest, each trimmed to its own in/out"

        trimPanel.isHidden = true
        trimPanel.translatesAutoresizingMaskIntoConstraints = false

        // Visual Design groups: every group, its colour and how many clips are in it. Click a name to rename it.
        let groupsTitle = NSTextField(labelWithString: "Visual Design Groups")
        groupsTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        let groupsHint = NSTextField(labelWithString: "Right-click a group to rename or delete it. Right-click clips to regroup them.")
        groupsHint.font = .systemFont(ofSize: 10)
        groupsHint.textColor = .tertiaryLabelColor
        groupsStack.orientation = .vertical
        groupsStack.alignment = .leading
        groupsStack.spacing = 2
        groupsStack.translatesAutoresizingMaskIntoConstraints = false
        let groupsDoc = FlippedView()
        groupsDoc.translatesAutoresizingMaskIntoConstraints = false
        groupsDoc.addSubview(groupsStack)
        groupsScroll.documentView = groupsDoc
        groupsScroll.hasVerticalScroller = true
        groupsScroll.drawsBackground = false
        groupsScroll.autohidesScrollers = true
        groupsScroll.scrollerStyle = .overlay
        groupsScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            groupsStack.leadingAnchor.constraint(equalTo: groupsDoc.leadingAnchor),
            groupsStack.trailingAnchor.constraint(equalTo: groupsDoc.trailingAnchor),
            groupsStack.topAnchor.constraint(equalTo: groupsDoc.topAnchor),
            groupsStack.bottomAnchor.constraint(equalTo: groupsDoc.bottomAnchor),
            groupsDoc.widthAnchor.constraint(equalTo: groupsScroll.contentView.widthAnchor)
        ])
        let groupsSection = NSStackView(views: [groupsTitle, groupsHint, groupsScroll])
        groupsSection.orientation = .vertical
        groupsSection.alignment = .leading
        groupsSection.spacing = 4
        groupsSection.translatesAutoresizingMaskIntoConstraints = false
        groupsScroll.widthAnchor.constraint(equalTo: groupsSection.widthAnchor).isActive = true
        groupsHeight = groupsScroll.heightAnchor.constraint(equalToConstant: 26)
        groupsHeight.isActive = true

        let stack = NSStackView(views: [header, subtitle, scroll, trimPanel, groupsSection, buildButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(16, after: subtitle)
        stack.setCustomSpacing(16, after: scroll)
        stack.setCustomSpacing(16, after: trimPanel)
        stack.setCustomSpacing(16, after: groupsSection)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 220),
            trimPanel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            groupsSection.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buildButton.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Refreshes the list from the window's current data. Call after any change.
    func setAssets(_ newAssets: [AssetEntry], selectedID: UUID?) {
        // A ⌘-click selection of several clips survives the refresh (e.g. after moving them to a group).
        let multi = tableView.selectedRowIndexes.count > 1
            ? Set(tableView.selectedRowIndexes.compactMap { assets.indices.contains($0) ? assets[$0].id : nil }) : []
        assets = newAssets
        rebuildGroupList()
        self.selectedID = selectedID   // set before reloading, so the selection-changed guard below is a no-op
        tableView.reloadData()
        let keep = IndexSet(assets.indices.filter { multi.contains(assets[$0].id) })
        if keep.count > 1 {
            tableView.selectRowIndexes(keep, byExtendingSelection: false)
            trimPanel.isHidden = true
        } else if let selectedID, let idx = assets.firstIndex(where: { $0.id == selectedID }) {
            tableView.selectRowIndexes([idx], byExtendingSelection: false)
            trimPanel.isHidden = false
            trimPanel.update(start: assets[idx].inPoint, end: assets[idx].outPoint)
        } else {
            tableView.deselectAll(nil)
            trimPanel.isHidden = true
        }
    }

    /// The Visual Design groups, for the row tags and the right-click menu.
    func setGroups(_ list: [(id: String, name: String, color: NSColor)]) {
        groups = list
        tableView.reloadData()
        rebuildGroupList()
    }

    /// One row per group (B-roll's group isn't about assets, so it's left out): swatch, editable name, clip count.
    private func rebuildGroupList() {
        guard groupsHeight != nil else { return }
        // Don't rebuild under the user's typing.
        if groupsStack.arrangedSubviews.contains(where: { ($0 as? GroupListRow)?.isEditing == true }) { return }
        groupsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let shown = groups.filter { $0.id != "broll" }
        for g in shown {
            let count = assets.filter { ($0.visualGroup ?? "aroll") == g.id }.count
            let row = GroupListRow(id: g.id, name: g.name, color: g.color, count: count)
            row.onRename = { [weak self] id, name in self?.onRenameGroup?(id, name) }
            row.onDelete = { [weak self] id in self?.onDeleteGroup?(id) }
            groupsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: groupsStack.widthAnchor).isActive = true
        }
        groupsHeight.constant = min(132, max(26, CGFloat(shown.count) * 26))
    }

    private func makeRowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    /// The clips a right-click acts on: the whole selection when the clicked row is in it.
    private var menuTargets: [UUID] {
        let row = tableView.clickedRow
        guard assets.indices.contains(row) else { return [] }
        let rows = tableView.selectedRowIndexes.contains(row) ? Array(tableView.selectedRowIndexes) : [row]
        return rows.filter { assets.indices.contains($0) }.map { assets[$0].id }
    }

    @objc private func newGroupClicked() {
        let ids = menuTargets
        if !ids.isEmpty { onMoveToNewGroup?(ids) }
    }

    @objc private func groupClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let ids = menuTargets
        if !ids.isEmpty { onMoveToGroup?(ids, id) }
    }

    static func swatch(_ color: NSColor, size: CGFloat = 10) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            color.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
    }

    @objc private func importClicked() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audiovisualContent]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        onImport?(panel.urls)
    }

    @objc private func buildClicked() { onBuild?() }

    @objc private func removeClicked() {
        for id in menuTargets { onRemove?(id) }
    }

    // MARK: Drag-and-drop import

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                                options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        onImport?(urls)
        return true
    }
}

extension AssetsPanel: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let ids = menuTargets
        guard !ids.isEmpty else { return }
        let many = ids.count > 1
        let new = NSMenuItem(title: many ? "Move \(ids.count) Clips to New Visual Design Group" : "Move to New Visual Design Group",
                             action: #selector(newGroupClicked), keyEquivalent: "")
        new.target = self
        menu.addItem(new)
        if !groups.isEmpty {
            let current = Set(assets.filter { ids.contains($0.id) }.map { $0.visualGroup ?? "aroll" })
            let sub = NSMenu()
            for g in groups where g.id != "broll" {
                let item = NSMenuItem(title: g.name, action: #selector(groupClicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = g.id
                item.image = Self.swatch(g.color)
                item.state = current == [g.id] ? .on : .off
                sub.addItem(item)
            }
            let move = NSMenuItem(title: "Move to Visual Design Group", action: nil, keyEquivalent: "")
            move.submenu = sub
            menu.addItem(move)
        }
        menu.addItem(.separator())
        let remove = NSMenuItem(title: many ? "Remove \(ids.count) Clips" : "Remove", action: #selector(removeClicked), keyEquivalent: "")
        remove.target = self
        menu.addItem(remove)
    }
}

extension AssetsPanel: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { assets.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("AssetRow")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? AssetRow) ?? AssetRow()
        cell.identifier = identifier
        let asset = assets[row]
        let g = groups.first { $0.id == (asset.visualGroup ?? "aroll") }
        cell.configure(asset, group: g.map { ($0.name, $0.color) })
        cell.onToggle = { [weak self] in self?.onToggleReject?(asset.id) }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if tableView.selectedRowIndexes.count > 1 { trimPanel.isHidden = true; return }   // ⌘-click: grouping only
        guard tableView.selectedRow >= 0, assets.indices.contains(tableView.selectedRow) else { return }
        let asset = assets[tableView.selectedRow]
        trimPanel.isHidden = false
        trimPanel.update(start: asset.inPoint, end: asset.outPoint)
        guard asset.id != selectedID else { return }   // a programmatic re-select from setAssets(); don't reload
        selectedID = asset.id
        onSelect?(asset.id)
    }
}

/// One row: filename + a small in/out (or duration) readout, and a red/green reject toggle.
final class AssetRow: NSTableCellView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let rangeLabel = NSTextField(labelWithString: "")
    private let toggleButton = NSButton()
    var onToggle: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        rangeLabel.font = .systemFont(ofSize: 10)
        rangeLabel.textColor = .secondaryLabelColor

        toggleButton.title = ""
        toggleButton.isBordered = false
        toggleButton.wantsLayer = true
        toggleButton.layer?.cornerRadius = 7
        toggleButton.target = self
        toggleButton.action = #selector(toggled)
        toggleButton.refusesFirstResponder = true
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            toggleButton.widthAnchor.constraint(equalToConstant: 14),
            toggleButton.heightAnchor.constraint(equalToConstant: 14)
        ])

        let textStack = NSStackView(views: [nameLabel, rangeLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1

        let row = NSStackView(views: [toggleButton, textStack])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggled() { onToggle?() }

    func configure(_ asset: AssetEntry, group: (name: String, color: NSColor)? = nil) {
        nameLabel.stringValue = (asset.path as NSString).lastPathComponent
        let trimmed = asset.outPoint > asset.inPoint + 0.01 && (asset.inPoint > 0 || asset.outPoint < asset.duration - 0.01)
        rangeLabel.stringValue = trimmed
            ? "\(TrimBar.format(asset.inPoint)) – \(TrimBar.format(asset.outPoint))"
            : TrimBar.format(asset.duration)
        if let group {
            let text = NSMutableAttributedString(string: rangeLabel.stringValue + "  ·  ",
                                                 attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: rangeLabel.font!])
            text.append(NSAttributedString(string: "● " + group.name,
                                           attributes: [.foregroundColor: group.color, .font: rangeLabel.font!]))
            rangeLabel.attributedStringValue = text
        }
        toggleButton.layer?.backgroundColor = (asset.rejected ? NSColor.systemRed : NSColor.systemGreen).cgColor
        toggleButton.toolTip = asset.rejected ? "Rejected — click to include" : "Included — click to reject"
    }
}


/// An editable text field whose right-click shows its own `menu` (e.g. Rename…). An editable
/// field otherwise handles right-clicks itself and never shows a menu set on it.
final class RightClickMenuField: NSTextField {
    override func rightMouseDown(with event: NSEvent) {
        guard currentEditor() == nil, let menu else { super.rightMouseDown(with: event); return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// An image that ignores the mouse, so clicks and right-clicks go to the view behind it.
final class PassThroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A row in the Visual Design Groups list: colour dot, name (click to rename), clip count.
final class GroupListRow: NSView, NSTextFieldDelegate {
    let groupID: String
    var onRename: ((String, String) -> Void)?
    var onDelete: ((String) -> Void)?
    private let field: NSTextField
    private var original: String
    private(set) var isEditing = false

    init(id: String, name: String, color: NSColor, count: Int) {
        groupID = id
        original = name
        field = RightClickMenuField(string: name)
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        translatesAutoresizingMaskIntoConstraints = false
        let dot = PassThroughImageView(image: AssetsPanel.swatch(color, size: 11))
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.delegate = self
        field.toolTip = "Click or right-click to rename"
        let countLabel = NSTextField(labelWithString: count == 1 ? "1 clip" : "\(count) clips")
        countLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [dot, field, countLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        // Right-click anywhere on the row (dot, name or count): Rename…, and Delete Group… for
        // every group but Default (its clips go back to Default).
        let menu = NSMenu()
        let rename = NSMenuItem(title: "Rename…", action: #selector(startRename), keyEquivalent: "")
        rename.target = self
        menu.addItem(rename)
        if id != VisualGroup.arollID {
            menu.addItem(.separator())
            let delete = NSMenuItem(title: "Delete Group…", action: #selector(deleteClicked), keyEquivalent: "")
            delete.target = self
            menu.addItem(delete)
        }
        self.menu = menu
        field.menu = menu
        countLabel.menu = menu

    }
    required init?(coder: NSCoder) { fatalError() }

    /// Puts the name into editing with all of it selected; Return saves, Esc puts the old name back.
    @objc func startRename() {
        guard let window else { return }
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    @objc private func deleteClicked() { onDelete?(groupID) }

    func controlTextDidBeginEditing(_ obj: Notification) { isEditing = true }

    func controlTextDidEndEditing(_ obj: Notification) {
        isEditing = false
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { field.stringValue = original; return }
        guard name != original else { return }
        original = name
        onRename?(groupID, name)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {   // Esc puts the old name back
            field.stringValue = original
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }
}

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
    /// The file behind an asset (its path is Media/-relative), for the details under a selected row.
    var urlForAsset: ((AssetEntry) -> URL?)?
    /// Reused as-is: edits the currently selected asset's in/out (the window retargets its
    /// closures; the control itself doesn't know or care what it's trimming).
    let trimPanel = TrimPanel()

    private let tableView = NSTableView()
    private var assets: [AssetEntry] = []
    private var selectedID: UUID?
    /// The row showing its file details (3.5): the selected clip, until it's clicked again.
    private var expandedID: UUID?
    /// Set when a click selects a new row, so that click doesn't also collapse it.
    private var selectionJustChanged = false
    /// The clip list is as tall as its rows (3.5), so an open clip pushes Trim and the rest down.
    private var listHeight: NSLayoutConstraint!
    private var contentStack: NSStackView!
    private var groups: [(id: String, name: String, color: NSColor)] = []
    private let groupsStack = NSStackView()
    private let groupsScroll = PassThroughScrollView()
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
        tableView.target = self
        tableView.action = #selector(rowClicked)

        // Never scrolls (3.5): always as tall as its rows, so opening a clip pushes the clips
        // below it, Trim and the rest down. The whole panel scrolls instead, if it ever must.
        let scroll = PassThroughScrollView()
        scroll.documentView = tableView
        scroll.drawsBackground = false
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
        groupsScroll.drawsBackground = false
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
        contentStack = stack
        listHeight = scroll.heightAnchor.constraint(equalToConstant: 8)

        // The panel's contents scroll as one page, with no scroll bar, only if they're taller than the window.
        let page = FlippedView()
        page.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(stack)
        let pageScroll = NSScrollView()
        pageScroll.documentView = page
        pageScroll.drawsBackground = false
        pageScroll.hasVerticalScroller = false
        pageScroll.hasHorizontalScroller = false
        pageScroll.verticalScrollElasticity = .none
        pageScroll.horizontalScrollElasticity = .none
        pageScroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pageScroll)
        NSLayoutConstraint.activate([
            pageScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            pageScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            pageScroll.topAnchor.constraint(equalTo: topAnchor),
            pageScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            page.widthAnchor.constraint(equalTo: pageScroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: page.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -16),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            listHeight,
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
        if expandedID != selectedID || keep.count > 1 { expandedID = nil }
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
        updateListHeight()
    }

    override func layout() {
        super.layout()
        updateListHeight()   // the window was resized, or the Trim panel came or went
    }

    /// Sizes the list to fit every row (an open clip's details included). It never scrolls.
    private func updateListHeight(animated: Bool = false) {
        guard let listHeight else { return }
        // The table's own row positions, so its padding and row spacing are counted too.
        let content = assets.isEmpty ? 0 : tableView.rect(ofRow: assets.count - 1).maxY + 4
        let target = max(8, content)
        guard abs(target - listHeight.constant) > 0.5 else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.allowsImplicitAnimation = true
                listHeight.animator().constant = target
                layoutSubtreeIfNeeded()
            }
        } else {
            listHeight.constant = target
        }
    }

    /// The Visual Design groups, for the row tags and the right-click menu.
    func setGroups(_ list: [(id: String, name: String, color: NSColor)]) {
        groups = list
        tableView.reloadData()
        rebuildGroupList()
        updateListHeight()
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
        groupsHeight.constant = max(26, CGFloat(shown.count) * 26)   // every group shows; no scrolling
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

    // MARK: File details (3.5)

    /// A second click on the selected row folds its details away; another click brings them back.
    @objc private func rowClicked() {
        if selectionJustChanged { selectionJustChanged = false; return }
        let row = tableView.clickedRow
        guard assets.indices.contains(row), tableView.selectedRowIndexes == [row] else { return }
        setExpanded(expandedID == assets[row].id ? nil : assets[row].id)
    }

    private func setExpanded(_ id: UUID?) {
        let old = expandedID.flatMap { e in assets.firstIndex { $0.id == e } }
        expandedID = id
        let new = id.flatMap { e in assets.firstIndex { $0.id == e } }
        refreshRows([old, new].compactMap { $0 })
        guard let id, let new, let url = urlForAsset?(assets[new]) else { return }
        if ClipInfo.cached(url) == nil {
            Task { @MainActor [weak self] in
                _ = await ClipInfo.load(url)
                guard let self, self.expandedID == id,
                      let row = self.assets.firstIndex(where: { $0.id == id }) else { return }
                self.refreshRows([row])
            }
        }
    }

    /// Re-fills and re-sizes rows (animated) and keeps an expanded row in view.
    private func refreshRows(_ rows: [Int]) {
        let set = IndexSet(rows.filter { assets.indices.contains($0) })
        guard !set.isEmpty else { return }
        for row in set { configureCell(tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? AssetRow, row: row) }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            tableView.noteHeightOfRows(withIndexesChanged: set)
        }
        updateListHeight(animated: true)
    }

    /// The details to show under a row, or nil when it isn't expanded.
    private func details(forRow row: Int) -> ClipInfo? {
        let asset = assets[row]
        guard asset.id == expandedID, tableView.selectedRowIndexes.count <= 1 else { return nil }
        guard let url = urlForAsset?(asset) else { return ClipInfo(lines: [("File", "Not found")]) }
        return ClipInfo.cached(url) ?? ClipInfo(lines: [("", "Reading file…")])
    }

    private func configureCell(_ cell: AssetRow?, row: Int) {
        guard let cell, assets.indices.contains(row) else { return }
        let asset = assets[row]
        let g = groups.first { $0.id == (asset.visualGroup ?? "aroll") }
        cell.configure(asset, group: g.map { ($0.name, $0.color) }, details: details(forRow: row))
        cell.onToggle = { [weak self] in self?.onToggleReject?(asset.id) }
    }

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
        configureCell(cell, row: row)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard assets.indices.contains(row), let info = details(forRow: row) else { return AssetRow.baseHeight }
        return AssetRow.baseHeight + AssetRow.detailsHeight(lines: info.lines.count)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if tableView.selectedRowIndexes.count > 1 {   // ⌘-click: grouping only
            trimPanel.isHidden = true
            if expandedID != nil { setExpanded(nil) }
            return
        }
        guard tableView.selectedRow >= 0, assets.indices.contains(tableView.selectedRow) else { return }
        let asset = assets[tableView.selectedRow]
        trimPanel.isHidden = false
        trimPanel.update(start: asset.inPoint, end: asset.outPoint)
        guard asset.id != selectedID else { return }   // a programmatic re-select from setAssets(); don't reload
        selectedID = asset.id
        selectionJustChanged = true
        setExpanded(asset.id)
        onSelect?(asset.id)
    }
}

/// One row: filename + a small in/out (or duration) readout, and a red/green reject toggle.
final class AssetRow: NSTableCellView {
    static let baseHeight: CGFloat = 36
    private static let lineHeight: CGFloat = 15
    static func detailsHeight(lines: Int) -> CGFloat { CGFloat(lines) * lineHeight + 10 }

    private let nameLabel = NSTextField(labelWithString: "")
    private let rangeLabel = NSTextField(labelWithString: "")
    private let toggleButton = NSButton()
    /// File details (3.5), under the name when the row is expanded.
    private let detailsLabel = NSTextField(labelWithString: "")
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

        detailsLabel.maximumNumberOfLines = 0
        detailsLabel.lineBreakMode = .byWordWrapping   // each line truncates itself (paragraph style)
        detailsLabel.isSelectable = true   // so a value can be copied
        detailsLabel.translatesAutoresizingMaskIntoConstraints = false
        detailsLabel.isHidden = true
        addSubview(detailsLabel)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            // The name stays in the top 36 pt; the details open up below it.
            row.centerYAnchor.constraint(equalTo: topAnchor, constant: AssetRow.baseHeight / 2),
            detailsLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            detailsLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            detailsLabel.topAnchor.constraint(equalTo: topAnchor, constant: AssetRow.baseHeight)
        ])
    }

    /// NSTableCellView isn't flipped, so "top" would follow the bottom edge as the row grows.
    override var isFlipped: Bool { true }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggled() { onToggle?() }

    func configure(_ asset: AssetEntry, group: (name: String, color: NSColor)? = nil, details: ClipInfo? = nil) {
        setDetails(details)
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

    /// Two columns, labels in grey, one fixed-height line per detail (so the row height is exact).
    private func setDetails(_ info: ClipInfo?) {
        guard let info else { detailsLabel.isHidden = true; detailsLabel.stringValue = ""; return }
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .left, location: 84)]
        para.minimumLineHeight = AssetRow.lineHeight
        para.maximumLineHeight = AssetRow.lineHeight
        para.lineBreakMode = .byTruncatingTail
        let font = NSFont.systemFont(ofSize: 10.5)
        let text = NSMutableAttributedString()
        for (i, line) in info.lines.enumerated() {
            if i > 0 { text.append(NSAttributedString(string: "\n")) }
            text.append(NSAttributedString(string: line.label + "\t",
                                           attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: para]))
            text.append(NSAttributedString(string: line.value,
                                           attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para]))
        }
        detailsLabel.attributedStringValue = text
        detailsLabel.isHidden = false
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

/// A scroll view that never scrolls or shows a scroll bar: it's always as tall as its contents,
/// and hands the trackpad on to the panel around it.
final class PassThroughScrollView: NSScrollView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        hasVerticalScroller = false
        hasHorizontalScroller = false
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .none
    }
    required init?(coder: NSCoder) { fatalError() }
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
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

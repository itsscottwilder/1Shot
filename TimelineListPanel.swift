// TimelineListPanel — 3.2: the right-side panel for the Cuts, Zooms, B-roll and Graphics tabs.
// One list per tab, in timeline order: each row has a colour tag, an optional thumbnail, a label,
// and In / Out timecodes (MM:SS:FF) you can type into to move an edge to the exact frame
// (Return applies). Click a row to jump there; the trash button removes it. The window owns the
// data and pushes rows in with setRows(_:summary:); edits come back through the closures.

import Cocoa

struct TimelineListRow {
    var start: Double            // original-clip seconds
    var end: Double?             // nil = no out point (e.g. a zoom with no reset after it)
    var title: String
    var detail: String = ""
    var color: NSColor
    var thumbnail: NSImage? = nil
}

final class TimelineListPanel: NSVisualEffectView, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((Int) -> Void)?
    var onEditStart: ((Int, Double) -> Void)?
    var onEditEnd: ((Int, Double) -> Void)?
    var onDelete: ((Int) -> Void)?
    /// The selected row changed (nil = none): lets a tab enable its extra controls.
    var onSelectionChanged: ((Int?) -> Void)?

    private let showsThumbnails: Bool
    private let inLabel: String, outLabel: String
    private let table = NSTableView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private var rows: [TimelineListRow] = []
    private var suppressSelect = false

    var selectedRow: Int? { table.selectedRow >= 0 ? table.selectedRow : nil }
    var rowCount: Int { rows.count }

    init(title: String, subtitle: String, inLabel: String = "In", outLabel: String = "Out",
         thumbnails: Bool, accessory: NSView? = nil) {
        showsThumbnails = thumbnails
        self.inLabel = inLabel
        self.outLabel = outLabel
        super.init(frame: NSRect(x: 0, y: 0, width: RightPanel.width, height: 400))
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .boldSystemFont(ofSize: 15)
        let sub = NSTextField(wrappingLabelWithString: subtitle)
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        summaryLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        summaryLabel.textColor = .secondaryLabelColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = thumbnails ? 72 : 58
        table.intercellSpacing = NSSize(width: 0, height: 3)
        table.dataSource = self
        table.delegate = self
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false

        var views: [NSView] = [titleLabel, sub, summaryLabel, scroll]
        if let accessory { views.append(accessory) }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(12, after: sub)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            sub.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ]
        if let accessory { constraints.append(accessory.widthAnchor.constraint(equalTo: stack.widthAnchor)) }
        NSLayoutConstraint.activate(constraints)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Replaces the list (keeps the selection when the row count is unchanged).
    func setRows(_ newRows: [TimelineListRow], summary: String) {
        let keep = newRows.count == rows.count ? selectedRow : nil
        rows = newRows
        summaryLabel.stringValue = summary
        suppressSelect = true
        table.reloadData()
        if let keep, keep < rows.count { table.selectRowIndexes([keep], byExtendingSelection: false) }
        suppressSelect = false
        onSelectionChanged?(selectedRow)
    }

    func setThumbnail(_ image: NSImage, row: Int) {
        guard rows.indices.contains(row) else { return }
        rows[row].thumbnail = image
        (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TimelineRowView)?.thumb.image = image
    }

    func select(_ row: Int?) {
        suppressSelect = true
        if let row, rows.indices.contains(row) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        } else {
            table.deselectAll(nil)
        }
        suppressSelect = false
        onSelectionChanged?(selectedRow)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("TimelineRowView")
        let view = (tableView.makeView(withIdentifier: id, owner: self) as? TimelineRowView)
            ?? TimelineRowView(thumbnails: showsThumbnails, inLabel: inLabel, outLabel: outLabel)
        view.identifier = id
        view.configure(rows[row], number: row + 1)
        view.onEditStart = { [weak self, weak view] t in
            guard let self, let view, let r = self.row(of: view) else { return }
            self.onEditStart?(r, t)
        }
        view.onEditEnd = { [weak self, weak view] t in
            guard let self, let view, let r = self.row(of: view) else { return }
            self.onEditEnd?(r, t)
        }
        view.onDelete = { [weak self, weak view] in
            guard let self, let view, let r = self.row(of: view) else { return }
            self.onDelete?(r)
        }
        return view
    }

    private func row(of view: NSView) -> Int? {
        let r = table.row(for: view)
        return r >= 0 ? r : nil
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelectionChanged?(selectedRow)
        guard !suppressSelect, let r = selectedRow else { return }
        onSelect?(r)
    }
}

/// One row: colour tag · thumbnail · "#n title" / detail · In [field] Out [field] · trash.
final class TimelineRowView: NSTableCellView {
    var onEditStart: ((Double) -> Void)?
    var onEditEnd: ((Double) -> Void)?
    var onDelete: (() -> Void)?

    let thumb = NSImageView()
    private let colorTag = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let inField = NSTextField(string: "")
    private let outField = NSTextField(string: "")
    private let showsThumb: Bool

    init(thumbnails: Bool, inLabel: String, outLabel: String) {
        showsThumb = thumbnails
        super.init(frame: NSRect(x: 0, y: 0, width: RightPanel.width - 20, height: thumbnails ? 72 : 58))
        colorTag.wantsLayer = true
        colorTag.layer?.cornerRadius = 2
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 10.5)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 3
        thumb.layer?.masksToBounds = true
        thumb.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor

        for f in [inField, outField] {
            f.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            f.controlSize = .small
            f.bezelStyle = .roundedBezel
            f.alignment = .center
            f.target = self
            f.toolTip = "MM:SS:FF — type a new time and press Return"
        }
        inField.action = #selector(inEdited)
        outField.action = #selector(outEdited)

        let trash = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Remove") ?? NSImage(),
                             target: self, action: #selector(deleteClicked))
        trash.isBordered = false
        trash.contentTintColor = .secondaryLabelColor
        trash.toolTip = "Remove"

        let inTitle = NSTextField(labelWithString: inLabel)
        let outTitle = NSTextField(labelWithString: outLabel)
        for l in [inTitle, outTitle] { l.font = .systemFont(ofSize: 10); l.textColor = .tertiaryLabelColor }

        for v in [colorTag, thumb, titleLabel, detailLabel, inTitle, inField, outTitle, outField, trash] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        thumb.isHidden = !thumbnails
        let textLeft = thumbnails ? thumb.trailingAnchor : colorTag.trailingAnchor
        NSLayoutConstraint.activate([
            colorTag.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            colorTag.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            colorTag.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            colorTag.widthAnchor.constraint(equalToConstant: 4),

            thumb.leadingAnchor.constraint(equalTo: colorTag.trailingAnchor, constant: 6),
            thumb.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            thumb.widthAnchor.constraint(equalToConstant: thumbnails ? 64 : 0),
            thumb.heightAnchor.constraint(equalToConstant: 36),

            titleLabel.leadingAnchor.constraint(equalTo: textLeft, constant: 7),
            titleLabel.trailingAnchor.constraint(equalTo: trash.leadingAnchor, constant: -4),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),

            // With a thumbnail, the timecodes get their own line under it, from the left edge,
            // so the whole row fits inside the selection highlight (2026-11-11).
            inTitle.leadingAnchor.constraint(equalTo: thumbnails ? thumb.leadingAnchor : titleLabel.leadingAnchor),
            inTitle.centerYAnchor.constraint(equalTo: inField.centerYAnchor),
            inField.leadingAnchor.constraint(equalTo: inTitle.trailingAnchor, constant: 3),
            inField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            inField.widthAnchor.constraint(equalToConstant: 68),
            outTitle.leadingAnchor.constraint(equalTo: inField.trailingAnchor, constant: 8),
            outTitle.centerYAnchor.constraint(equalTo: inField.centerYAnchor),
            outField.leadingAnchor.constraint(equalTo: outTitle.trailingAnchor, constant: 3),
            outField.centerYAnchor.constraint(equalTo: inField.centerYAnchor),
            outField.widthAnchor.constraint(equalToConstant: 68),

            trash.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            trash.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            trash.widthAnchor.constraint(equalToConstant: 18)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ row: TimelineListRow, number: Int) {
        colorTag.layer?.backgroundColor = row.color.cgColor
        titleLabel.stringValue = "\(number). \(row.title)"
        detailLabel.stringValue = row.detail
        inField.stringValue = TrimBar.format(row.start)
        outField.stringValue = row.end.map { TrimBar.format($0) } ?? "—"
        thumb.image = row.thumbnail
    }

    @objc private func inEdited() {
        guard let t = TrimBar.parseTimecode(inField.stringValue) else { NSSound.beep(); return }
        onEditStart?(t)
    }
    @objc private func outEdited() {
        guard let t = TrimBar.parseTimecode(outField.stringValue) else { NSSound.beep(); return }
        onEditEnd?(t)
    }
    @objc private func deleteClicked() { onDelete?() }
}

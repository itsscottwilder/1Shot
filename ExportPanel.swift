// ExportPanel — 3.2: the Export tab's right-side panel. Pick a recipe (YouTube 1080p/4K/8K,
// masters, social sites…), see exactly what it will write, then Export… (⌘Y uses the same recipe).

import Cocoa

final class ExportPanel: NSVisualEffectView {
    var onExport: (() -> Void)?
    var onRecipeChanged: ((ExportRecipe) -> Void)?

    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let specs = NSTextField(wrappingLabelWithString: "")
    private let notes = NSTextField(wrappingLabelWithString: "")
    private let output = NSTextField(wrappingLabelWithString: "")
    private let warning = NSTextField(wrappingLabelWithString: "")
    // Custom (3.2): The user's own settings, shown only when "Custom" is chosen.
    private let customBox = NSStackView()
    private let codecPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let audioPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let bitrateSlider = NSSlider(value: 12, minValue: 1, maxValue: 200, target: nil, action: nil)
    private let bitrateField = NSTextField(string: "12")
    private var bitrateRow: NSView!
    private var lastSize: (Int, Int, Double?) = (0, 0, nil)

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: RightPanel.width, height: 400))
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)

        let title = NSTextField(labelWithString: "Export")
        title.font = .boldSystemFont(ofSize: 15)
        let sub = NSTextField(wrappingLabelWithString: "Choose where the video is going. Everything in your edit is included: cuts, zooms, B-roll, graphics, color and sound.")
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor

        let menu = NSMenu()
        var lastGroup = ""
        for r in ExportRecipe.all {
            if r.group != lastGroup {
                if !lastGroup.isEmpty { menu.addItem(.separator()) }
                let header = NSMenuItem(title: r.group.uppercased(), action: nil, keyEquivalent: "")
                header.isEnabled = false
                header.attributedTitle = NSAttributedString(string: r.group.uppercased(), attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
                menu.addItem(header)
                lastGroup = r.group
            }
            let item = NSMenuItem(title: r.name, action: nil, keyEquivalent: "")
            item.representedObject = r.id
            item.indentationLevel = 1
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let customHeader = NSMenuItem(title: "CUSTOM", action: nil, keyEquivalent: "")
        customHeader.isEnabled = false
        customHeader.attributedTitle = NSAttributedString(string: "CUSTOM", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
        menu.addItem(customHeader)
        let customItem = NSMenuItem(title: "Custom…", action: nil, keyEquivalent: "")
        customItem.representedObject = CustomExport.id
        customItem.indentationLevel = 1
        menu.addItem(customItem)
        popup.menu = menu
        popup.autoenablesItems = false
        popup.target = self
        popup.action = #selector(recipeChosen)

        specs.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        notes.font = .systemFont(ofSize: 11)
        notes.textColor = .secondaryLabelColor
        output.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        warning.font = .systemFont(ofSize: 11, weight: .medium)
        warning.textColor = .systemOrange

        let button = NSButton(title: "Export…", target: self, action: #selector(exportClicked))
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.keyEquivalent = ""
        let shortcut = NSTextField(labelWithString: "⌘Y exports with this recipe")
        shortcut.font = .systemFont(ofSize: 10.5)
        shortcut.textColor = .tertiaryLabelColor

        setUpCustom()
        let stack = NSStackView(views: [title, sub, popup, customBox, specs, notes, output, warning, button, shortcut])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(16, after: sub)
        stack.setCustomSpacing(18, after: warning)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            sub.widthAnchor.constraint(equalTo: stack.widthAnchor),
            popup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            customBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            specs.widthAnchor.constraint(equalTo: stack.widthAnchor),
            notes.widthAnchor.constraint(equalTo: stack.widthAnchor),
            output.widthAnchor.constraint(equalTo: stack.widthAnchor),
            warning.widthAnchor.constraint(equalTo: stack.widthAnchor),
            button.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        select(ExportRecipe.current)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func select(_ r: ExportRecipe) {
        if let item = popup.menu?.items.first(where: { ($0.representedObject as? String) == r.id }) { popup.select(item) }
        specs.stringValue = r.specs
        notes.stringValue = r.notes
        customBox.isHidden = r.id != CustomExport.id
        if r.id == CustomExport.id { showCustom(CustomExport.saved) }
    }

    // MARK: Custom

    private func setUpCustom() {
        func row(_ label: String, _ control: NSView) -> NSView {
            let l = NSTextField(labelWithString: label)
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            l.alignment = .right
            l.widthAnchor.constraint(equalToConstant: 66).isActive = true
            let r = NSStackView(views: [l, control])
            r.orientation = .horizontal
            r.spacing = 8
            return r
        }
        for (p, items) in [(codecPopup, CustomExport.codecs.map(\.name)), (sizePopup, CustomExport.heights.map(\.name)),
                           (audioPopup, CustomExport.audio.map(\.name))] {
            p.addItems(withTitles: items)
            p.controlSize = .small
            p.font = .systemFont(ofSize: 11)
            p.target = self
            p.action = #selector(customChanged(_:))
        }
        bitrateSlider.controlSize = .small
        bitrateSlider.target = self
        bitrateSlider.action = #selector(customChanged(_:))
        bitrateField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        bitrateField.controlSize = .small
        bitrateField.alignment = .right
        bitrateField.target = self
        bitrateField.action = #selector(customChanged(_:))
        bitrateField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let unit = NSTextField(labelWithString: "Mbps")
        unit.font = .systemFont(ofSize: 11)
        unit.textColor = .secondaryLabelColor
        let bitrate = NSStackView(views: [bitrateSlider, bitrateField, unit])
        bitrate.spacing = 6
        bitrateRow = row("Bitrate", bitrate)
        let rows = [row("Codec", codecPopup), row("Size", sizePopup), bitrateRow!, row("Audio", audioPopup)]
        rows.forEach { customBox.addArrangedSubview($0) }
        customBox.orientation = .vertical
        customBox.alignment = .leading
        customBox.spacing = 6
        customBox.isHidden = true
        for r in rows { r.widthAnchor.constraint(equalTo: customBox.widthAnchor).isActive = true }
    }

    private func showCustom(_ c: CustomExport) {
        codecPopup.selectItem(at: CustomExport.codecs.firstIndex { $0.id == c.codec } ?? 0)
        sizePopup.selectItem(at: CustomExport.heights.firstIndex { $0.height == c.height } ?? 0)
        audioPopup.selectItem(at: CustomExport.audio.firstIndex { $0.kbps == c.audioKbps } ?? 3)
        bitrateSlider.doubleValue = c.mbps
        bitrateField.stringValue = c.mbps == c.mbps.rounded() ? String(Int(c.mbps)) : String(format: "%.1f", c.mbps)
        bitrateRow.isHidden = c.codec.hasPrefix("prores")
    }

    @objc private func customChanged(_ sender: Any) {
        var c = CustomExport.saved
        c.codec = CustomExport.codecs[max(0, codecPopup.indexOfSelectedItem)].id
        let newHeight = CustomExport.heights[max(0, sizePopup.indexOfSelectedItem)].height
        if (sender as? NSPopUpButton) === sizePopup, newHeight != c.height {
            c.mbps = CustomExport.suggestedMbps(height: newHeight)    // a fresh size starts at its usual bitrate
        } else if (sender as? NSSlider) === bitrateSlider {
            c.mbps = (bitrateSlider.doubleValue * 2).rounded() / 2
        } else if (sender as? NSTextField) === bitrateField, let v = Double(bitrateField.stringValue) {
            c.mbps = min(400, max(0.5, v))
        }
        c.height = newHeight
        c.audioKbps = CustomExport.audio[max(0, audioPopup.indexOfSelectedItem)].kbps
        CustomExport.saved = c
        let r = ExportRecipe.custom(c)
        ExportRecipe.current = r
        select(r)
        update(sourceWidth: lastSize.0, sourceHeight: lastSize.1, length: lastSize.2)
        onRecipeChanged?(r)
    }

    /// What this recipe will write for the open edit: output size, length, and any platform limit.
    func update(sourceWidth: Int, sourceHeight: Int, length: Double?) {
        lastSize = (sourceWidth, sourceHeight, length)
        let r = ExportRecipe.current
        let (w, h) = r.outputSize(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        var text = "Output \(w)×\(h)"
        if sourceWidth > 0, h > sourceHeight { text += " (upscaled from \(sourceWidth)×\(sourceHeight))" }
        if let length { text += "\nLength \(TrimBar.format(length))" }
        output.stringValue = sourceWidth > 0 ? text : ""
        if let max = r.maxSeconds, let length, length > max {
            warning.stringValue = "⚠︎ Longer than \(r.name.components(separatedBy: " (").first ?? r.name)'s \(TrimBar.format(max)) limit."
            warning.isHidden = false
        } else {
            warning.stringValue = ""
            warning.isHidden = true
        }
    }

    @objc private func recipeChosen() {
        guard let id = popup.selectedItem?.representedObject as? String else { return }
        let r = ExportRecipe.find(id)
        ExportRecipe.current = r
        select(r)
        onRecipeChanged?(r)
    }

    @objc private func exportClicked() { onExport?() }
}

// VisualDesignPanel — the Visual Design tab's permanent right-side panel:
// White Balance (eyedropper, Color, Tint), Camera LUT, Creative LUT, Stabilize, Levels histogram, Color sliders, fade to black.

import Cocoa

final class VisualDesignPanel: NSVisualEffectView {
    static let width: CGFloat = RightPanel.width

    var onGradeChanged: ((ColorGrade.Settings) -> Void)?
    var onEyedropper: (() -> Void)?
    var onBypassChanged: ((Bool) -> Void)?
    var onFadeChanged: ((Bool) -> Void)?
    private let fadeToggle = NSButton(checkboxWithTitle: "Fade to black at end (+ 2 s black)", target: nil, action: nil)
    var onStabilizeAnalyze: (() -> Void)?
    var onStabilizeToggle: ((Bool) -> Void)?
    var onStabilizeSettings: ((Double, Double) -> Void)?     // smoothness 0…100, max crop %
    private let stabOn = NSButton(checkboxWithTitle: "On", target: nil, action: nil)
    private let stabAnalyze = NSButton(title: "Analyze", target: nil, action: nil)
    private let stabProgress = NSProgressIndicator()
    private let stabStatus = NSTextField(labelWithString: "Not analyzed")
    private let stabSmooth = ResetSlider()
    private let stabCrop = ResetSlider()
    private let stabSmoothLabel = NSTextField(labelWithString: "50")
    private let stabCropLabel = NSTextField(labelWithString: "10%")
    private let bypassButton = NSButton()
    enum LUTSlot: Int { case camera = 0, creative = 1 }
    /// nil = no LUT
    var onLUTSelected: ((LUTSlot, URL?) -> Void)?
    var onLoadLUT: ((LUTSlot) -> Void)?

    private let eyedropperButton = NSButton()

    // Visual Design groups (3.2): a coloured header naming the group being edited, with a menu to
    // move the selected clip to another group, start a new one, or rename this one.
    var onAssignGroup: ((String) -> Void)?
    var onNewGroup: (() -> Void)?
    var onRenameGroup: (() -> Void)?
    private let groupHeader = NSView()
    private let groupName = NSTextField(labelWithString: "A-roll")
    private let groupClip = NSTextField(labelWithString: "")
    private let groupMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    private let levels = LevelsView()
    private let lutPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let creativePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var sliders: [NSSlider] = []
    private var valueLabels: [NSTextField] = []
    private var nameLabels: [NSTextField] = []
    /// Controls whose effect is temporarily switched off (name shown in red).
    private var bypassedRows: Set<Int> = []
    private var selectedLUTs: [LUTSlot: URL] = [:]

    // Display order the user asked for.
    static let rows: [(title: String, help: String, key: WritableKeyPath<ColorGrade.Settings, Double>, min: Double)] = [
        ("Exposure", "Overall brightness (±1 stop)", \.exposure, -100),
        ("Saturation", "− toward black & white, + more vivid", \.saturation, -100),
        ("Vibrance", "Boosts muted colors more than strong ones — gentler on skin tones", \.vibrance, -100),
        ("Color", "Color temperature: − cooler (blue), + warmer (yellow)", \.temperature, -100),
        ("Tint", "− greener, + more magenta", \.tint, -100),
        ("Highlights", "− recover detail in bright areas like skies and clouds, + brighten them", \.highlights, -100),
        ("Shadows", "− deepen dark areas, + lift them", \.shadows, -100),
        ("Sharpen", "Crisper detail (0 = off). Small amounts go a long way.", \.sharpen, 0),
        ("Denoise", "Smooths grain from low-light footage (0 = off)", \.denoise, 0)
    ]

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: VisualDesignPanel.width, height: 400))
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)

        // ---- Levels histogram (top)
        let levelsTitle = sectionLabel("Levels")
        levelsTitle.toolTip = "Drag the bottom-left triangle in to set the black point, the bottom-right one to set the white point. Double-click a handle to reset it."
        levels.translatesAutoresizingMaskIntoConstraints = false
        levels.heightAnchor.constraint(equalToConstant: LevelsView.height).isActive = true
        levels.onChange = { [weak self] _, _, _ in
            guard let self else { return }
            self.onGradeChanged?(self.currentSettings)
        }

        // ---- Camera LUT (converts the camera's log/profile) and Creative LUT (a look on top)
        let lutTitle = sectionLabel("Camera LUT")
        let creativeTitle = sectionLabel("Creative LUT")
        for (popup, slot) in [(lutPopup, LUTSlot.camera), (creativePopup, LUTSlot.creative)] {
            popup.tag = slot.rawValue
            popup.controlSize = .regular
            popup.refusesFirstResponder = true
            popup.target = self
            popup.action = #selector(lutChosen(_:))
            popup.translatesAutoresizingMaskIntoConstraints = false
        }
        lutPopup.toolTip = "Converts your camera's log footage (e.g. Apple Log) to normal video. Applied right after white balance."
        creativePopup.toolTip = "A look or film style, applied after the Camera LUT."
        rebuildLUTMenu()

        // ---- Stabilize
        let stabTitle = sectionLabel("Stabilize")
        stabOn.target = self
        stabOn.action = #selector(stabToggled(_:))
        stabOn.isEnabled = false
        stabOn.refusesFirstResponder = true
        stabOn.toolTip = "Turn stabilization on or off (after analyzing). Export follows this."
        stabAnalyze.target = self
        stabAnalyze.action = #selector(stabAnalyzeClicked)
        stabAnalyze.bezelStyle = .rounded
        stabAnalyze.controlSize = .small
        stabAnalyze.refusesFirstResponder = true
        stabAnalyze.toolTip = "Scan the clip once to measure camera shake"
        let stabHeader = NSStackView(views: [stabTitle, NSView(), stabOn, stabAnalyze])
        stabHeader.orientation = .horizontal
        stabProgress.style = .bar
        stabProgress.isIndeterminate = false
        stabProgress.minValue = 0
        stabProgress.maxValue = 1
        stabProgress.controlSize = .small
        stabProgress.isHidden = true
        stabProgress.translatesAutoresizingMaskIntoConstraints = false
        stabStatus.font = .systemFont(ofSize: 11)
        stabStatus.textColor = .secondaryLabelColor
        let smoothRow = stabRow("Smoothness", stabSmooth, stabSmoothLabel, min: 0, max: 100, value: 50,
                                help: "Low = remove small jitters only · High = gimbal-smooth · Far right = Lock (tripod) · double-click for 50")
        let cropRow = stabRow("Max Crop", stabCrop, stabCropLabel, min: 2, max: 20, value: 10,
                              help: "Never zoom in more than this to hide the moving edges · double-click for 10%")

        // ---- Color
        let colorTitle = NSTextField(labelWithString: "Color")
        colorTitle.font = .boldSystemFont(ofSize: 15)
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetClicked))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.refusesFirstResponder = true
        reset.toolTip = "Sliders and Levels back to neutral (keeps the LUTs)"
        bypassButton.title = "Bypass"
        bypassButton.setButtonType(.pushOnPushOff)
        bypassButton.bezelStyle = .rounded
        bypassButton.controlSize = .small
        bypassButton.refusesFirstResponder = true
        bypassButton.toolTip = "Turns off white balance and the Color sliders (LUTs and Levels stay on). Export always includes them."
        bypassButton.target = self
        bypassButton.action = #selector(bypassClicked(_:))
        let colorHeader = NSStackView(views: [colorTitle, NSView(), bypassButton, reset])
        colorHeader.orientation = .horizontal

        eyedropperButton.title = "White Balance"
        eyedropperButton.image = NSImage(systemSymbolName: "eyedropper", accessibilityDescription: "White balance eyedropper")
        eyedropperButton.imagePosition = .imageLeading
        eyedropperButton.setButtonType(.pushOnPushOff)
        eyedropperButton.bezelStyle = .rounded
        eyedropperButton.controlSize = .large
        eyedropperButton.refusesFirstResponder = true
        eyedropperButton.toolTip = "Click, then click something in the video that should be white or gray"
        eyedropperButton.target = self
        eyedropperButton.action = #selector(eyedropperClicked)
        eyedropperButton.translatesAutoresizingMaskIntoConstraints = false

        var sliderRows: [NSStackView] = []
        for (i, row) in Self.rows.enumerated() {
            let label = ClickableLabel(labelWithString: row.title)
            label.font = .systemFont(ofSize: 12)
            label.toolTip = row.help + " · click the name to bypass just this control"
            label.widthAnchor.constraint(equalToConstant: 72).isActive = true
            label.onClick = { [weak self] in self?.toggleRowBypass(i) }
            nameLabels.append(label)
            let slider = ResetSlider(value: 0, minValue: row.min, maxValue: 100, target: self, action: #selector(sliderMoved(_:)))
            slider.tag = i
            slider.isContinuous = true
            slider.controlSize = .small
            slider.refusesFirstResponder = true
            slider.toolTip = row.help + " · double-click to reset"
            let value = NSTextField(labelWithString: "0")
            value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            value.alignment = .right
            value.widthAnchor.constraint(equalToConstant: 34).isActive = true
            sliders.append(slider)
            valueLabels.append(value)
            let line = NSStackView(views: [label, slider, value])
            line.orientation = .horizontal
            line.spacing = 6
            sliderRows.append(line)
        }

        // ---- Fade to black (after Shadows)
        fadeToggle.target = self
        fadeToggle.action = #selector(fadeToggled(_:))
        fadeToggle.refusesFirstResponder = true
        fadeToggle.controlSize = .regular
        fadeToggle.toolTip = "Fades the picture to black and the sound to silence over the last half second (of the trimmed video), then adds 2 seconds of black and silence to the export."

        // White balance sits at the very top, because it's applied before the LUT.
        let wbTitle = NSTextField(labelWithString: "White Balance")
        wbTitle.font = .boldSystemFont(ofSize: 15)
        let isWB: (Int) -> Bool = { i in
            let key = Self.rows[i].key
            return key == \ColorGrade.Settings.temperature || key == \ColorGrade.Settings.tint
        }
        let wbRows = sliderRows.indices.filter(isWB).map { sliderRows[$0] }
        let otherRows = sliderRows.indices.filter { !isWB($0) }.map { sliderRows[$0] }

        let drawerTitle = NSTextField(labelWithString: "Visual Design")
        drawerTitle.font = .boldSystemFont(ofSize: 15)
        let drawerSubtitle = NSTextField(labelWithString: "Picture flows top to bottom")
        drawerSubtitle.font = .systemFont(ofSize: 11)
        drawerSubtitle.textColor = .secondaryLabelColor
        buildGroupHeader()
        let views: [NSView] = [groupHeader, drawerTitle, drawerSubtitle, wbTitle, eyedropperButton] + wbRows
            + [lutTitle, lutPopup, creativeTitle, creativePopup, stabHeader, stabProgress, smoothRow, cropRow, stabStatus,
               levelsTitle, levels, colorHeader]
            + otherRows + [fadeToggle]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.setCustomSpacing(16, after: drawerSubtitle)
        stack.spacing = 8
        stack.setCustomSpacing(10, after: wbTitle)
        stack.setCustomSpacing(12, after: eyedropperButton)
        if let lastWB = wbRows.last { stack.setCustomSpacing(20, after: lastWB) }
        stack.setCustomSpacing(6, after: lutTitle)
        stack.setCustomSpacing(12, after: lutPopup)
        stack.setCustomSpacing(6, after: creativeTitle)
        stack.setCustomSpacing(16, after: creativePopup)
        stack.setCustomSpacing(6, after: stabHeader)
        stack.setCustomSpacing(4, after: cropRow)
        stack.setCustomSpacing(18, after: stabStatus)
        stack.setCustomSpacing(6, after: levelsTitle)
        stack.setCustomSpacing(20, after: levels)
        stack.setCustomSpacing(12, after: colorHeader)
        if let lastRow = otherRows.last { stack.setCustomSpacing(14, after: lastRow) }
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Scrolls when the window is too short to show everything.
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        addSubview(scroll)

        var constraints = [
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16),
            levels.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stabHeader.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stabProgress.widthAnchor.constraint(equalTo: stack.widthAnchor),
            smoothRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            cropRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            lutPopup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            creativePopup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            colorHeader.widthAnchor.constraint(equalTo: stack.widthAnchor),
            eyedropperButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            groupHeader.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ]
        constraints += sliderRows.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) }
        NSLayoutConstraint.activate(constraints)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func stabRow(_ title: String, _ slider: ResetSlider, _ value: NSTextField,
                         min: Double, max: Double, value initial: Double, help: String) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.toolTip = help
        label.widthAnchor.constraint(equalToConstant: 72).isActive = true
        slider.minValue = min
        slider.maxValue = max
        slider.doubleValue = initial
        slider.resetValue = initial
        slider.isContinuous = true
        slider.controlSize = .small
        slider.refusesFirstResponder = true
        slider.toolTip = help
        slider.target = self
        slider.action = #selector(stabSettingsChanged(_:))
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.alignment = .right
        value.widthAnchor.constraint(equalToConstant: 34).isActive = true
        let line = NSStackView(views: [label, slider, value])
        line.orientation = .horizontal
        line.spacing = 6
        line.translatesAutoresizingMaskIntoConstraints = false
        return line
    }

    // MARK: Stabilize

    @objc private func stabAnalyzeClicked() { onStabilizeAnalyze?() }

    @objc private func stabToggled(_ sender: NSButton) {
        onStabilizeToggle?(sender.state == .on)
    }

    @objc private func stabSettingsChanged(_ sender: NSSlider) {
        let smooth = stabSmooth.doubleValue.rounded()
        let crop = stabCrop.doubleValue.rounded()
        stabSmoothLabel.stringValue = smooth >= 99.5 ? "Lock" : "\(Int(smooth))"
        stabCropLabel.stringValue = "\(Int(crop))%"
        onStabilizeSettings?(smooth, crop)
    }

    /// Shows analysis progress (nil = not analyzing).
    func setStabilizeProgress(_ progress: Double?) {
        stabProgress.isHidden = progress == nil
        stabAnalyze.isEnabled = progress == nil
        if let progress {
            stabProgress.doubleValue = progress
            stabStatus.stringValue = "Analyzing… \(Int(progress * 100))%"
        }
    }

    /// After analysis (or reset): analyzed?, on?, current zoom.
    func setStabilizeState(analyzed: Bool, enabled: Bool, zoomPercent: Double?) {
        stabOn.isEnabled = analyzed
        stabOn.state = enabled ? .on : .off
        stabAnalyze.title = analyzed ? "Re-analyze" : "Analyze"
        if !analyzed {
            stabStatus.stringValue = "Not analyzed — click Analyze"
        } else if !enabled {
            stabStatus.stringValue = "Off"
        } else if let zoomPercent {
            stabStatus.stringValue = String(format: "On · zoom %.1f%%", zoomPercent)
        }
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        return label
    }

    // MARK: LUT menu

    /// Both menus: None · your LUTs · Load LUT… · Show LUT Folder (one shared LUT library).
    func rebuildLUTMenu(select url: URL? = nil, slot: LUTSlot = .camera) {
        if let url { selectedLUTs[slot] = url }
        buildMenu(for: lutPopup, selected: selectedLUTs[.camera])
        buildMenu(for: creativePopup, selected: selectedLUTs[.creative])
    }

    private func buildMenu(for popup: NSPopUpButton, selected: URL?) {
        let menu = NSMenu()
        let none = NSMenuItem(title: "None", action: nil, keyEquivalent: "")
        menu.addItem(none)
        let files = CubeLUT.libraryFiles()
        if !files.isEmpty { menu.addItem(.separator()) }
        var selectedItem: NSMenuItem = none
        for file in files {
            let item = NSMenuItem(title: file.deletingPathExtension().lastPathComponent, action: nil, keyEquivalent: "")
            item.representedObject = file
            menu.addItem(item)
            if file.standardizedFileURL == selected?.standardizedFileURL { selectedItem = item }
        }
        menu.addItem(.separator())
        let load = NSMenuItem(title: "Load LUT…", action: nil, keyEquivalent: "")
        load.tag = 1
        menu.addItem(load)
        let reveal = NSMenuItem(title: "Show LUT Folder", action: nil, keyEquivalent: "")
        reveal.tag = 2
        menu.addItem(reveal)
        popup.menu = menu
        popup.select(selectedItem)
    }

    func clearLUTSelection(_ slot: LUTSlot) {
        selectedLUTs[slot] = nil
        rebuildLUTMenu()
    }

    @objc private func lutChosen(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem, let slot = LUTSlot(rawValue: sender.tag) else { return }
        switch item.tag {
        case 1:
            rebuildLUTMenu()            // put the selection back while the file picker is open
            onLoadLUT?(slot)
        case 2:
            rebuildLUTMenu()
            NSWorkspace.shared.activateFileViewerSelecting([CubeLUT.libraryFolder])
        default:
            selectedLUTs[slot] = item.representedObject as? URL
            onLUTSelected?(slot, selectedLUTs[slot])
        }
    }

    // MARK: Group header (3.2)

    private func buildGroupHeader() {
        groupHeader.wantsLayer = true
        groupHeader.layer?.cornerRadius = 7
        groupHeader.translatesAutoresizingMaskIntoConstraints = false
        groupName.font = .systemFont(ofSize: 14, weight: .heavy)
        groupName.textColor = .black
        groupName.lineBreakMode = .byTruncatingTail
        groupClip.font = .systemFont(ofSize: 10.5, weight: .medium)
        groupClip.textColor = NSColor.black.withAlphaComponent(0.7)
        groupClip.lineBreakMode = .byTruncatingTail
        groupMenu.bezelStyle = .inline
        groupMenu.isBordered = false
        groupMenu.controlSize = .small
        groupMenu.addItem(withTitle: "Group")
        groupMenu.toolTip = "Move this clip to another Visual Design group, start a new group, or rename this one"
        for v in [groupName, groupClip, groupMenu] {
            v.translatesAutoresizingMaskIntoConstraints = false
            groupHeader.addSubview(v)
        }
        NSLayoutConstraint.activate([
            groupHeader.heightAnchor.constraint(equalToConstant: 46),
            groupName.leadingAnchor.constraint(equalTo: groupHeader.leadingAnchor, constant: 10),
            groupName.topAnchor.constraint(equalTo: groupHeader.topAnchor, constant: 6),
            groupName.trailingAnchor.constraint(lessThanOrEqualTo: groupMenu.leadingAnchor, constant: -6),
            groupClip.leadingAnchor.constraint(equalTo: groupName.leadingAnchor),
            groupClip.topAnchor.constraint(equalTo: groupName.bottomAnchor, constant: 1),
            groupClip.trailingAnchor.constraint(equalTo: groupHeader.trailingAnchor, constant: -8),
            groupMenu.trailingAnchor.constraint(equalTo: groupHeader.trailingAnchor, constant: -6),
            groupMenu.topAnchor.constraint(equalTo: groupHeader.topAnchor, constant: 5)
        ])
    }

    /// Shows which group is being edited (its colour and name), which clip was picked, and the
    /// groups this clip can be moved to.
    func setGroup(name: String, color: NSColor, clip: String, groups: [(id: String, name: String, color: NSColor)], current: String) {
        groupHeader.layer?.backgroundColor = color.cgColor
        groupName.stringValue = name
        groupClip.stringValue = clip.isEmpty ? "Click a clip on the timeline to grade it" : clip
        let menu = NSMenu()
        menu.addItem(withTitle: "Group", action: nil, keyEquivalent: "")   // pull-down title
        let header = NSMenuItem(title: "Move this clip to", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for g in groups {
            let item = NSMenuItem(title: g.name, action: #selector(groupChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = g.id
            item.state = g.id == current ? .on : .off
            let swatch = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
                g.color.setFill(); NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill(); return true }
            item.image = swatch
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let new = NSMenuItem(title: "New Group for This Clip", action: #selector(newGroupChosen), keyEquivalent: "")
        new.target = self
        menu.addItem(new)
        let rename = NSMenuItem(title: "Rename “\(name)”…", action: #selector(renameChosen), keyEquivalent: "")
        rename.target = self
        menu.addItem(rename)
        groupMenu.menu = menu
        groupMenu.isEnabled = !clip.isEmpty
    }

    @objc private func groupChosen(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { onAssignGroup?(id) }
    }
    @objc private func newGroupChosen() { onNewGroup?() }
    @objc private func renameChosen() { onRenameGroup?() }

    // MARK: Updating from outside


    func setSettings(_ s: ColorGrade.Settings) {
        for (i, row) in Self.rows.enumerated() {
            // A control that's being given a new value (eyedropper, Reset) is no longer bypassed.
            if sliders[i].doubleValue != s[keyPath: row.key], bypassedRows.remove(i) != nil {
                updateRowBypassLook(i)
            }
            sliders[i].doubleValue = s[keyPath: row.key]
            valueLabels[i].stringValue = Self.label(s[keyPath: row.key])
        }
        levels.setPoints(black: s.blackPoint, white: s.whitePoint)
    }

    /// Eyedropper result: set Color and Tint, turn their bypass off, and apply.
    func applyWhiteBalance(temperature: Double, tint: Double) {
        for (i, row) in Self.rows.enumerated() {
            let value: Double
            if row.key == \ColorGrade.Settings.temperature { value = temperature }
            else if row.key == \ColorGrade.Settings.tint { value = tint }
            else { continue }
            sliders[i].doubleValue = value
            valueLabels[i].stringValue = Self.label(value)
            if bypassedRows.remove(i) != nil { updateRowBypassLook(i) }
        }
        onGradeChanged?(currentSettings)
    }

    /// Red/green/blue histogram of the current frame (768 raw counts).
    func setHistogram(_ bins: [Float]) {
        levels.setHistogram(bins)
    }

    func setEyedropperActive(_ active: Bool) {
        eyedropperButton.state = active ? .on : .off
    }

    var currentSettings: ColorGrade.Settings {
        var s = ColorGrade.Settings()
        for (i, row) in Self.rows.enumerated() where !bypassedRows.contains(i) {
            s[keyPath: row.key] = sliders[i].doubleValue.rounded()
        }
        s.blackPoint = levels.blackPoint
        s.whitePoint = levels.whitePoint
        return s
    }

    // MARK: Actions

    /// Click a control's name: switch that one adjustment off/on, keeping the slider where it is.
    private func toggleRowBypass(_ i: Int) {
        if bypassedRows.contains(i) { bypassedRows.remove(i) } else { bypassedRows.insert(i) }
        updateRowBypassLook(i)
        onGradeChanged?(currentSettings)
    }

    private func updateRowBypassLook(_ i: Int) {
        let off = bypassedRows.contains(i)
        nameLabels[i].textColor = off ? .systemRed : .labelColor
        valueLabels[i].textColor = off ? .systemRed : .labelColor
    }

    @objc private func sliderMoved(_ slider: NSSlider) {
        // Moving a bypassed control turns it back on.
        if bypassedRows.remove(slider.tag) != nil { updateRowBypassLook(slider.tag) }
        // Snap back to 0 when you're close, so "untouched" is easy to hit.
        if abs(slider.doubleValue) < 2 { slider.doubleValue = 0 }
        valueLabels[slider.tag].stringValue = Self.label(slider.doubleValue)
        onGradeChanged?(currentSettings)
    }

    @objc private func resetClicked() {
        bypassedRows.removeAll()
        for i in nameLabels.indices { updateRowBypassLook(i) }
        setSettings(ColorGrade.Settings())
        onGradeChanged?(currentSettings)
    }

    @objc private func eyedropperClicked() { onEyedropper?() }

    @objc private func fadeToggled(_ sender: NSButton) {
        onFadeChanged?(sender.state == .on)
    }

    @objc private func bypassClicked(_ sender: NSButton) {
        let on = sender.state == .on
        sender.contentTintColor = on ? .systemOrange : nil
        sender.title = on ? "Bypassed" : "Bypass"
        onBypassChanged?(on)
    }

    private static func label(_ v: Double) -> String {
        let n = Int(v.rounded())
        return n > 0 ? "+\(n)" : "\(n)"
    }
}

/// Slider that jumps back to its reset value (normally 0) when double-clicked.
final class ResetSlider: NSSlider {
    /// Value a double-click returns to (0 unless set).
    var resetValue: Double = 0

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            doubleValue = resetValue
            sendAction(action, to: target)
            return
        }
        super.mouseDown(with: event)
    }
}

/// A text label that reports clicks (used for click-to-bypass on control names).
final class ClickableLabel: NSTextField {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// MARK: - Saving / restoring (projects)

extension VisualDesignPanel {
    struct Snapshot: Codable, Equatable {
        var sliders: [String: Double]      // by control name ("Exposure", "Color", …)
        var bypassed: [String]             // control names switched off (red)
        var blackPoint: Double
        var whitePoint: Double
        var cameraLUT: String?             // LUT file names
        var creativeLUT: String?
        var stabilize: Bool
        var smoothness: Double
        var maxCrop: Double
        var fade: Bool
        var colorBypass: Bool
    }

    var snapshot: Snapshot {
        var values: [String: Double] = [:]
        var off: [String] = []
        for (i, row) in Self.rows.enumerated() {
            values[row.title] = sliders[i].doubleValue.rounded()
            if bypassedRows.contains(i) { off.append(row.title) }
        }
        return Snapshot(sliders: values, bypassed: off,
                        blackPoint: levels.blackPoint, whitePoint: levels.whitePoint,
                        cameraLUT: selectedLUTs[.camera]?.lastPathComponent,
                        creativeLUT: selectedLUTs[.creative]?.lastPathComponent,
                        stabilize: stabOn.state == .on,
                        smoothness: stabSmooth.doubleValue.rounded(), maxCrop: stabCrop.doubleValue.rounded(),
                        fade: fadeToggle.state == .on,
                        colorBypass: bypassButton.state == .on)
    }

    /// A group's look: what a Visual Design group keeps (3.2). Stabilize and Fade aren't in it.
    struct Look: Codable, Equatable {
        var sliders: [String: Double] = [:]
        var bypassed: [String] = []
        var blackPoint: Double = 0
        var whitePoint: Double = 1
        var cameraLUT: String? = nil
        var creativeLUT: String? = nil
    }

    var look: Look {
        let s = snapshot
        return Look(sliders: s.sliders, bypassed: s.bypassed, blackPoint: s.blackPoint, whitePoint: s.whitePoint,
                    cameraLUT: s.cameraLUT, creativeLUT: s.creativeLUT)
    }

    /// Shows a group's look and applies it (fires onGradeChanged and onLUTSelected for each slot).
    func applyLook(_ l: Look, lutURL: (String) -> URL?) {
        var settings = ColorGrade.Settings()
        for row in Self.rows { settings[keyPath: row.key] = l.sliders[row.title] ?? 0 }
        settings.blackPoint = l.blackPoint
        settings.whitePoint = l.whitePoint
        bypassedRows = []
        setSettings(settings)
        bypassedRows = Set(Self.rows.indices.filter { l.bypassed.contains(Self.rows[$0].title) })
        for i in nameLabels.indices { updateRowBypassLook(i) }
        for (slot, name) in [(LUTSlot.camera, l.cameraLUT), (LUTSlot.creative, l.creativeLUT)] {
            let url = name.flatMap(lutURL)
            selectedLUTs[slot] = url
            onLUTSelected?(slot, url)
        }
        rebuildLUTMenu()
        onGradeChanged?(currentSettings)
    }

    /// Writes a look into a full snapshot (keeps the snapshot's Stabilize, Fade and Bypass).
    static func snapshot(_ base: Snapshot, with l: Look) -> Snapshot {
        var s = base
        s.sliders = l.sliders; s.bypassed = l.bypassed
        s.blackPoint = l.blackPoint; s.whitePoint = l.whitePoint
        s.cameraLUT = l.cameraLUT; s.creativeLUT = l.creativeLUT
        return s
    }

    /// The LUT files currently chosen (so the project can keep copies).
    var selectedLUTFiles: [URL] { Array(selectedLUTs.values) }

    /// Puts every control back and applies it. `lutURL` finds a LUT file by name.
    /// Stabilization analysis itself isn't stored — the window re-runs it when `stabilize` is on.
    func restore(_ s: Snapshot, lutURL: (String) -> URL?) {
        // Color sliders + Levels
        var settings = ColorGrade.Settings()
        for row in Self.rows { settings[keyPath: row.key] = s.sliders[row.title] ?? 0 }
        settings.blackPoint = s.blackPoint
        settings.whitePoint = s.whitePoint
        setSettings(settings)
        bypassedRows = Set(Self.rows.indices.filter { s.bypassed.contains(Self.rows[$0].title) })
        for i in nameLabels.indices { updateRowBypassLook(i) }
        onGradeChanged?(currentSettings)

        // LUTs
        for (slot, name) in [(LUTSlot.camera, s.cameraLUT), (LUTSlot.creative, s.creativeLUT)] {
            let url = name.flatMap(lutURL)
            selectedLUTs[slot] = url
            onLUTSelected?(slot, url)
        }
        rebuildLUTMenu()

        // Stabilize settings (the On switch follows once the clip is re-analyzed)
        stabSmooth.doubleValue = s.smoothness
        stabCrop.doubleValue = s.maxCrop
        stabSettingsChanged(stabSmooth)

        // Fade + Color bypass
        fadeToggle.state = s.fade ? .on : .off
        fadeToggled(fadeToggle)
        bypassButton.state = s.colorBypass ? .on : .off
        bypassClicked(bypassButton)
    }
}

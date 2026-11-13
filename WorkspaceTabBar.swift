// WorkspaceTabBar — the DaVinci-style row of step tabs docked above the timeline (3.0.0).
// Selecting a tab swaps the page shown in RightPanel; the timeline itself never hides.

import Cocoa

enum WorkspaceTab: Int, CaseIterable {
    case assets, visualDesign, soundDesign, cuts, zooms, broll, graphics, export

    var title: String {
        switch self {
        case .assets: return "Assets"
        case .visualDesign: return "Visual Design"
        case .soundDesign: return "Sound Design"
        case .cuts: return "Cuts"
        case .zooms: return "Zooms"
        case .broll: return "B-roll"
        case .graphics: return "Graphics"
        case .export: return "Export"
        }
    }

    /// Whether this tab has a real right-panel page yet; the rest show the placeholder
    /// until they're built out in a later point release.
    var isBuilt: Bool {
        switch self {
        case .assets, .visualDesign, .soundDesign, .cuts, .zooms, .broll, .graphics, .export: return true
        }
    }

    /// How this step works today, shown on the placeholder page for a not-yet-built tab.
    var placeholderNote: String {
        switch self {
        case .cuts: return "Press X to mark a cut, Delete to remove the selected one, or use the Automation menu."
        case .zooms: return "Press Z to insert a punch-in at the playhead, or drag/right-click a marker on the timeline."
        case .broll: return "Press B to add a clip at the playhead, drag files onto the timeline, or use the Automation menu."
        case .graphics: return "Ask Claude to place motion graphics plates through the MCP tools."
        case .export: return "Press ⌘Y, or use File › Export for YouTube…"
        case .assets, .visualDesign, .soundDesign: return ""
        }
    }
}

/// A fixed row of step tabs. Purely presentational — `onSelect` reports taps; the window
/// decides what happens (swap the right panel, switch the timeline's display mode, etc.).
final class WorkspaceTabBar: NSView {
    static let height: CGFloat = 28

    var onSelect: ((WorkspaceTab) -> Void)?
    private var buttons: [WorkspaceTab: NSButton] = [:]
    private var selected: WorkspaceTab = .visualDesign

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        for tab in WorkspaceTab.allCases {
            let button = NSButton(title: tab.title, target: self, action: #selector(tapped(_:)))
            button.tag = tab.rawValue
            button.isBordered = false
            button.refusesFirstResponder = true
            button.alignment = .center
            button.wantsLayer = true
            stack.addArrangedSubview(button)
            buttons[tab] = button
        }
        updateLook()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped(_ sender: NSButton) {
        guard let tab = WorkspaceTab(rawValue: sender.tag) else { return }
        selected = tab
        updateLook()
        onSelect?(tab)
    }

    func select(_ tab: WorkspaceTab) {
        selected = tab
        updateLook()
    }

    /// Selected tab: bright white, semibold, a faint highlight behind it. Everything else: dimmed
    /// white text (still readable, not just the highlighted tab) so a new user can see every step.
    private func updateLook() {
        for (tab, button) in buttons {
            let isSelected = tab == selected
            button.attributedTitle = NSAttributedString(string: tab.title, attributes: [
                .foregroundColor: isSelected ? NSColor.white : NSColor.white.withAlphaComponent(0.55),
                .font: NSFont.systemFont(ofSize: 11, weight: isSelected ? .semibold : .medium)
            ])
            button.layer?.backgroundColor = isSelected
                ? NSColor.white.withAlphaComponent(0.14).cgColor
                : NSColor.clear.cgColor
            button.layer?.cornerRadius = 4
        }
    }
}

/// Shown in RightPanel for a tab that doesn't have a built panel yet.
final class PlaceholderPanel: NSVisualEffectView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: RightPanel.width, height: 400))
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)

        titleLabel.font = .boldSystemFont(ofSize: 15)
        noteLabel.font = .systemFont(ofSize: 12)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.maximumNumberOfLines = 0

        let comingSoon = NSTextField(labelWithString: "A full panel is coming in a later version.")
        comingSoon.font = .systemFont(ofSize: 11)
        comingSoon.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [titleLabel, noteLabel, comingSoon])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(16, after: titleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            noteLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(for tab: WorkspaceTab) {
        titleLabel.stringValue = tab.title
        noteLabel.stringValue = tab.placeholderNote
    }
}

// RightPanel — the permanent sidebar on the window's right edge (3.0.0). Replaces the
// old sliding Sound Design / Visual Design drawers: no animation, no hover handle, always
// visible. Holds one "page" view per workspace tab; only the selected one is shown.

import Cocoa

final class RightPanel: NSView {
    static let width: CGFloat = 280

    private var pages: [WorkspaceTab: NSView] = [:]
    private let placeholder = PlaceholderPanel()
    private var current: WorkspaceTab = .visualDesign

    override init(frame: NSRect) {
        super.init(frame: frame)
        placeholder.frame = bounds
        placeholder.autoresizingMask = [.width, .height]
        placeholder.isHidden = true
        addSubview(placeholder)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Registers the page shown for a built tab. Call once per tab during window setup.
    func setPage(_ view: NSView, for tab: WorkspaceTab) {
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        view.isHidden = true
        addSubview(view, positioned: .below, relativeTo: placeholder)
        pages[tab] = view
    }

    func show(_ tab: WorkspaceTab) {
        pages[current]?.isHidden = true
        placeholder.isHidden = true
        current = tab
        if let page = pages[tab] {
            page.isHidden = false
        } else {
            placeholder.configure(for: tab)
            placeholder.isHidden = false
        }
    }
}

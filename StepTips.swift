// StepTips — a friendly explainer card for each step tab (3.4.0). It pops up over the video the
// first time you open a step in a project window. "Got it" closes it; ticking "I don't need
// training wheels" turns every card off for good (Help › Show Step Tips Again brings them back).
// The card is an overlay, not a sheet, so it never blocks the window or Claude's MCP tools.

import Cocoa

extension WorkspaceTab {
    /// The card's title and text for this step.
    var tip: (title: String, body: String) {
        switch self {
        case .assets:
            return ("This is Assets: your pile of raw takes 🎬",
                    "Drag your clips in (or click Import…). They line up oldest to newest, because that's the order you shot them.\n\n" +
                    "Click a clip to watch it and drag its in/out handles to trim the dead air off each end. Click a clip's green dot to leave it out. " +
                    "Right-click clips to put them in a Visual Design group (clips shot the same way share one).\n\n" +
                    "Happy with the lineup? Hit Build A-roll and they become one timeline.")
        case .visualDesign:
            return ("This is Visual Design: make it look good 🎨",
                    "Click a clip on the timeline to pick its group, then work the panel top to bottom:\n\n" +
                    "• White Balance: eyedrop something white or grey and the colour cast is gone.\n" +
                    "• Camera LUT, then Creative LUT: undo your camera's log look, then add some style.\n" +
                    "• Stabilize: smooths out a wobbly shot (Analyze first).\n" +
                    "• Levels and Color: set your blacks and whites, then season to taste.\n\n" +
                    "Every clip in the same group gets the same look. Grade once, done.")
        case .soundDesign:
            return ("This is Sound Design: make it sound good 🎧",
                    "Your audio flows top to bottom, one effect into the next:\n\n" +
                    "• Voice Isolation scrubs out the room. High Pass cuts the rumble.\n" +
                    "• Gate hushes the gaps. Compressor evens out loud and soft.\n" +
                    "• De-esser tames sharp S sounds. Limiter stops anything from clipping.\n\n" +
                    "Watch the meters at the bottom: YouTube likes about −14 LUFS. Trust your ears (headphones on!).")
        case .cuts:
            return ("This is Cuts: the ums, ahs and oopsies go here ✂️",
                    "Every cut shows on the timeline and in the list, in seconds of your original recording.\n\n" +
                    "Press X to mark a cut at the playhead, Delete removes the selected one. Or let Claude do the heavy lifting: " +
                    "it cuts the pauses first, then the false starts and retakes.\n\n" +
                    "Play it back. If a cut feels choppy, nudge it or delete it.")
        case .zooms:
            return ("This is Zooms: punch in for emphasis 🔍",
                    "A punch-in is a quick zoom on a word that matters. It makes a single camera feel like two.\n\n" +
                    "Press Z to punch in at the playhead (it goes back to normal 5 s later). Drag its end marker, " +
                    "or edit Out in the list, to hold it longer.\n\n" +
                    "Pro tip: less is more. One punch every 20–30 seconds keeps it fresh.")
        case .broll:
            return ("This is B-roll: show, don't just tell 🎞️",
                    "B-roll sits on V2, above your talking head. Press B to add a clip at the playhead, or drag files onto the timeline. " +
                    "Claude can also find stock footage for you, one spot at a time, and you pick the winner.\n\n" +
                    "Select a shot to zoom and pan it, or shrink it into a picture-in-picture box you can drag around the video.")
        case .graphics:
            return ("This is Graphics: titles, callouts and a little sparkle ✨",
                    "Motion graphics plates live on V3, on top of everything. Claude proposes them from your transcript: " +
                    "a name plate early on, bullets and big numbers for your key points.\n\n" +
                    "Select a plate to move or resize it right on the video. Keep them off your face (unless it's for the laugh).")
        case .export:
            return ("This is Export: ship it! 🚀",
                    "Pick a recipe (YouTube is the usual pick) or roll your own with Custom…, then hit Export….\n\n" +
                    "⌘Y exports with this recipe from anywhere. Leave \"Normalize loudness to −14 LUFS\" on and your video " +
                    "will sit right next to everyone else's on YouTube.")
        }
    }
}

/// The card itself. Purely presentational: the window decides when to show it.
final class StepTipCard: NSVisualEffectView {
    static let width: CGFloat = 460
    static let turnedOffKey = "StepTipsOff"
    static var turnedOff: Bool {
        get { UserDefaults.standard.bool(forKey: turnedOffKey) }
        set { UserDefaults.standard.set(newValue, forKey: turnedOffKey) }
    }
    /// Posted when someone ticks the box, so every open window drops its card.
    static let turnedOffNotification = Notification.Name("StepTipsTurnedOff")

    var onClose: (() -> Void)?
    private let checkbox = NSButton(checkboxWithTitle: "I don't need training wheels", target: nil, action: nil)

    init(tab: WorkspaceTab) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        let step = WorkspaceTab.allCases.firstIndex(of: tab).map { $0 + 1 } ?? 1
        let kicker = NSTextField(labelWithString: "STEP \(step) OF \(WorkspaceTab.allCases.count)")
        kicker.font = .systemFont(ofSize: 10, weight: .semibold)
        kicker.textColor = .controlAccentColor

        let title = NSTextField(wrappingLabelWithString: tab.tip.title)
        title.font = .boldSystemFont(ofSize: 17)
        title.textColor = .white

        let body = NSTextField(wrappingLabelWithString: tab.tip.body)
        body.font = .systemFont(ofSize: 13)
        body.textColor = NSColor.white.withAlphaComponent(0.85)
        body.isSelectable = false

        checkbox.target = self
        checkbox.font = .systemFont(ofSize: 12)
        checkbox.toolTip = "Turns these cards off for every step. Help › Show Step Tips Again brings them back."
        let ok = NSButton(title: "Got it", target: self, action: #selector(okClicked))
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        let buttons = NSStackView(views: [checkbox, NSView(), ok])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [kicker, title, body, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(4, after: kicker)
        stack.setCustomSpacing(18, after: body)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let inner = Self.width - 44
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            title.widthAnchor.constraint(equalToConstant: inner),
            body.widthAnchor.constraint(equalToConstant: inner),
            buttons.widthAnchor.constraint(equalToConstant: inner)
        ])
        // Size to fit the text: wrapping labels need their width before they can report their height.
        title.preferredMaxLayoutWidth = inner
        body.preferredMaxLayoutWidth = inner
        layoutSubtreeIfNeeded()
        let fitted = stack.fittingSize
        setFrameSize(NSSize(width: Self.width, height: fitted.height + 38))
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func okClicked() {
        if checkbox.state == .on {
            Self.turnedOff = true
            NotificationCenter.default.post(name: Self.turnedOffNotification, object: nil)
        }
        onClose?()
    }

    // Clicks on the card stay on the card (don't reach the video underneath).
    override func mouseDown(with event: NSEvent) {}
}

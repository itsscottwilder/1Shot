// TransportBar — playback controls docked above the step tabs (3.3.3), the same height as the
// tab bar: go to start, frame back, play/pause, frame forward, go to end, and loop on/off.
// Purely presentational: the window wires each button and keeps the play and loop states current.

import Cocoa

final class TransportBar: NSView {
    static let height: CGFloat = WorkspaceTabBar.height

    var onGoToStart: (() -> Void)?
    var onStepBack: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onStepForward: (() -> Void)?
    var onGoToEnd: (() -> Void)?
    var onToggleLoop: (() -> Void)?

    private let startButton: NSButton
    private let backButton: NSButton
    private let playButton: NSButton
    private let forwardButton: NSButton
    private let endButton: NSButton
    private let loopButton: NSButton
    private var playing = false
    private var looping = false

    override init(frame: NSRect) {
        startButton = Self.button("backward.end.fill", "Go to start (Home / fn ←)")
        backButton = Self.button("backward.frame.fill", "Back one frame (←; ⇧← one second)")
        playButton = Self.button("play.fill", "Play (Space)", size: 15)
        forwardButton = Self.button("forward.frame.fill", "Forward one frame (→; ⇧→ one second)")
        endButton = Self.button("forward.end.fill", "Go to end (End / fn →)")
        loopButton = Self.button("repeat", "Loop playback (⌥⌘L)")
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor

        for (b, action) in [(startButton, #selector(startClicked)), (backButton, #selector(backClicked)),
                            (playButton, #selector(playClicked)), (forwardButton, #selector(forwardClicked)),
                            (endButton, #selector(endClicked)), (loopButton, #selector(loopClicked))] {
            b.target = self
            b.action = action
        }

        let controls = NSStackView(views: [startButton, backButton, playButton, forwardButton, endButton])
        controls.orientation = .horizontal
        controls.spacing = 14
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)
        loopButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(loopButton)
        NSLayoutConstraint.activate([
            controls.centerXAnchor.constraint(equalTo: centerXAnchor),
            controls.centerYAnchor.constraint(equalTo: centerYAnchor),
            loopButton.leadingAnchor.constraint(equalTo: controls.trailingAnchor, constant: 26),
            loopButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setLoop(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    private static func button(_ symbol: String, _ tip: String, size: CGFloat = 12) -> NSButton {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(config)
            ?? NSImage()
        let b = NSButton(image: image, target: nil, action: nil)
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        b.toolTip = tip
        b.setAccessibilityLabel(tip)
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    /// Shows pause while playing, play while paused.
    func setPlaying(_ on: Bool) {
        guard on != playing else { return }
        playing = on
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let tip = on ? "Pause (Space)" : "Play (Space)"
        playButton.image = NSImage(systemSymbolName: on ? "pause.fill" : "play.fill",
                                   accessibilityDescription: tip)?.withSymbolConfiguration(config)
        playButton.toolTip = tip
        playButton.setAccessibilityLabel(tip)
    }

    /// Lit in the accent colour while looping is on.
    func setLoop(_ on: Bool) {
        looping = on
        loopButton.contentTintColor = on ? .controlAccentColor : NSColor.white.withAlphaComponent(0.4)
        let tip = on ? "Loop playback is on (⌥⌘L)" : "Loop playback is off (⌥⌘L)"
        loopButton.toolTip = tip
        loopButton.setAccessibilityLabel(tip)
        loopButton.setAccessibilityValue(on ? "on" : "off")
    }

    /// Greys out the buttons while there's nothing to play.
    func setEnabled(_ on: Bool) {
        for b in [startButton, backButton, playButton, forwardButton, endButton] { b.isEnabled = on }
    }

    @objc private func startClicked() { onGoToStart?() }
    @objc private func backClicked() { onStepBack?() }
    @objc private func playClicked() { onPlayPause?() }
    @objc private func forwardClicked() { onStepForward?() }
    @objc private func endClicked() { onGoToEnd?() }
    @objc private func loopClicked() { onToggleLoop?() }
}

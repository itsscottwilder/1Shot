// TrimPanel — editable in/out timecodes and "At Playhead" buttons, the in-app equivalent of
// the set_trim MCP tool. Embedded inside AssetsPanel (3.1.0) to trim whichever source clip is
// selected there. Dragging the yellow handles directly on the timeline still works as before.

import Cocoa

final class TrimPanel: NSVisualEffectView {
    static let width: CGFloat = RightPanel.width

    /// A timecode field was edited and should become the new in/out point (original-clip seconds).
    var onSetIn: ((Double) -> Void)?
    var onSetOut: ((Double) -> Void)?
    var onSetInAtPlayhead: (() -> Void)?
    var onSetOutAtPlayhead: (() -> Void)?

    private let inField = NSTextField(string: "00:00:00")
    private let outField = NSTextField(string: "00:00:00")
    private let durationLabel = NSTextField(labelWithString: "Duration —")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: TrimPanel.width, height: 400))
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)

        let title = NSTextField(labelWithString: "Trim")
        title.font = .boldSystemFont(ofSize: 15)
        let subtitle = NSTextField(labelWithString: "Start and stop points")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        let inRow = fieldRow("In", inField, fieldAction: #selector(inEdited), buttonAction: #selector(setInClicked))
        let outRow = fieldRow("Out", outField, fieldAction: #selector(outEdited), buttonAction: #selector(setOutClicked))

        durationLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        durationLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, subtitle, inRow, outRow, durationLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(16, after: subtitle)
        stack.setCustomSpacing(16, after: outRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            // As tall as its contents (3.5): the Assets panel stacks it under a list that grows.
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            inRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            outRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func fieldRow(_ title: String, _ field: NSTextField, fieldAction: Selector, buttonAction: Selector) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.widthAnchor.constraint(equalToConstant: 26).isActive = true
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.target = self
        field.action = fieldAction
        field.toolTip = "MM:SS:FF — press Return to apply"
        field.widthAnchor.constraint(equalToConstant: 76).isActive = true
        let setButton = NSButton(title: "At Playhead", target: self, action: buttonAction)
        setButton.bezelStyle = .rounded
        setButton.controlSize = .small
        setButton.refusesFirstResponder = true
        let row = NSStackView(views: [label, field, setButton])
        row.orientation = .horizontal
        row.spacing = 6
        return row
    }

    @objc private func inEdited() {
        guard let seconds = TrimBar.parseTimecode(inField.stringValue) else { return }
        onSetIn?(seconds)
    }
    @objc private func outEdited() {
        guard let seconds = TrimBar.parseTimecode(outField.stringValue) else { return }
        onSetOut?(seconds)
    }
    @objc private func setInClicked() { onSetInAtPlayhead?() }
    @objc private func setOutClicked() { onSetOutAtPlayhead?() }

    /// Reflects the current trim range (original-clip seconds). Called whenever it changes.
    func update(start: Double, end: Double) {
        inField.stringValue = TrimBar.format(start)
        outField.stringValue = TrimBar.format(end)
        durationLabel.stringValue = "Duration \(TrimBar.format(max(0, end - start)))"
    }
}

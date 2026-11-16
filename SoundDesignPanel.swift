// SoundDesignPanel — the Sound Design tab's permanent right-side panel:
// voice isolation, high pass, noise gate, compressor, limiter, output meters.

import Cocoa
import AVFoundation

final class SoundDesignPanel: NSVisualEffectView {
    static let width: CGFloat = RightPanel.width

    private let rack: AudioRack
    private let meter = MeterView()
    private var meterTimer: Timer?
    private let isolationAmount = ResetSlider()
    private let isolationModel = NSSlider()
    private let isolationAmountLabel = NSTextField(labelWithString: "Off")
    private let isolationModelLabel = NSTextField(labelWithString: "HQV")
    private let highPass = ResetSlider()
    private let highPassLabel = NSTextField(labelWithString: "Off")
    private let gateThreshold = ResetSlider()
    private let gateRange = ResetSlider()
    private let gateThresholdLabel = NSTextField(labelWithString: "-50 dB")
    private let gateRangeLabel = NSTextField(labelWithString: "Off")
    private let gateReduction = GainReductionMeter(range: 40)
    private let compThreshold = ResetSlider()
    private let compRatio = ResetSlider()
    private let compMakeup = ResetSlider()
    private let compThresholdLabel = NSTextField(labelWithString: "0 dB")
    private let compRatioLabel = NSTextField(labelWithString: "Off")
    private let compMakeupLabel = NSTextField(labelWithString: "+0 dB")
    private let gainReduction = GainReductionMeter()
    private let deEssFrequency = ResetSlider()
    private let deEssAmount = ResetSlider()
    private let deEssFrequencyLabel = NSTextField(labelWithString: "4.5 kHz")
    private let deEssAmountLabel = NSTextField(labelWithString: "Off")
    private let deEssReduction = GainReductionMeter(range: 20)
    private let limiterInput = ResetSlider()
    private let limiterInputLabel = NSTextField(labelWithString: "+0.0 dB")
    private let limiterReduction = GainReductionMeter(range: 10)     // limiter: 0 to −10 dB

    init(rack: AudioRack) {
        self.rack = rack
        super.init(frame: NSRect(x: 0, y: 0, width: SoundDesignPanel.width, height: 400))
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)

        let title = NSTextField(labelWithString: "Sound Design")
        title.font = .boldSystemFont(ofSize: 15)
        let subtitle = NSTextField(labelWithString: "Audio flows top to bottom")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(subtitle)
        stack.setCustomSpacing(16, after: subtitle)

        // Voice isolation: Apple's two controls, ahead of the five slots.
        let isoLabel = stageTitle("Voice Isolation", .isolation)
        isoLabel.font = .systemFont(ofSize: 12, weight: .semibold)

        isolationAmount.minValue = 0
        isolationAmount.maxValue = 100
        isolationAmount.doubleValue = 0
        isolationAmount.isContinuous = true
        isolationAmount.controlSize = .small
        isolationAmount.refusesFirstResponder = true
        isolationAmount.toolTip = "How much of the isolated voice you hear vs. the original. 0 = off · double-click to turn off"
        isolationAmount.target = self
        isolationAmount.action = #selector(isolationChanged(_:))

        isolationModel.minValue = 0
        isolationModel.maxValue = 1
        isolationModel.numberOfTickMarks = 2
        isolationModel.allowsTickMarkValuesOnly = true
        isolationModel.doubleValue = 1
        isolationModel.controlSize = .small
        isolationModel.refusesFirstResponder = true
        isolationModel.toolTip = "Voice = lighter model · HQV = High Quality Voice (same as Final Cut Pro)"
        isolationModel.target = self
        isolationModel.action = #selector(isolationChanged(_:))

        for (title, slider, value) in [("Amount", isolationAmount as NSSlider, isolationAmountLabel),
                                       ("Model", isolationModel, isolationModelLabel)] {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12)
            label.widthAnchor.constraint(equalToConstant: 58).isActive = true
            value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            value.alignment = .right
            value.widthAnchor.constraint(equalToConstant: 40).isActive = true
            let line = NSStackView(views: [label, slider, value])
            line.orientation = .horizontal
            line.spacing = 6
            line.translatesAutoresizingMaskIntoConstraints = false
            if title == "Amount" {
                stack.addArrangedSubview(isoLabel)
                stack.setCustomSpacing(6, after: isoLabel)
            }
            stack.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            if title == "Model" { stack.setCustomSpacing(12, after: line) }
        }
        updateIsolationLabels()

        // High-pass filter: Off, then 20–400 Hz.
        highPass.minValue = 0
        highPass.maxValue = 100
        highPass.doubleValue = Self.highPassPosition(forFrequency: 120)    // default 120 Hz
        highPass.isContinuous = true
        highPass.controlSize = .small
        highPass.refusesFirstResponder = true
        highPass.toolTip = "Cuts rumble below this frequency (wind, traffic, AC hum). 80–100 Hz suits most voices · double-click to turn off"
        highPass.target = self
        highPass.action = #selector(highPassChanged(_:))
        let hpTitle = NSTextField(labelWithString: "High Pass")
        hpTitle.font = .systemFont(ofSize: 12)
        hpTitle.toolTip = highPass.toolTip
        hpTitle.widthAnchor.constraint(equalToConstant: 58).isActive = true
        highPassLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        highPassLabel.alignment = .right
        highPassLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
        let hpLine = NSStackView(views: [hpTitle, highPass, highPassLabel])
        hpLine.orientation = .horizontal
        hpLine.spacing = 6
        hpLine.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(hpLine)
        hpLine.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(18, after: hpLine)
        highPassChanged(highPass)                       // apply the default

        // Noise gate: Threshold, Range, reduction meter.
        let gateTitle = stageTitle("Noise Gate", .gate)
        gateTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(gateTitle)
        stack.setCustomSpacing(6, after: gateTitle)
        configureGate(gateThreshold, min: -80, max: 0, value: -50,
                      help: "Below this level the gate turns the audio down · double-click for −50 dB")
        gateThreshold.resetValue = -50
        configureGate(gateRange, min: -40, max: 0, value: 0,
                      help: "How far quiet gaps are turned down. 0 = off; −10 to −20 dB sounds natural · double-click to turn off")
        addControlRow("Threshold", gateThreshold, gateThresholdLabel, to: stack)
        addControlRow("Range", gateRange, gateRangeLabel, to: stack)
        let gateGRTitle = NSTextField(labelWithString: "Reduction")
        gateGRTitle.font = .systemFont(ofSize: 12)
        gateGRTitle.widthAnchor.constraint(equalToConstant: 58).isActive = true
        gateReduction.toolTip = "How far the gate is turning the audio down right now"
        gateReduction.heightAnchor.constraint(equalToConstant: 26).isActive = true
        let gateGRLine = NSStackView(views: [gateGRTitle, gateReduction])
        gateGRLine.orientation = .horizontal
        gateGRLine.alignment = .top
        gateGRLine.spacing = 6
        gateGRLine.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(gateGRLine)
        gateGRLine.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(18, after: gateGRLine)
        gateChanged(gateRange)

        // Compressor: Threshold, Ratio, gain-reduction meter, Make-up.
        let compTitle = stageTitle("Compressor", .compressor)
        compTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(compTitle)
        stack.setCustomSpacing(6, after: compTitle)

        configure(compThreshold, min: -40, max: 0, value: 0,
                  help: "Level where compression starts (dBFS) · double-click for 0 dB")
        configure(compRatio, min: 1, max: 10, value: 4,
                  help: "How hard it squeezes above the threshold, up to 10:1. 1:1 = off · double-click to turn off")
        configure(compMakeup, min: 0, max: 24, value: 0,
                  help: "Turns the compressed signal back up · double-click for 0 dB")
        addControlRow("Threshold", compThreshold, compThresholdLabel, to: stack)
        addControlRow("Ratio", compRatio, compRatioLabel, to: stack)

        let grTitle = NSTextField(labelWithString: "Reduction")
        grTitle.font = .systemFont(ofSize: 12)
        grTitle.widthAnchor.constraint(equalToConstant: 58).isActive = true
        gainReduction.toolTip = "How much the compressor is turning the audio down right now"
        gainReduction.heightAnchor.constraint(equalToConstant: 26).isActive = true
        let grLine = NSStackView(views: [grTitle, gainReduction])
        grLine.orientation = .horizontal
        grLine.alignment = .top
        grLine.spacing = 6
        grLine.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(grLine)
        grLine.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let makeupLine = addControlRow("Make-up", compMakeup, compMakeupLabel, to: stack)
        stack.setCustomSpacing(18, after: makeupLine)
        compressorChanged(compRatio)                    // apply the default (4:1)


        // De-esser: Frequency, Amount, reduction meter (after the compressor).
        let dsTitle = stageTitle("De-esser", .deEsser)
        dsTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(dsTitle)
        stack.setCustomSpacing(6, after: dsTitle)
        configure(deEssFrequency, min: 4, max: 10, value: 4.5,
                  help: "Where harsh “s” sounds start for your voice (4–10 kHz) · double-click for 4.5 kHz")
        deEssFrequency.resetValue = 4.5
        deEssFrequency.action = #selector(deEsserChanged(_:))
        configure(deEssAmount, min: 0, max: 100, value: 0,
                  help: "How strongly “s” sounds are tamed. 0 = off · double-click to turn off")
        deEssAmount.action = #selector(deEsserChanged(_:))
        addControlRow("Frequency", deEssFrequency, deEssFrequencyLabel, to: stack)
        addControlRow("Amount", deEssAmount, deEssAmountLabel, to: stack)
        let dsGRTitle = NSTextField(labelWithString: "Reduction")
        dsGRTitle.font = .systemFont(ofSize: 12)
        dsGRTitle.widthAnchor.constraint(equalToConstant: 58).isActive = true
        deEssReduction.toolTip = "How much the “s” band is being turned down right now"
        deEssReduction.heightAnchor.constraint(equalToConstant: 26).isActive = true
        let dsGRLine = NSStackView(views: [dsGRTitle, deEssReduction])
        dsGRLine.orientation = .horizontal
        dsGRLine.alignment = .top
        dsGRLine.spacing = 6
        dsGRLine.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(dsGRLine)
        dsGRLine.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(18, after: dsGRLine)

        // Limiter (last in the audio chain, so it sits right above the Output meter): brick wall, fixed −0.1 dB ceiling, Input drive + reduction meter.
        let limTitle = stageTitle("Limiter", .limiter)
        limTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        let limCeiling = NSTextField(labelWithString: "ceiling −0.1 dB")
        limCeiling.font = .systemFont(ofSize: 11)
        limCeiling.textColor = .secondaryLabelColor
        let limHeader = NSStackView(views: [limTitle, limCeiling])
        limHeader.orientation = .horizontal
        limHeader.spacing = 6
        stack.addArrangedSubview(limHeader)
        stack.setCustomSpacing(6, after: limHeader)

        limiterInput.minValue = 0
        limiterInput.maxValue = 24
        limiterInput.doubleValue = 0
        limiterInput.isContinuous = true
        limiterInput.controlSize = .small
        limiterInput.refusesFirstResponder = true
        limiterInput.toolTip = "Pushes the level into the limiter; peaks never pass −0.1 dB · double-click for 0 dB"
        limiterInput.target = self
        limiterInput.action = #selector(limiterChanged(_:))
        addControlRow("Input", limiterInput, limiterInputLabel, to: stack)

        let limGRTitle = NSTextField(labelWithString: "Reduction")
        limGRTitle.font = .systemFont(ofSize: 12)
        limGRTitle.widthAnchor.constraint(equalToConstant: 58).isActive = true
        limiterReduction.toolTip = "How much the limiter is holding peaks down right now"
        limiterReduction.heightAnchor.constraint(equalToConstant: 26).isActive = true
        let limGRLine = NSStackView(views: [limGRTitle, limiterReduction])
        limGRLine.orientation = .horizontal
        limGRLine.alignment = .top
        limGRLine.spacing = 6
        limGRLine.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(limGRLine)
        limGRLine.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(18, after: limGRLine)

        // Output meter (final mix, after all audio processing)
        let meterLabel = NSTextField(labelWithString: "Output")
        meterLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        meter.toolTip = "Final output level · click to reset the clip lights"
        meter.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(meterLabel)
        stack.setCustomSpacing(6, after: meterLabel)
        stack.addArrangedSubview(meter)
        meter.heightAnchor.constraint(equalToConstant: MeterView.height).isActive = true
        meter.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        stack.translatesAutoresizingMaskIntoConstraints = false

        // Scrolls if the window is too short to show everything.
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

        meterTimer = Timer.everyMode(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self, !self.isHidden else { return }
            let reading = self.rack.meterReading()
            self.meter.update(peak: reading.peak, rms: reading.rms)
            self.gainReduction.update(reduction: self.rack.compressorGainReduction())
            self.deEssReduction.update(reduction: self.rack.deEsserGainReduction())
            self.gateReduction.update(reduction: self.rack.gateGainReduction())
            self.limiterReduction.update(reduction: self.rack.limiterGainReduction())
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -18)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Click a section title to bypass it

    private var stageTitles: [AudioRack.Stage: NSTextField] = [:]

    private func stageTitle(_ text: String, _ stage: AudioRack.Stage) -> ClickableLabel {
        let label = ClickableLabel(labelWithString: text)
        label.toolTip = "Click to bypass this whole section (settings are kept)"
        label.onClick = { [weak self] in
            guard let self else { return }
            self.setStage(stage, bypassed: !self.rack.bypassed.contains(stage))
        }
        stageTitles[stage] = label
        return label
    }

    private func setStage(_ stage: AudioRack.Stage, bypassed off: Bool) {
        rack.setBypassed(stage, off)
        stageTitles[stage]?.textColor = rack.bypassed.contains(stage) ? .systemRed : .labelColor
    }

    /// Moving a slider in a bypassed section switches it back on.
    private func wake(_ stage: AudioRack.Stage) {
        if rack.bypassed.contains(stage) { setStage(stage, bypassed: false) }
    }

    @objc private func isolationChanged(_ sender: NSSlider) {
        wake(.isolation)
        let amount = isolationAmount.doubleValue.rounded()
        let highQuality = isolationModel.doubleValue >= 0.5
        updateIsolationLabels()
        rack.setIsolation(amount: amount, highQuality: highQuality) { [weak self] error in
            guard let self, let error else { return }
            self.isolationAmount.doubleValue = 0
            self.updateIsolationLabels()
            self.showError("Couldn't turn on voice isolation.", error)
        }
    }

    // MARK: Compressor controls

    private func configure(_ slider: NSSlider, min: Double, max: Double, value: Double, help: String) {
        slider.minValue = min
        slider.maxValue = max
        slider.doubleValue = value
        slider.isContinuous = true
        slider.controlSize = .small
        slider.refusesFirstResponder = true
        slider.toolTip = help
        slider.target = self
        slider.action = #selector(compressorChanged(_:))
    }

    @discardableResult
    private func addControlRow(_ title: String, _ slider: NSSlider, _ value: NSTextField, to stack: NSStackView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.toolTip = slider.toolTip
        label.widthAnchor.constraint(equalToConstant: 58).isActive = true
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.alignment = .right
        value.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let line = NSStackView(views: [label, slider, value])
        line.orientation = .horizontal
        line.spacing = 6
        line.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(line)
        line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return line
    }

    @objc private func compressorChanged(_ sender: NSSlider) {
        wake(.compressor)
        updateCompressorLabels()
        rack.setCompressor(threshold: compThreshold.doubleValue.rounded(),
                           ratio: (compRatio.doubleValue * 10).rounded() / 10,
                           makeup: (compMakeup.doubleValue * 2).rounded() / 2)
    }

    private func configureGate(_ slider: NSSlider, min: Double, max: Double, value: Double, help: String) {
        configure(slider, min: min, max: max, value: value, help: help)
        slider.action = #selector(gateChanged(_:))
    }

    @objc private func gateChanged(_ sender: NSSlider) {
        wake(.gate)
        let threshold = gateThreshold.doubleValue.rounded()
        let range = gateRange.doubleValue.rounded()
        gateThresholdLabel.stringValue = "\(Int(threshold)) dB"
        gateRangeLabel.stringValue = range >= -0.5 ? "Off" : "\(Int(range)) dB"
        rack.setGate(threshold: threshold, range: range)
    }

    @objc private func deEsserChanged(_ sender: NSSlider) {
        wake(.deEsser)
        let khz = (deEssFrequency.doubleValue * 10).rounded() / 10
        let amount = deEssAmount.doubleValue.rounded()
        deEssFrequencyLabel.stringValue = String(format: "%.1f kHz", khz)
        deEssAmountLabel.stringValue = amount < 0.5 ? "Off" : "\(Int(amount))"
        rack.setDeEsser(frequency: khz * 1000, amount: amount)
    }

    @objc private func limiterChanged(_ sender: NSSlider) {
        wake(.limiter)
        let db = (sender.doubleValue * 2).rounded() / 2
        limiterInputLabel.stringValue = String(format: "+%.1f dB", db)
        rack.setLimiter(inputGain: db)
    }

    private func updateCompressorLabels() {
        compThresholdLabel.stringValue = "\(Int(compThreshold.doubleValue.rounded())) dB"
        let ratio = (compRatio.doubleValue * 10).rounded() / 10
        compRatioLabel.stringValue = ratio <= 1.01 ? "Off" : String(format: "%.1f:1", ratio)
        let makeup = (compMakeup.doubleValue * 2).rounded() / 2
        compMakeupLabel.stringValue = String(format: "+%.1f dB", makeup)
    }

    /// Slider position → cutoff: 0 = off, 1…100 = 20…400 Hz on a log scale.
    private static func highPassFrequency(forPosition p: Double) -> Double {
        guard p >= 0.5 else { return 0 }
        return 20 * pow(400.0 / 20.0, (p - 1) / 99)
    }

    /// Inverse of highPassFrequency(forPosition:).
    private static func highPassPosition(forFrequency hz: Double) -> Double {
        1 + 99 * log(hz / 20) / log(400.0 / 20.0)
    }

    @objc private func highPassChanged(_ sender: NSSlider) {
        if sender.doubleValue < 0.5 { sender.doubleValue = 0 }
        let hz = Self.highPassFrequency(forPosition: sender.doubleValue)
        highPassLabel.stringValue = hz == 0 ? "Off" : "\(Int(hz.rounded())) Hz"
        rack.setHighPass(frequency: hz)
    }

    private func updateIsolationLabels() {
        let amount = Int(isolationAmount.doubleValue.rounded())
        isolationAmountLabel.stringValue = amount == 0 ? "Off" : "\(amount)%"
        isolationModelLabel.stringValue = isolationModel.doubleValue >= 0.5 ? "HQV" : "Voice"
    }

    private func showError(_ message: String, _ error: Error?) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error?.localizedDescription ?? ""
        if let w = window { alert.beginSheetModal(for: w) } else { alert.runModal() }
    }
}

// MARK: - Saving / restoring (projects)

extension SoundDesignPanel {
    struct Snapshot: Codable, Equatable {
        var values: [String: Double]    // raw slider positions
        var bypassed: [String]          // section names switched off (red)
    }

    private var namedSliders: [(String, NSSlider)] {
        let list: [(String, NSSlider)] = [
            ("isolationAmount", isolationAmount as NSSlider), ("isolationModel", isolationModel),
            ("highPass", highPass as NSSlider),
            ("gateThreshold", gateThreshold as NSSlider), ("gateRange", gateRange as NSSlider),
            ("compThreshold", compThreshold as NSSlider), ("compRatio", compRatio as NSSlider),
            ("compMakeup", compMakeup as NSSlider),
            ("deEssFrequency", deEssFrequency as NSSlider), ("deEssAmount", deEssAmount as NSSlider),
            ("limiterInput", limiterInput as NSSlider)]
        return list
    }

    private static let stageNames: [(String, AudioRack.Stage)] = [
        ("isolation", .isolation), ("gate", .gate), ("compressor", .compressor),
        ("deEsser", .deEsser), ("limiter", .limiter)]

    var snapshot: Snapshot {
        var values: [String: Double] = [:]
        for (name, slider) in namedSliders { values[name] = slider.doubleValue }
        let off = Self.stageNames.filter { rack.bypassed.contains($0.1) }.map { $0.0 }
        return Snapshot(values: values, bypassed: off)
    }

    /// Puts every control back and applies it to the audio chain.
    func restore(_ s: Snapshot) {
        for (name, slider) in namedSliders {
            if let v = s.values[name] { slider.doubleValue = v }
        }
        // Apply each section (these also switch sections back on…)
        if isolationAmount.doubleValue.rounded() > 0 || rack.isolationMode != .off { isolationChanged(isolationAmount) }
        highPassChanged(highPass)
        gateChanged(gateThreshold)
        compressorChanged(compThreshold)
        deEsserChanged(deEssAmount)
        limiterChanged(limiterInput)
        // …so set the bypassed (red) sections last.
        for (name, stage) in Self.stageNames {
            setStage(stage, bypassed: s.bypassed.contains(name))
        }
    }
}

/// Top-to-bottom coordinates so scrolled content starts at the top.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

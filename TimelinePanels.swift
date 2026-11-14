// TimelinePanels — 3.2: fills the Cuts, Zooms, B-roll and Graphics tabs' list panels from the
// edit, and applies the edits made there (typed In/Out timecodes, delete, B-roll framing).
// Everything is in original-clip seconds, like the rest of the app.

import Cocoa
import AVFoundation

/// Zoom and pan sliders for the selected B-roll shot (B-roll tab, under the list).
final class BrollFramingControls: NSView {
    var onChange: ((Double, Double, Double) -> Void)?
    private let zoom = NSSlider(value: 1, minValue: 1, maxValue: 3, target: nil, action: nil)
    private let panX = NSSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let panY = NSSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let zoomValue = NSTextField(labelWithString: "1.00×")
    private let hint = NSTextField(labelWithString: "Select a shot to zoom and pan it")
    private let reset = NSButton(title: "Reset", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        let title = NSTextField(labelWithString: "Framing")
        title.font = .boldSystemFont(ofSize: 12)
        hint.font = .systemFont(ofSize: 10.5)
        hint.textColor = .secondaryLabelColor
        zoomValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.target = self
        reset.action = #selector(resetClicked)
        for s in [zoom, panX, panY] {
            s.target = self
            s.action = #selector(changed)
            s.isContinuous = true
            s.controlSize = .small
        }
        let header = NSStackView(views: [title, NSView(), reset])
        let stack = NSStackView(views: [header, hint,
                                        row("Zoom", zoom, zoomValue),
                                        row("Pan ←→", panX, nil),
                                        row("Pan ↑↓", panY, nil)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        setShot(nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func row(_ name: String, _ slider: NSSlider, _ value: NSTextField?) -> NSStackView {
        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 11)
        label.widthAnchor.constraint(equalToConstant: 52).isActive = true
        slider.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let r = NSStackView(views: [label, slider] + (value.map { [$0] } ?? []))
        r.spacing = 6
        return r
    }

    /// Shows the selected shot's framing; nil disables the sliders.
    func setShot(_ c: BrollClip?) {
        let on = c != nil
        [zoom, panX, panY, reset].forEach { $0.isEnabled = on }
        hint.isHidden = on
        zoom.doubleValue = c?.zoom ?? 1
        panX.doubleValue = c?.panX ?? 0
        panY.doubleValue = c?.panY ?? 0
        zoomValue.stringValue = String(format: "%.2f×", zoom.doubleValue)
    }

    @objc private func changed() {
        zoomValue.stringValue = String(format: "%.2f×", zoom.doubleValue)
        onChange?(zoom.doubleValue, panX.doubleValue, panY.doubleValue)
    }

    @objc private func resetClicked() {
        zoom.doubleValue = 1; panX.doubleValue = 0; panY.doubleValue = 0
        changed()
    }
}

/// Size and position for the selected plate (Graphics tab, under the list). Moves live.
final class GraphicsPlacementControls: NSView {
    /// (scale, dx, dy, side) — dx/dy in px of a 1920×1080 frame.
    var onChange: ((Double, Double, Double, String?) -> Void)?
    private let size = NSSlider(value: 1, minValue: 0.3, maxValue: 2.5, target: nil, action: nil)
    private let posX = NSSlider(value: 0, minValue: -960, maxValue: 960, target: nil, action: nil)
    private let posY = NSSlider(value: 0, minValue: -540, maxValue: 540, target: nil, action: nil)
    private let sizeValue = NSTextField(labelWithString: "1.00×")
    private let side = NSSegmentedControl(labels: ["Left", "Right"], trackingMode: .selectOne, target: nil, action: nil)
    private let hint = NSTextField(labelWithString: "Select a plate to move or resize it")
    private let reset = NSButton(title: "Reset", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        let title = NSTextField(labelWithString: "Size & position")
        title.font = .boldSystemFont(ofSize: 12)
        hint.font = .systemFont(ofSize: 10.5)
        hint.textColor = .secondaryLabelColor
        sizeValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.target = self
        reset.action = #selector(resetClicked)
        side.controlSize = .small
        side.target = self
        side.action = #selector(changed)
        for s in [size, posX, posY] {
            s.target = self
            s.action = #selector(changed)
            s.isContinuous = true
            s.controlSize = .small
        }
        let header = NSStackView(views: [title, NSView(), reset])
        let sideRow = NSStackView(views: [label("Side"), side])
        sideRow.spacing = 6
        let stack = NSStackView(views: [header, hint, row("Size", size, sizeValue), row("← →", posX, nil),
                                        row("↑ ↓", posY, nil), sideRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        setPlate(nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.widthAnchor.constraint(equalToConstant: 40).isActive = true
        return l
    }

    private func row(_ name: String, _ slider: NSSlider, _ value: NSTextField?) -> NSStackView {
        slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let r = NSStackView(views: [label(name), slider] + (value.map { [$0] } ?? []))
        r.spacing = 6
        return r
    }

    /// Shows the selected plate's size and position; nil disables the controls.
    func setPlate(_ p: GraphicPlate?) {
        let on = p != nil
        [size, posX, posY, reset].forEach { $0.isEnabled = on }
        side.isEnabled = on && p?.isFullScreen == false && p?.template != "ring"
        hint.isHidden = on
        size.doubleValue = p?.scale ?? 1
        posX.doubleValue = p?.dx ?? 0
        posY.doubleValue = p?.dy ?? 0
        side.selectedSegment = (p?.side ?? "left") == "right" ? 1 : 0
        sizeValue.stringValue = String(format: "%.2f×", size.doubleValue)
    }

    @objc private func changed() {
        sizeValue.stringValue = String(format: "%.2f×", size.doubleValue)
        onChange?(size.doubleValue, posX.doubleValue, posY.doubleValue, side.isEnabled ? (side.selectedSegment == 1 ? "right" : "left") : nil)
    }

    @objc private func resetClicked() {
        size.doubleValue = 1; posX.doubleValue = 0; posY.doubleValue = 0
        changed()
    }
}

extension PlayerWindowController {

    /// Wires the four list panels into the right panel. Called once from init.
    func setUpTimelinePanels() {
        rightPanel.setPage(cutsPanel, for: .cuts)
        rightPanel.setPage(zoomsPanel, for: .zooms)
        rightPanel.setPage(brollPanel, for: .broll)
        rightPanel.setPage(graphicsPanel, for: .graphics)

        // Cuts
        cutsPanel.onSelect = { [weak self] i in
            guard let self, self.cuts.indices.contains(i) else { return }
            self.jumpTo(max(0, self.cuts[i].start - 1))
            self.trimBar.selectedCut = i
        }
        cutsPanel.onEditStart = { [weak self] i, t in
            guard let self, self.cuts.indices.contains(i) else { return }
            var c = self.cuts[i]
            guard t < c.end - CutList.minimumLength else { NSSound.beep(); self.refreshCutsPanel(); return }
            c.start = t
            self.resizeCut(at: i, to: c)
        }
        cutsPanel.onEditEnd = { [weak self] i, t in
            guard let self, self.cuts.indices.contains(i) else { return }
            var c = self.cuts[i]
            guard t > c.start + CutList.minimumLength else { NSSound.beep(); self.refreshCutsPanel(); return }
            c.end = t
            self.resizeCut(at: i, to: c)
        }
        cutsPanel.onDelete = { [weak self] i in self?.removeCut(at: i) }

        // Zooms (one row per punch-in, its Out is the reset that ends it)
        zoomsPanel.onSelect = { [weak self] r in
            guard let self, self.zoomRowMap.indices.contains(r) else { return }
            self.jumpTo(self.zooms[self.zoomRowMap[r].punch].at)
        }
        zoomsPanel.onEditStart = { [weak self] r, t in
            guard let self, self.zoomRowMap.indices.contains(r) else { return }
            let m = self.zoomRowMap[r]
            if let reset = m.reset, t >= self.zooms[reset].at - 0.05 { NSSound.beep(); self.refreshZoomsPanel(); return }
            self.moveZoom(at: m.punch, to: t)
        }
        zoomsPanel.onEditEnd = { [weak self] r, t in
            guard let self, self.zoomRowMap.indices.contains(r) else { return }
            let m = self.zoomRowMap[r]
            guard t > self.zooms[m.punch].at + 0.05 else { NSSound.beep(); self.refreshZoomsPanel(); return }
            if let reset = m.reset { self.moveZoom(at: reset, to: t) } else { self.addZoom(at: t, scale: 1) }
        }
        zoomsPanel.onDelete = { [weak self] r in
            guard let self, self.zoomRowMap.indices.contains(r) else { return }
            let m = self.zoomRowMap[r]
            var list = self.zooms
            for i in [m.reset, m.punch].compactMap({ $0 }).sorted(by: >) { list.remove(at: i) }
            self.setZooms(list)
        }

        // B-roll
        brollPanel.onSelect = { [weak self] i in
            guard let self, self.broll.indices.contains(i) else { return }
            self.jumpTo(self.broll[i].at + 0.05)
        }
        brollPanel.onSelectionChanged = { [weak self] i in
            guard let self else { return }
            self.brollFraming.setShot(i.flatMap { self.broll.indices.contains($0) ? self.broll[$0] : nil })
            self.updateBrollHandles()
        }
        brollPanel.onEditStart = { [weak self] i, t in
            guard let self, self.broll.indices.contains(i) else { return }
            self.editBroll(at: i, start: t, end: t, part: 0)       // move, keeping its length
        }
        brollPanel.onEditEnd = { [weak self] i, t in
            guard let self, self.broll.indices.contains(i) else { return }
            guard t > self.broll[i].at + 0.3 else { NSSound.beep(); self.refreshBrollPanel(); return }
            self.editBroll(at: i, start: self.broll[i].at, end: t, part: 2)
        }
        brollPanel.onDelete = { [weak self] i in self?.removeBroll(at: i) }
        brollFraming.onChange = { [weak self] zoom, panX, panY in
            guard let self, let i = self.brollPanel.selectedRow, self.broll.indices.contains(i) else { return }
            self.setBrollFraming(at: i, zoom: zoom, panX: panX, panY: panY)
        }

        // Graphics
        graphicsPanel.onSelect = { [weak self] i in
            guard let self, self.graphics.indices.contains(i) else { return }
            self.jumpTo(self.graphics[i].at + min(1.5, self.graphics[i].length / 2))
        }
        graphicsPanel.onEditStart = { [weak self] i, t in
            guard let self, self.graphics.indices.contains(i) else { return }
            self.editGraphic(at: i, start: t, end: t, part: 0)
        }
        graphicsPanel.onEditEnd = { [weak self] i, t in
            guard let self, self.graphics.indices.contains(i) else { return }
            guard t > self.graphics[i].at + 0.3 else { NSSound.beep(); self.refreshGraphicsPanel(); return }
            self.editGraphic(at: i, start: self.graphics[i].at, end: t, part: 2)
        }
        graphicsPanel.onDelete = { [weak self] i in
            guard let self, self.graphics.indices.contains(i) else { return }
            var list = self.graphics
            list.remove(at: i)
            self.setGraphics(list)
        }
        trimBar.onEditGraphics = { [weak self] i, s, e, part in self?.editGraphic(at: i, start: s, end: e, part: part) }

        // Export (3.2)
        rightPanel.setPage(exportPanel, for: .export)
        exportPanel.onExport = { [weak self] in self?.exportVideo() }
        exportPanel.onRecipeChanged = { [weak self] _ in self?.refreshExportPanel() }
        graphicsPanel.onSelectionChanged = { [weak self] i in
            guard let self else { return }
            self.plateControls.setPlate(i.flatMap { self.graphics.indices.contains($0) ? self.graphics[$0] : nil })
            self.updatePlateHandles()
        }
        plateControls.onChange = { [weak self] scale, dx, dy, side in
            guard let self, let i = self.graphicsPanel.selectedRow, self.graphics.indices.contains(i) else { return }
            var list = self.graphics
            list[i].scale = abs(scale - 1) > 0.001 ? scale : nil
            list[i].dx = abs(dx) > 0.5 ? dx.rounded() : nil
            list[i].dy = abs(dy) > 0.5 ? dy.rounded() : nil
            if let side { list[i].side = side }
            let p = list[i]
            self.setGraphics(list)
            // Keep the plate on screen while it's being adjusted.
            let end = self.clipTimeFor(edited: self.edited(p.at) + p.length)
            if self.trimBar.playhead < p.at || self.trimBar.playhead > end {
                self.jumpTo(p.at + min(p.length - 0.1, max(0.5, p.length * 0.6)))
            }
        }
    }

    /// The Export tab's "what you'll get": output size and finished length for the chosen recipe.
    func refreshExportPanel() {
        let size = player?.currentItem?.presentationSize ?? .zero
        let length = trimRange.map {
            $0.end - $0.start - CutList.totalLength(CutList.normalized(cuts, trim: $0)) + (fadeEnabled ? 2 : 0)
        } ?? (trimBar.duration > 0 ? trimBar.duration - CutList.totalLength(cuts) + (fadeEnabled ? 2 : 0) : nil)
        exportPanel.update(sourceWidth: Int(size.width), sourceHeight: Int(size.height), length: length)
    }

    /// Moves the playhead (and the picture) to a clip time.
    func jumpTo(_ t: Double) {
        player?.pause()
        trimBar.playhead = t
        player?.seek(to: CMTime(seconds: toComp(t), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: Edits from the panels / the V2 lane

    /// Moves (part 0) or trims (1 = left edge, 2 = right edge) a plate. Its length is on-screen
    /// (edited) time, like B-roll; build times move with it.
    func editGraphic(at i: Int, start s: Double, end e: Double, part: Int) {
        guard graphics.indices.contains(i) else { return }
        var p = graphics[i]
        switch part {
        case 1:
            let delta = edited(s) - edited(p.at)
            p.at = max(0, s)
            p.length = max(0.5, p.length - delta)
        case 2:
            p.length = max(0.5, edited(e) - edited(p.at))
        default:
            let shift = max(0, s) - p.at
            p.at = max(0, s)
            p.builds = p.builds?.map { $0 + shift }
        }
        var list = graphics
        list[i] = p
        setGraphics(list)
        graphicsPanel.select(graphics.firstIndex { $0.id == p.id })
    }

    func setBrollFraming(at i: Int, zoom: Double, panX: Double, panY: Double) {
        guard broll.indices.contains(i) else { return }
        var list = broll
        list[i].zoom = zoom > 1.001 ? zoom : nil
        list[i].panX = abs(panX) > 0.001 ? panX : nil
        list[i].panY = abs(panY) > 0.001 ? panY : nil
        setBroll(list)
        // Show the shot as it now looks.
        if trimBar.playhead < list[i].at || trimBar.playhead > clipTimeFor(edited: edited(list[i].at) + list[i].length) {
            jumpTo(list[i].at + min(1, list[i].length / 2))
        }
    }

    // MARK: Filling the lists

    func refreshCutsPanel() {
        let rows = cuts.map { c -> TimelineListRow in
            let what = [c.reason, c.note].compactMap { $0 }.filter { !$0.isEmpty }
            return TimelineListRow(start: c.start, end: c.end,
                                   title: what.first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Cut",
                                   detail: (what.count > 1 ? what[1] + " · " : "") + String(format: "removes %.2f s", c.length),
                                   color: NSColor.systemRed)
        }
        let total = cuts.reduce(0) { $0 + $1.length }
        cutsPanel.setRows(rows, summary: "\(cuts.count) cut\(cuts.count == 1 ? "" : "s") · \(String(format: "%.1f", total)) s removed")
    }

    func refreshZoomsPanel() {
        var map: [(punch: Int, reset: Int?)] = []
        for (i, z) in zooms.enumerated() where z.scale > 1.001 {
            let next = zooms.indices.first { $0 > i }
            let reset = next.flatMap { abs(zooms[$0].scale - 1) < 0.001 ? $0 : nil }
            map.append((i, reset))
        }
        zoomRowMap = map
        let rows = map.map { m -> TimelineListRow in
            let z = zooms[m.punch]
            let kind = z.type == "cta" ? "CTA" : (z.reason == "gag" ? "Gag" : "Punch-in")
            return TimelineListRow(start: z.at, end: m.reset.map { zooms[$0].at },
                                   title: String(format: "%.2f× %@", z.scale, kind),
                                   detail: z.words ?? z.reason ?? "",
                                   color: NSColor.systemYellow)
        }
        zoomsPanel.setRows(rows, summary: "\(rows.count) zoom\(rows.count == 1 ? "" : "s")")
    }

    func refreshBrollPanel() {
        let rows = broll.enumerated().map { i, c -> TimelineListRow in
            let name = c.file.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
                ?? c.pixabayId.map { "Pixabay \($0)" } ?? c.search ?? "B-roll"
            var detail = c.words ?? c.credit ?? ""
            if let z = c.zoom, z > 1.001 { detail = String(format: "%.2f× · ", z) + detail }
            return TimelineListRow(start: c.at, end: clipTimeFor(edited: edited(c.at) + c.length),
                                   title: name, detail: detail, color: TrimBar.brollColor,
                                   thumbnail: listThumbCache[brollThumbKey(c)])
        }
        brollPanel.setRows(rows, summary: "\(broll.count) shot\(broll.count == 1 ? "" : "s") · \(String(format: "%.1f", broll.reduce(0) { $0 + $1.length })) s")
        for (i, c) in broll.enumerated() where listThumbCache[brollThumbKey(c)] == nil { makeBrollThumb(c, row: i) }
        brollFraming.setShot(brollPanel.selectedRow.flatMap { broll.indices.contains($0) ? broll[$0] : nil })
    }

    func refreshGraphicsPanel() {
        let rows = graphics.map { p -> TimelineListRow in
            let words = [p.title, p.kicker, p.items?.first].compactMap { $0 }.first
            let label = (words ?? "").replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "\\n", with: " ")
            return TimelineListRow(start: p.at, end: clipTimeFor(edited: edited(p.at) + p.length),
                                   title: label.isEmpty ? p.template : label,
                                   detail: p.template + (p.subtitle.map { " · " + $0 } ?? ""),
                                   color: TrimBar.graphicsColor, thumbnail: graphicsThumb(p))
        }
        graphicsPanel.setRows(rows, summary: "\(graphics.count) plate\(graphics.count == 1 ? "" : "s")")
        // Forget the thumbnails of plates that are gone.
        if plateThumbCache.count > graphics.count {
            let ids = Set(graphics.map(\.id))
            plateThumbCache = plateThumbCache.filter { ids.contains($0.key) }
        }
    }

    // MARK: Thumbnails

    private func brollThumbKey(_ c: BrollClip) -> String { "\(c.file ?? c.id)@\(c.sourceIn ?? 0)" }

    private func makeBrollThumb(_ c: BrollClip, row: Int) {
        guard let url = brollURL(c) else { return }
        let key = brollThumbKey(c)
        if c.isPhoto {
            // A small copy is all the list needs (a full-size photo can be tens of MB once decoded).
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: 384]
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                listThumbCache[key] = img
                brollPanel.setThumbnail(img, row: row)
            }
            return
        }
        // One request per thumbnail: the list is refreshed on every slider tick, and each
        // AVAssetImageGenerator opens its own video decoders.
        guard !brollThumbsLoading.contains(key) else { return }
        brollThumbsLoading.insert(key)
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 192, height: 108)
        let t = CMTime(seconds: (c.sourceIn ?? 0) + 0.5, preferredTimescale: 600)
        gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: t)]) { [weak self] _, cg, _, _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.brollThumbsLoading.remove(key)
                guard let cg else { return }
                let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                self.listThumbCache[key] = img
                if let r = self.broll.firstIndex(where: { self.brollThumbKey($0) == key }) { self.brollPanel.setThumbnail(img, row: r) }
            }
        }
    }

    /// The plate itself, drawn small on a dark frame. Kept per plate and redrawn only when the
    /// plate or the graphics style changes.
    private func graphicsThumb(_ p: GraphicPlate) -> NSImage? {
        let style = "\(GraphicsStyle.redHex)|\(GraphicsTuningStore.version)"
        if let hit = plateThumbCache[p.id], hit.plate == p, hit.style == style { return hit.image }
        let w = 192, h = 108
        guard let plate = PlateDrawing.render(p, width: w, height: h, red: GraphicsStyle.red) else { return nil }
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        NSColor(white: 0.18, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        NSGraphicsContext.current?.cgContext.draw(plate, in: CGRect(x: 0, y: 0, width: w, height: h))
        img.unlockFocus()
        plateThumbCache[p.id] = (plate: p, style: style, image: img)
        return img
    }
}

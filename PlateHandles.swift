// PlateHandles — 3.2: move and resize a motion-graphics plate right on the video
// (2026-11-12: "draw a box with four corner handles that I can use to resize the graphic, and a
// handle in the center so I can move it"). In the Graphics tab, the plate on screen at the
// playhead gets a box: drag a corner to resize (the opposite corner stays put), drag the centre
// handle (or anywhere inside the box) to move it. Other plates on screen get a faint box; click
// one to switch to it. While dragging, the plate's finished image is moved and scaled live;
// it's redrawn sharp at the new size when you let go.

import Cocoa
import AVFoundation

final class PlateHandlesView: NSView {
    enum Grab: Equatable { case move, corner(Int), rotate }   // corners: 0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right

    /// The active plate's box and the other plates on screen, in this view's (flipped) coordinates.
    var box: NSRect? { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var others: [(index: Int, rect: NSRect)] = [] { didSet { needsDisplay = true } }
    /// 3.8.0 (B-roll pictures): the box's turn in radians, clockwise on screen, and whether it gets
    /// a rotate knob above its top edge.
    var angle: CGFloat = 0 { didSet { if angle != oldValue { needsDisplay = true; window?.invalidateCursorRects(for: self) } } }
    var rotatable = false { didSet { if rotatable != oldValue { needsDisplay = true } } }
    private let knobGap: CGFloat = 26

    var onGrab: ((Grab, NSPoint) -> Void)?
    var onDrag: ((NSPoint, _ shift: Bool) -> Void)?
    var onRelease: (() -> Void)?
    var onPickOther: ((Int) -> Void)?

    private let corner: CGFloat = 11
    private let centre: CGFloat = 26
    private var dragging = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func corners(_ r: NSRect) -> [NSPoint] {
        [NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.maxX, y: r.minY),
         NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.maxX, y: r.maxY)]
    }

    /// A view point turned into the box's own (unturned) frame.
    private func local(_ p: NSPoint, _ r: NSRect) -> NSPoint {
        guard angle != 0 else { return p }
        let dx = p.x - r.midX, dy = p.y - r.midY, c = cos(-angle), s = sin(-angle)
        return NSPoint(x: r.midX + dx * c - dy * s, y: r.midY + dx * s + dy * c)
    }

    /// Above the top edge, or just inside it when there's no room above (a picture as tall as the frame).
    private func knob(_ r: NSRect) -> NSPoint {
        let above = r.minY - knobGap
        return NSPoint(x: r.midX, y: above >= bounds.minY + 10 ? above : r.minY + knobGap)
    }

    private func grab(at viewPoint: NSPoint) -> Grab? {
        guard let r = box else { return nil }
        let p = local(viewPoint, r)
        if rotatable, hypot(p.x - knob(r).x, p.y - knob(r).y) <= 10 { return .rotate }
        for (i, c) in corners(r).enumerated() where abs(p.x - c.x) <= corner && abs(p.y - c.y) <= corner {
            return .corner(i)
        }
        if hypot(p.x - r.midX, p.y - r.midY) <= centre / 2 + 4 || r.contains(p) { return .move }
        return nil
    }

    /// Only the handles, the box and other plates' boxes take clicks; the rest of the video doesn't.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let p = convert(point, from: superview)
        if grab(at: p) != nil || others.contains(where: { $0.rect.contains(p) }) { return self }
        return nil
    }

    override func resetCursorRects() {
        guard let r = box else { return }
        if angle != 0 { return }      // turned: the plain arrow (cursor rects can't turn)
        if rotatable {
            let k = knob(r)
            addCursorRect(NSRect(x: k.x - 10, y: k.y - 10, width: 20, height: 20), cursor: .pointingHand)
        }
        addCursorRect(r, cursor: .openHand)
        for c in corners(r) {
            addCursorRect(NSRect(x: c.x - corner, y: c.y - corner, width: corner * 2, height: corner * 2), cursor: .crosshair)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let g = grab(at: p) {
            dragging = true
            if g == .move { NSCursor.closedHand.set() }
            onGrab?(g, p)
        } else if let o = others.last(where: { $0.rect.contains(p) }) {
            onPickOther?(o.index)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        onDrag?(convert(event.locationInWindow, from: nil), event.modifierFlags.contains(.shift))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        onRelease?()
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        for o in others {
            let path = NSBezierPath(rect: o.rect.insetBy(dx: 0.5, dy: 0.5))
            path.setLineDash([5, 4], count: 2, phase: 0)
            path.lineWidth = 1
            NSColor.white.withAlphaComponent(0.45).setStroke()
            path.stroke()
        }
        guard let r = box else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if angle != 0 {
            let t = NSAffineTransform()
            t.translateX(by: r.midX, yBy: r.midY)
            t.rotate(byRadians: angle)
            t.translateX(by: -r.midX, yBy: -r.midY)
            t.concat()
        }
        if rotatable {
            let k = knob(r)
            let stem = NSBezierPath()
            stem.move(to: NSPoint(x: r.midX, y: r.minY)); stem.line(to: NSPoint(x: k.x, y: k.y + (k.y < r.minY ? 7 : -7)))
            stem.lineWidth = 1.5
            NSColor(srgbRed: 0.24, green: 0.80, blue: 0.78, alpha: 1).setStroke(); stem.stroke()
            let disc = NSBezierPath(ovalIn: NSRect(x: k.x - 7, y: k.y - 7, width: 14, height: 14))
            NSColor.white.setFill(); disc.fill()
            disc.lineWidth = 1.5; NSColor(srgbRed: 0.24, green: 0.80, blue: 0.78, alpha: 1).setStroke(); disc.stroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: k, radius: 3.5, startAngle: 30, endAngle: 300)
            arc.lineWidth = 1.3; NSColor.black.withAlphaComponent(0.75).setStroke(); arc.stroke()
        }
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = .zero
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        let accent = NSColor(srgbRed: 0.24, green: 0.80, blue: 0.78, alpha: 1)
        let outline = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1.5
        accent.setStroke()
        outline.stroke()
        // Corner handles: white squares with a teal edge.
        for c in corners(r) {
            let h = NSBezierPath(rect: NSRect(x: c.x - 5.5, y: c.y - 5.5, width: 11, height: 11))
            NSColor.white.setFill(); h.fill()
            h.lineWidth = 1.5; accent.setStroke(); h.stroke()
        }
        // Centre handle: a round move button with four arrows.
        let m = NSRect(x: r.midX - centre / 2, y: r.midY - centre / 2, width: centre, height: centre)
        let disc = NSBezierPath(ovalIn: m)
        NSColor.black.withAlphaComponent(0.55).setFill(); disc.fill()
        disc.lineWidth = 1.5; NSColor.white.setStroke(); disc.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let arrows = NSBezierPath()
        let cx = r.midX, cy = r.midY, a: CGFloat = 7.5, k: CGFloat = 3
        for (dx, dy) in [(0.0, -1.0), (0.0, 1.0), (-1.0, 0.0), (1.0, 0.0)] {
            let tip = NSPoint(x: cx + CGFloat(dx) * a, y: cy + CGFloat(dy) * a)
            arrows.move(to: NSPoint(x: cx, y: cy)); arrows.line(to: tip)
            arrows.move(to: NSPoint(x: tip.x - CGFloat(dx) * k + CGFloat(dy) * k, y: tip.y - CGFloat(dy) * k + CGFloat(dx) * k))
            arrows.line(to: tip)
            arrows.line(to: NSPoint(x: tip.x - CGFloat(dx) * k - CGFloat(dy) * k, y: tip.y - CGFloat(dy) * k - CGFloat(dx) * k))
        }
        arrows.lineWidth = 1.5
        arrows.lineCapStyle = .round
        arrows.lineJoinStyle = .round
        NSColor.white.setStroke()
        arrows.stroke()
    }
}

// MARK: The window side

extension PlayerWindowController {

    struct PlateDrag {
        let index: Int
        let id: String
        let grab: PlateHandlesView.Grab
        let start: NSPoint          // view point where the drag began
        let base: CGRect            // design space, before the user's size/nudge
        let pivot: CGPoint
        let scale: CGFloat
        let dx: CGFloat, dy: CGFloat
        let box: CGRect             // design space box at the start
        var newScale: CGFloat
        var newDX: CGFloat, newDY: CGFloat
    }

    func setUpPlateHandles() {
        guard let ov = playerView.contentOverlayView else { return }
        plateHandles.frame = ov.bounds
        plateHandles.autoresizingMask = [.width, .height]
        plateHandles.isHidden = true
        ov.addSubview(plateHandles)
        plateHandles.onGrab = { [weak self] g, p in self?.beginPlateDrag(g, at: p) }
        plateHandles.onDrag = { [weak self] p, shift in self?.continuePlateDrag(to: p, fine: shift) }
        plateHandles.onRelease = { [weak self] in self?.endPlateDrag() }
        plateHandles.onPickOther = { [weak self] i in
            guard let self else { return }
            self.graphicsPanel.select(i)
            self.updatePlateHandles()
        }
    }

    /// The video's picture inside the handles view, and design-space → view mapping.
    private func designToView() -> ((CGRect) -> NSRect, CGFloat)? {
        let size = player?.currentItem?.presentationSize ?? .zero
        guard size.width > 0, size.height > 0 else { return nil }
        let vb = plateHandles.convert(playerView.videoBounds, from: playerView)
        guard vb.width > 1, vb.height > 1 else { return nil }
        let s = min(size.width / PlateDrawing.W, size.height / PlateDrawing.H)
        let ox = (size.width - PlateDrawing.W * s) / 2, oy = (size.height - PlateDrawing.H * s) / 2
        let kx = vb.width / size.width, ky = vb.height / size.height
        let map: (CGRect) -> NSRect = { r in
            NSRect(x: vb.minX + (ox + r.minX * s) * kx, y: vb.minY + (oy + r.minY * s) * ky,
                   width: r.width * s * kx, height: r.height * s * ky)
        }
        return (map, s * kx)      // view points per design pixel
    }

    private func platePlacement(_ p: GraphicPlate) -> (base: CGRect, pivot: CGPoint)? {
        let key = [p.id, p.template, p.side ?? "", p.title ?? "", p.subtitle ?? "", p.kicker ?? "",
                   (p.items ?? []).joined(separator: "|"), p.style ?? ""].joined(separator: "§")
        if let hit = plateBoxCache[key] { return hit }
        guard let placed = PlateDrawing.placement(p) else { return nil }
        plateBoxCache[key] = placed
        if plateBoxCache.count > 64 { plateBoxCache.removeAll() }
        return placed
    }

    private func plateBox(_ p: GraphicPlate) -> CGRect? {
        guard let (base, pivot) = platePlacement(p) else { return nil }
        return PlateDrawing.placed(base, pivot: pivot, scale: CGFloat(p.scale ?? 1),
                                   dx: CGFloat(p.dx ?? 0), dy: CGFloat(p.dy ?? 0))
    }

    /// Shows the box for the plate on screen now (Graphics tab only). Cheap: call it freely.
    func updatePlateHandles() {
        guard plateDrag == nil else { return }
        let t = trimBar.playhead
        let onScreen = currentTab == .graphics ? graphics.indices.filter { i in
            let p = graphics[i]
            return t >= p.at && t < clipTimeFor(edited: edited(p.at) + p.length)
        } : []
        guard !onScreen.isEmpty, let (map, _) = designToView() else {
            if !plateHandles.isHidden { plateHandles.isHidden = true; plateHandles.box = nil; plateHandles.others = [] }
            return
        }
        let selected = graphicsPanel.selectedRow
        let active = selected.flatMap { onScreen.contains($0) ? $0 : nil } ?? onScreen.last!
        plateHandles.isHidden = false
        let box = plateBox(graphics[active]).map(map)
        if plateHandles.box != box { plateHandles.box = box }
        let others = onScreen.filter { $0 != active }.compactMap { i in plateBox(graphics[i]).map { (index: i, rect: map($0)) } }
        if plateHandles.others.map(\.rect) != others.map(\.rect) { plateHandles.others = others }
        if selected != active { graphicsPanel.select(active) }
    }

    func invalidatePlateBoxes() {
        plateBoxCache.removeAll()
        updatePlateHandles()
    }

    private func beginPlateDrag(_ grab: PlateHandlesView.Grab, at point: NSPoint) {
        guard let i = graphicsPanel.selectedRow, graphics.indices.contains(i),
              let (base, pivot) = platePlacement(graphics[i]) else { return }
        player?.pause()
        refreshStats = RefreshStats()
        let p = graphics[i]
        let s = CGFloat(p.scale ?? 1), dx = CGFloat(p.dx ?? 0), dy = CGFloat(p.dy ?? 0)
        let box = PlateDrawing.placed(base, pivot: pivot, scale: s, dx: dx, dy: dy)
        plateDrag = PlateDrag(index: i, id: p.id, grab: grab, start: point, base: base, pivot: pivot,
                              scale: s, dx: dx, dy: dy, box: box, newScale: s, newDX: dx, newDY: dy)
    }

    /// `fine`: Shift held — moves and resizes at a quarter speed for small adjustments.
    private func continuePlateDrag(to point: NSPoint, fine: Bool) {
        guard var d = plateDrag, let (map, perDesign) = designToView(), perDesign > 0 else { return }
        let k = (fine ? 0.25 : 1) / perDesign
        let delta = CGPoint(x: (point.x - d.start.x) * k, y: (point.y - d.start.y) * k)
        var box = d.box
        switch d.grab {
        case .move:
            d.newScale = d.scale
            d.newDX = d.dx + delta.x
            d.newDY = d.dy + delta.y
            box = box.offsetBy(dx: delta.x, dy: delta.y)
        case .corner(let c):
            // The opposite corner stays put; the size follows the mouse along the diagonal.
            let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                           CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)]
            let from = corners[c], fixed = corners[3 - c]
            let to = CGPoint(x: from.x + delta.x, y: from.y + delta.y)
            let diag = CGPoint(x: from.x - fixed.x, y: from.y - fixed.y)
            let len2 = diag.x * diag.x + diag.y * diag.y
            guard len2 > 1 else { return }
            var r = ((to.x - fixed.x) * diag.x + (to.y - fixed.y) * diag.y) / len2
            r = min(max(r, 0.25 / d.scale), 3.0 / d.scale)        // overall size 0.25…3
            d.newScale = d.scale * r
            let w = box.width * r, h = box.height * r
            box = CGRect(x: c % 2 == 0 ? fixed.x - w : fixed.x, y: c < 2 ? fixed.y - h : fixed.y, width: w, height: h)
            // The nudge that puts the newly sized plate exactly in that box.
            d.newDX = box.minX - d.pivot.x - d.newScale * (d.base.minX - d.pivot.x)
            d.newDY = box.minY - d.pivot.y - d.newScale * (d.base.minY - d.pivot.y)
        case .rotate:
            return      // plates don't turn
        }
        plateDrag = d
        plateHandles.box = map(box)
        // Live: move the plate's finished image (no redraw) from its old box to the new one.
        let r = box.width / max(1, d.box.width)
        let live = CGAffineTransform(translationX: box.minX, y: box.minY).scaledBy(x: r, y: r)
            .translatedBy(x: -d.box.minX, y: -d.box.minY)
        grade.graphics.setLive(d.id, live)
        refreshFrame()
    }

    private func endPlateDrag() {
        guard let d = plateDrag else { return }
        plateDrag = nil
        grade.graphics.setLive(nil)
        guard graphics.indices.contains(d.index), graphics[d.index].id == d.id else { refreshFrame(); return }
        var list = graphics
        let s = Double(d.newScale)
        list[d.index].scale = abs(s - 1) > 0.001 ? (s * 1000).rounded() / 1000 : nil
        list[d.index].dx = abs(d.newDX) > 0.5 ? Double(d.newDX).rounded() : nil
        list[d.index].dy = abs(d.newDY) > 0.5 ? Double(d.newDY).rounded() : nil
        setGraphics(list)                                   // redraws the plate sharp at its new size
        logRefreshStatsSoon("graphic drag")
        if let i = graphics.firstIndex(where: { $0.id == d.id }) {
            graphicsPanel.select(i)                         // also brings the Size/X/Y sliders up to date
        }
        updatePlateHandles()
    }
}

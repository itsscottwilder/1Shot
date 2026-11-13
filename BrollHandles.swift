// BrollHandles — 3.2: picture-in-picture B-roll, resized and moved right on the video
// (2026-11-12: "do the same thing with B-roll so we can effectively do picture in picture").
// In the B-roll tab, the shot on screen at the playhead gets the same box as graphics plates:
// drag a corner in to shrink a full-screen shot into a box over the talking head (the opposite
// corner stays put), drag the centre handle or inside the box to move it. Drag a corner back out
// to the full frame (within 3%) and the shot is full screen again. The box stays inside the frame.

import Cocoa

extension PlayerWindowController {

    struct BrollDrag {
        let index: Int
        let id: String
        let grab: PlateHandlesView.Grab
        let start: NSPoint
        let box: CGRect            // design space (1920×1080, y down) at the start
        var newBox: CGRect
    }

    private static let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    func setUpBrollHandles() {
        guard let ov = playerView.contentOverlayView else { return }
        brollHandles.frame = ov.bounds
        brollHandles.autoresizingMask = [.width, .height]
        brollHandles.isHidden = true
        ov.addSubview(brollHandles)
        brollHandles.onGrab = { [weak self] g, p in self?.beginBrollDrag(g, at: p) }
        brollHandles.onDrag = { [weak self] p, shift in self?.continueBrollDrag(to: p, fine: shift) }
        brollHandles.onRelease = { [weak self] in self?.endBrollDrag() }
    }

    /// A shot's box in design space: its PiP box, or the whole frame when full screen.
    private func brollBox(_ c: BrollClip) -> CGRect {
        let s = CGFloat(c.isPiP ? c.pipScale ?? 1 : 1)
        let cx = CGFloat(c.isPiP ? c.pipX ?? 960 : 960), cy = CGFloat(c.isPiP ? c.pipY ?? 540 : 540)
        return CGRect(x: cx - 960 * s, y: cy - 540 * s, width: 1920 * s, height: 1080 * s)
    }

    /// Design space → the handles view (the video's picture), and view points per design pixel.
    private func brollDesignToView() -> ((CGRect) -> NSRect, CGFloat)? {
        let size = player?.currentItem?.presentationSize ?? .zero
        guard size.width > 0, size.height > 0 else { return nil }
        let vb = brollHandles.convert(playerView.videoBounds, from: playerView)
        guard vb.width > 1, vb.height > 1 else { return nil }
        let s = min(size.width / 1920, size.height / 1080)
        let ox = (size.width - 1920 * s) / 2, oy = (size.height - 1080 * s) / 2
        let kx = vb.width / size.width, ky = vb.height / size.height
        return ({ r in NSRect(x: vb.minX + (ox + r.minX * s) * kx, y: vb.minY + (oy + r.minY * s) * ky,
                              width: r.width * s * kx, height: r.height * s * ky) }, s * kx)
    }

    /// Shows the box for the B-roll shot on screen now (B-roll tab only). Cheap: call it freely.
    func updateBrollHandles() {
        guard brollDrag == nil else { return }
        let t = trimBar.playhead
        let onScreen = currentTab == .broll ? broll.indices.filter { i in
            let c = broll[i]
            return c.file != nil && t >= c.at && t < clipTimeFor(edited: edited(c.at) + c.length)
        } : []
        guard let i = onScreen.first, let (map, _) = brollDesignToView() else {
            if !brollHandles.isHidden { brollHandles.isHidden = true; brollHandles.box = nil }
            return
        }
        brollHandles.isHidden = false
        let box = map(brollBox(broll[i]))
        if brollHandles.box != box { brollHandles.box = box }
        if brollPanel.selectedRow != i { brollPanel.select(i) }
    }

    private func beginBrollDrag(_ grab: PlateHandlesView.Grab, at point: NSPoint) {
        guard let i = brollPanel.selectedRow, broll.indices.contains(i) else { return }
        player?.pause()
        let box = brollBox(broll[i])
        brollDrag = BrollDrag(index: i, id: broll[i].id, grab: grab, start: point, box: box, newBox: box)
    }

    /// Keeps a box inside the frame.
    private func keepInFrame(_ r: CGRect) -> CGRect {
        let f = Self.frame
        var r = r
        r.origin.x = min(max(r.minX, f.minX), f.maxX - r.width)
        r.origin.y = min(max(r.minY, f.minY), f.maxY - r.height)
        return r
    }

    private func continueBrollDrag(to point: NSPoint, fine: Bool) {
        guard var d = brollDrag, let (map, perDesign) = brollDesignToView(), perDesign > 0 else { return }
        let k = (fine ? 0.25 : 1) / perDesign
        let delta = CGPoint(x: (point.x - d.start.x) * k, y: (point.y - d.start.y) * k)
        let b = d.box
        switch d.grab {
        case .move:
            d.newBox = keepInFrame(b.offsetBy(dx: delta.x, dy: delta.y))
        case .corner(let c):
            let corners = [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
                           CGPoint(x: b.minX, y: b.maxY), CGPoint(x: b.maxX, y: b.maxY)]
            let from = corners[c], fixed = corners[3 - c]
            let to = CGPoint(x: from.x + delta.x, y: from.y + delta.y)
            let diag = CGPoint(x: from.x - fixed.x, y: from.y - fixed.y)
            let len2 = diag.x * diag.x + diag.y * diag.y
            guard len2 > 1 else { return }
            let r = ((to.x - fixed.x) * diag.x + (to.y - fixed.y) * diag.y) / len2
            var s = min(1, max(0.15, b.width / 1920 * r))
            if s > 0.97 { s = 1 }                                  // snap back to full screen
            let w = 1920 * s, h = 1080 * s
            d.newBox = s == 1 ? Self.frame
                : keepInFrame(CGRect(x: c % 2 == 0 ? fixed.x - w : fixed.x, y: c < 2 ? fixed.y - h : fixed.y, width: w, height: h))
        }
        brollDrag = d
        brollHandles.box = map(d.newBox)
        let s = d.newBox.width / 1920
        grade.broll.setLive(d.id, s < 0.999 ? .init(scale: Double(s), x: Double(d.newBox.midX), y: Double(d.newBox.midY)) : nil)
        refreshFrame()
    }

    private func endBrollDrag() {
        guard let d = brollDrag else { return }
        brollDrag = nil
        grade.broll.setLive(nil)
        guard broll.indices.contains(d.index), broll[d.index].id == d.id else { refreshFrame(); return }
        var list = broll
        let s = Double(d.newBox.width / 1920)
        if s < 0.999 {
            list[d.index].pipScale = (s * 1000).rounded() / 1000
            list[d.index].pipX = Double(d.newBox.midX).rounded()
            list[d.index].pipY = Double(d.newBox.midY).rounded()
        } else {
            list[d.index].pipScale = nil; list[d.index].pipX = nil; list[d.index].pipY = nil
        }
        setBroll(list)
        if let i = broll.firstIndex(where: { $0.id == d.id }) { brollPanel.select(i) }
        saveProject()
        updateBrollHandles()
    }
}

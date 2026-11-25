// BrollHandles — 3.2: picture-in-picture B-roll, resized and moved right on the video
// (2026-11-12: "do the same thing with B-roll so we can effectively do picture in picture").
// In the B-roll tab, the shot on screen at the playhead gets the same box as graphics plates:
// drag a corner in to shrink a full-screen shot into a box over the talking head (the opposite
// corner stays put), drag the centre handle or inside the box to move it. Drag a corner back out
// to the full frame (within 3%) and the shot is full screen again. The box stays inside the frame.

import Cocoa
import AVFoundation
import ImageIO

extension PlayerWindowController {

    struct BrollDrag {
        let index: Int
        let id: String
        let grab: PlateHandlesView.Grab
        let start: NSPoint
        let box: CGRect            // design space (1920×1080, y down) at the start
        var newBox: CGRect
        // Whole pictures (3.8.0): placed freely — centre, size and turn.
        var whole = false
        var centre = CGPoint(x: 960, y: 540), scale = 1.0, rotation = 0.0
        var newCentre = CGPoint(x: 960, y: 540), newScale = 1.0, newRotation = 0.0
        var startCentreView = NSPoint.zero
    }

    /// The picture's pixel size (cached), for the whole-picture box.
    private static var pictureSizes: [String: CGSize] = [:]
    private func pictureSize(_ c: BrollClip) -> CGSize? {
        guard let url = brollURL(c) else { return nil }
        if let s = Self.pictureSizes[url.path] { return s }
        var size: CGSize?
        if c.isPhoto {
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
               let w = p[kCGImagePropertyPixelWidth] as? Double, let h = p[kCGImagePropertyPixelHeight] as? Double {
                let o = p[kCGImagePropertyOrientation] as? Int ?? 1
                size = o >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
            }
        } else if let t = AVURLAsset(url: url).tracks(withMediaType: .video).first {
            let r = CGRect(origin: .zero, size: t.naturalSize).applying(t.preferredTransform)
            size = CGSize(width: abs(r.width), height: abs(r.height))
        }
        if let size, size.width > 0, size.height > 0 { Self.pictureSizes[url.path] = size; return size }
        return nil
    }

    /// A whole picture's unturned box in design space, at a given centre, size and zoom.
    private func wholeBox(_ c: BrollClip, centre: CGPoint, scale: Double) -> CGRect? {
        guard let px = pictureSize(c) else { return nil }
        let k = min(1920 / px.width, 1080 / px.height) * CGFloat(scale * max(1, c.zoom ?? 1))
        let w = px.width * k, h = px.height * k
        return CGRect(x: centre.x - w / 2, y: centre.y - h / 2, width: w, height: h)
    }

    private func wholePlacement(_ c: BrollClip) -> (CGPoint, Double, Double) {
        (CGPoint(x: c.pipX ?? 960, y: c.pipY ?? 540), c.pipScale ?? 1, c.rotation ?? 0)
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
        let c = broll[i]
        if c.showsWhole {
            let (centre, scale, turn) = wholePlacement(c)
            if let b = wholeBox(c, centre: centre, scale: scale) {
                brollHandles.rotatable = true
                brollHandles.angle = CGFloat(turn * .pi / 180)
                let box = map(b)
                if brollHandles.box != box { brollHandles.box = box }
            }
        } else {
            brollHandles.rotatable = false
            brollHandles.angle = 0
            let box = map(brollBox(c))
            if brollHandles.box != box { brollHandles.box = box }
        }
        // Select its row, but only a row the list has: right after an Undo the clips are back
        // before the list is refreshed, and asking for a missing row deselects, which calls here
        // again (it looped until the stack ran out). The flag stops any other way back in.
        if brollPanel.selectedRow != i, i < brollPanel.rowCount, !selectingBrollRow {
            selectingBrollRow = true
            brollPanel.select(i)
            selectingBrollRow = false
        }
    }

    private func beginBrollDrag(_ grab: PlateHandlesView.Grab, at point: NSPoint) {
        guard let i = brollPanel.selectedRow, broll.indices.contains(i) else { return }
        player?.pause()
        refreshStats = RefreshStats()
        let c = broll[i]
        if c.showsWhole {
            let (centre, scale, turn) = wholePlacement(c)
            guard let b = wholeBox(c, centre: centre, scale: scale) else { return }
            var d = BrollDrag(index: i, id: c.id, grab: grab, start: point, box: b, newBox: b)
            d.whole = true
            d.centre = centre; d.scale = scale; d.rotation = turn
            d.newCentre = centre; d.newScale = scale; d.newRotation = turn
            if let (map, _) = brollDesignToView() { let v = map(b); d.startCentreView = NSPoint(x: v.midX, y: v.midY) }
            brollDrag = d
            return
        }
        let box = brollBox(c)
        brollDrag = BrollDrag(index: i, id: c.id, grab: grab, start: point, box: box, newBox: box)
    }

    /// Dragging a whole picture: move its centre, size it about its centre, or turn it.
    private func continueWholeDrag(_ d0: BrollDrag, to point: NSPoint, shift: Bool,
                                   map: (CGRect) -> NSRect, perDesign: CGFloat) {
        var d = d0
        guard broll.indices.contains(d.index) else { return }
        let c = broll[d.index]
        let cv = d.startCentreView
        switch d.grab {
        case .move:
            let k = (shift ? 0.25 : 1) / perDesign
            d.newCentre = CGPoint(x: min(1920, max(0, d.centre.x + (point.x - d.start.x) * k)),
                                  y: min(1080, max(0, d.centre.y + (point.y - d.start.y) * k)))
        case .corner:
            let r0 = hypot(d.start.x - cv.x, d.start.y - cv.y)
            guard r0 > 2 else { return }
            var ratio = Double(hypot(point.x - cv.x, point.y - cv.y) / r0)
            if shift { ratio = 1 + (ratio - 1) * 0.25 }
            var s = min(4, max(0.05, d.scale * ratio))
            if abs(s - 1) < 0.02 { s = 1 }                       // snap to "fits the frame"
            d.newScale = s
        case .rotate:
            let a0 = atan2(d.start.y - cv.y, d.start.x - cv.x)
            let a1 = atan2(point.y - cv.y, point.x - cv.x)
            var deg = d.rotation + Double(a1 - a0) * 180 / .pi
            deg = deg.truncatingRemainder(dividingBy: 360)
            if deg > 180 { deg -= 360 } else if deg < -180 { deg += 360 }
            if shift { deg = (deg / 15).rounded() * 15 }        // ⇧: 15° steps
            else if let snap = [-180.0, -90, 0, 90, 180].first(where: { abs(deg - $0) < 2 }) { deg = snap }
            d.newRotation = deg
        }
        brollDrag = d
        if let b = wholeBox(c, centre: d.newCentre, scale: d.newScale) {
            d.newBox = b
            brollDrag = d
            brollHandles.box = map(b)
        }
        brollHandles.angle = CGFloat(d.newRotation * .pi / 180)
        grade.broll.setLive(d.id, .init(scale: d.newScale, x: Double(d.newCentre.x), y: Double(d.newCentre.y), rotation: d.newRotation))
        refreshFrame()
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
        if d.whole { continueWholeDrag(d, to: point, shift: fine, map: map, perDesign: perDesign); return }
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
        case .rotate:
            return      // only whole pictures turn
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
        if d.whole {
            let sc = (d.newScale * 1000).rounded() / 1000
            let x = Double(d.newCentre.x).rounded(), y = Double(d.newCentre.y).rounded()
            let turn = (d.newRotation * 10).rounded() / 10
            list[d.index].pipScale = abs(sc - 1) < 0.001 ? nil : sc
            list[d.index].pipX = x == 960 ? nil : x
            list[d.index].pipY = y == 540 ? nil : y
            list[d.index].rotation = turn == 0 ? nil : turn
        } else if s < 0.999 {
            list[d.index].pipScale = (s * 1000).rounded() / 1000
            list[d.index].pipX = Double(d.newBox.midX).rounded()
            list[d.index].pipY = Double(d.newBox.midY).rounded()
        } else {
            list[d.index].pipScale = nil; list[d.index].pipX = nil; list[d.index].pipY = nil
        }
        setBroll(list)
        logRefreshStatsSoon("B-roll drag")
        if let i = broll.firstIndex(where: { $0.id == d.id }) { brollPanel.select(i) }
        saveProject()
        updateBrollHandles()
    }
}

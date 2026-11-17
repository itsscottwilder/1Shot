// TrimBar — an always-visible strip under the video: filmstrip thumbnails, a yellow
// trim frame with a handle at each end, a playhead you can click/drag to scrub,
// and Start / Length / End times underneath.

import Cocoa

final class TrimBar: NSView {
    static let height: CGFloat = 252   // 3.2: room for the A1 audio lane under V1 (3.3.3: A1 as tall as V1)

    // Model (seconds)
    var duration: Double = 0 {
        didSet {
            zoom = 1
            viewStart = 0
            relayout()
        }
    }
    var start: Double = 0 { didSet { relayout() } }
    var end: Double = 0 { didSet { relayout() } }
    var playhead: Double = 0 {
        didSet {
            guard abs(playhead - oldValue) > 0.001 else { return }
            needsDisplay = true
            followPlayhead()
        }
    }
    /// Pieces cut out of the middle (shown in red), the selected one, and a cut being marked (X key).
    var cuts: [Cut] = [] { didSet { relayout() } }
    var selectedCut: Int? { didSet { needsDisplay = true } }
    /// Boundaries between the original clips in an assembled A-roll, in timeline seconds.
    var sourceClipBoundaries: [Double] = [] { didSet { needsDisplay = true } }
    var sourceClipCount = 0 { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var onResizeSourceClip: ((Int, Bool, Double) -> Void)?
    private var sourceEdgeDelta: Double = 0
    private var hoveredSourceEdge: (index: Int, left: Bool)?
    private var sourceEdgeTracking: NSTrackingArea?

    /// DaVinci-style: show only the kept parts, end to end, as separate clips; each cut is an edit
    /// point between two clips. Off = the whole recording with the cuts in red.
    var clipView = true { didSet { relayout() } }
    /// Asset trimming keeps the whole source visible, regardless of the editing timeline preference.
    var showFullAsset = false { didSet { relayout() } }
    private var showsClips: Bool { clipView && !showFullAsset }
    private var layoutFrozen = false            // while an edge is dragged, the clips don't reflow
    private var segs: [(s: Double, e: Double)] = []
    private var shownLength: Double = 0.001
    private var dragOriginX: CGFloat = 0
    private var dragOriginValue: Double = 0

    private func relayout() {
        guard !layoutFrozen else { needsDisplay = true; return }
        if showsClips, duration > 0 {
            segs = CutList.keptSegments(start: start, end: end, cuts: cuts).map { (s: $0.0, e: $0.1) }
            if segs.isEmpty { segs = [(s: start, e: max(start, end))] }
        } else {
            segs = [(s: 0, e: duration)]
        }
        shownLength = max(0.001, segs.reduce(0) { $0 + ($1.e - $1.s) })
        clampView()
        syncZoomSlider()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// Clip time → place on the shown timeline (seconds). Times inside a cut land on its edit point;
    /// times before/after the kept parts extend past the ends (so a dragged trim handle can follow).
    private func shown(_ t: Double) -> Double {
        guard let first = segs.first, let last = segs.last else { return t }
        if t <= first.s { return t - first.s }
        var acc = 0.0
        for g in segs {
            if t <= g.e { return acc + max(0, t - g.s) }
            acc += g.e - g.s
        }
        return acc + (t - last.e)
    }

    /// Place on the shown timeline → clip time.
    private func clipTime(shown d: Double) -> Double {
        guard let first = segs.first, let last = segs.last else { return d }
        if d <= 0 { return first.s + d }
        var acc = 0.0
        for g in segs {
            let len = g.e - g.s
            if d <= acc + len { return g.s + (d - acc) }
            acc += len
        }
        return last.e + (d - acc)
    }
    var pendingCutStart: Double? { didSet { needsDisplay = true } }
    /// A cut was clicked (nil = clicked outside any cut).
    var onSelectCut: ((Int?) -> Void)?
    /// "Remove Cut" chosen from a cut's right-click menu.
    var onRemoveCut: ((Int) -> Void)?
    /// "Play Across Cut" chosen: play from just before the cut so you can hear the join.
    var onPlayAcrossCut: ((Int) -> Void)?
    /// Punch-in zooms, drawn as markers above the strip (blue = punch-in, purple = subscribe zoom,
    /// gray = back to normal) with a blue band under the zoomed-in stretches.
    var zoomMarks: [ZoomEvent] = [] { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    /// A zoom marker was dragged: (index, new time). Sent on mouse-up.
    var onMoveZoom: ((Int, Double) -> Void)?
    /// From a zoom marker's menu: (index, new scale), or nil scale to remove it.
    var onChangeZoom: ((Int, Double?) -> Void)?
    /// From the strip's menu: add a zoom at (time, scale).
    var onAddZoom: ((Double, Double) -> Void)?
    private var movingZoomAt: Double?
    private var menuTime: Double = 0

    /// A cut's edge was dragged to a new place: (index, resized cut). Sent on mouse-up.
    var onResizeCut: ((Int, Cut) -> Void)?

    /// (start, end, movingStartHandle, finished)
    var onTrimChanged: ((Double, Double, Bool, Bool) -> Void)?
    /// (time, finished)
    var onScrub: ((Double, Bool) -> Void)?

    private var thumbnails: [NSImage?] = []
    private enum Drag { case none, start, end, playhead, cutStart(Int), cutEnd(Int), sourceEdge(Int, Bool), pan(Double), zoomMark(Int), broll(Int, Int), graphics(Int, Int) }

    // MARK: V2 — B-roll track (above the clips)

    struct BrollBlock { var start: Double; var end: Double; var label: String; var photo: Bool; var pending: Bool }
    /// B-roll shots on V2 (clip times), set by the window.
    var brollBlocks: [BrollBlock] = [] { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }

    /// Motion graphics plates, shown as pink boxes on the V2 lane (under B-roll where they overlap).
    struct GraphicsBlock { var start: Double; var end: Double; var label: String; var fullScreen: Bool }
    var graphicsBlocks: [GraphicsBlock] = [] { didSet { needsDisplay = true } }
    // Visual Design selection (3.2): the clip picked on the timeline turns its group's colour.
    enum ClipPick { case aroll(Double), broll(Int) }
    enum ClipHighlight { case v1(start: Double, end: Double), broll(Int) }
    /// A click on a clip (V1 at a clip time, or a B-roll shot on V2).
    var onPickClip: ((ClipPick) -> Void)?
    var clipHighlight: (ClipHighlight, NSColor)? { didSet { needsDisplay = true } }

    private func drawV1Highlight(in strip: NSRect) {
        guard let (h, color) = clipHighlight, case .v1(let s, let e) = h else { return }
        let x0 = max(strip.minX, x(for: s)), x1 = min(strip.maxX, x(for: e))
        guard x1 > x0 else { return }
        let r = NSRect(x: x0, y: strip.minY, width: x1 - x0, height: strip.height)
        color.withAlphaComponent(0.32).setFill()
        r.fill(using: .sourceOver)
        color.setStroke()
        let path = NSBezierPath(rect: r.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 3
        path.stroke()
    }

    /// A plate was moved or trimmed on V2 (3.2): (index, new start, new end, part: 0 move / 1 left / 2 right), clip time.
    var onEditGraphics: ((Int, Double, Double, Int) -> Void)?
    private var graphicsDrag: (x0: CGFloat, start: Double, end: Double, sx: CGFloat, ex: CGFloat)?
    private var graphicsLive: (Int, Double, Double)?

    /// (plate index, part) for a point on V2 that isn't on a B-roll shot.
    private func graphicsHit(_ p: NSPoint) -> (Int, Int)? {
        guard laneRect.insetBy(dx: -8, dy: -2).contains(p) else { return nil }
        for (i, g) in graphicsBlocks.enumerated().reversed() {
            let r = NSRect(x: x(for: g.start), y: laneRect.minY, width: max(4, x(for: g.end) - x(for: g.start)), height: laneRect.height)
            guard r.insetBy(dx: -5, dy: 0).contains(p) else { continue }
            if abs(p.x - r.minX) <= 5 { return (i, 1) }
            if abs(p.x - r.maxX) <= 5 { return (i, 2) }
            return (i, 0)
        }
        return nil
    }

    static let brollColor = NSColor(srgbRed: 0.56, green: 0.60, blue: 0.98, alpha: 1)     // periwinkle
    static let graphicsColor = NSColor(srgbRed: 1.00, green: 0.45, blue: 0.72, alpha: 1)  // pink
    /// A shot was moved or trimmed: (index, new start, new end, part: 0 move / 1 left / 2 right), clip time.
    var onEditBroll: ((Int, Double, Double, Int) -> Void)?
    var onRemoveBroll: ((Int) -> Void)?
    /// Files dropped on the timeline: (files, clip time where they were dropped).
    var onDropBroll: (([URL], Double) -> Void)?
    private var brollDrag: (x0: CGFloat, start: Double, end: Double, sx: CGFloat, ex: CGFloat)?
    private var brollLive: (Int, Double, Double)?

    private var laneRect: NSRect { NSRect(x: stripRect.minX, y: 6, width: stripRect.width, height: 30) }

    private func brollBlockRect(_ b: BrollBlock) -> NSRect {
        NSRect(x: x(for: b.start), y: laneRect.minY, width: max(4, x(for: b.end) - x(for: b.start)), height: laneRect.height)
    }

    /// (block index, part): part 0 = body (move), 1 = left edge, 2 = right edge.
    private func brollHit(_ p: NSPoint) -> (Int, Int)? {
        guard laneRect.insetBy(dx: -8, dy: -2).contains(p) else { return nil }
        for (i, b) in brollBlocks.enumerated().reversed() {
            let r = brollBlockRect(b)
            guard r.insetBy(dx: -5, dy: 0).contains(p) else { continue }
            if abs(p.x - r.minX) <= 5 { return (i, 1) }
            if abs(p.x - r.maxX) <= 5 { return (i, 2) }
            return (i, 0)
        }
        return nil
    }

    private func drawBrollLane() {
        let lane = laneRect
        NSColor(white: 0.16, alpha: 1).setFill()
        NSBezierPath(roundedRect: lane, xRadius: 3, yRadius: 3).fill()
        let tag = NSAttributedString(string: "V2", attributes: [.font: NSFont.boldSystemFont(ofSize: 9),
                                                               .foregroundColor: NSColor(white: 0.5, alpha: 1)])
        tag.draw(at: NSPoint(x: lane.minX - 16, y: lane.midY - 6))
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: lane).addClip()
        for (gi, g0) in graphicsBlocks.enumerated() {
            var g = g0
            if let live = graphicsLive, live.0 == gi { g.start = live.1; g.end = live.2 }
            let r = NSRect(x: x(for: g.start), y: lane.minY, width: max(4, x(for: g.end) - x(for: g.start)), height: lane.height)
            Self.graphicsColor.withAlphaComponent(g.fullScreen ? 0.95 : 0.8).setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 1), xRadius: 4, yRadius: 4).fill()
            NSColor.white.withAlphaComponent(0.7).setStroke()
            NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 1), xRadius: 4, yRadius: 4).stroke()
            let text = NSAttributedString(string: (g.fullScreen ? "■ " : "") + g.label, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor(white: 0.08, alpha: 1)])
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: r.insetBy(dx: 4, dy: 0)).addClip()
            text.draw(at: NSPoint(x: r.minX + 5, y: r.midY - 7))
            NSGraphicsContext.restoreGraphicsState()
        }
        for (i, b0) in brollBlocks.enumerated() {
            var b = b0
            if let live = brollLive, live.0 == i { b.start = live.1; b.end = live.2 }
            let r = brollBlockRect(b)
            var fill = Self.brollColor
            if let (h, color) = clipHighlight, case .broll(let hi) = h, hi == i { fill = color }
            fill.withAlphaComponent(b.pending ? 0.35 : (b.photo ? 0.7 : 0.95)).setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 1), xRadius: 4, yRadius: 4).fill()
            NSColor.white.withAlphaComponent(0.7).setStroke()
            NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 1), xRadius: 4, yRadius: 4).stroke()
            let text = NSAttributedString(string: (b.pending ? "⤓ " : "") + b.label, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor(white: 0.08, alpha: 1)])
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: r.insetBy(dx: 4, dy: 0)).addClip()
            text.draw(at: NSPoint(x: r.minX + 5, y: r.midY - 7))
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        // The playhead runs through V2 too, down to the clips.
        let px = x(for: playhead)
        if px >= stripRect.minX - 1 && px <= stripRect.maxX + 1 {
            NSColor.white.setFill()
            NSRect(x: px - 1, y: lane.minY, width: 2, height: stripRect.minY - lane.minY).fill()
        }
    }

    @objc private func removeBrollChosen(_ sender: NSMenuItem) { onRemoveBroll?(sender.tag) }

    // Drag files from Finder onto the timeline to add your own B-roll.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                               options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty, duration > 0 else { return false }
        let p = convert(sender.draggingLocation, from: nil)
        onDropBroll?(urls, snapToFrame(time(atX: p.x)))
        return true
    }
    /// How close (in points) the mouse must be to a cut's edge to grab it.
    private let cutEdgeGrab: CGFloat = 5
    /// While an edge is dragged: the cut as it will be when you let go.
    private var resizing: Cut?
    private var drag: Drag = .none
    private let handleWidth: CGFloat = 12
    private let minLength: Double = 0.5

    // Zoom: 1 = the whole clip fits; higher = less time across the strip, so you can place
    // cut edges frame-accurately. viewStart is the clip time at the strip's left edge.
    private(set) var zoom: Double = 1
    private var viewStart: Double = 0
    private var visibleLength: Double { shownLength / zoom }
    /// Zoomed all the way in shows 5 ms across the strip — single audio samples on A1 (3.2;
    /// was 2 seconds).
    private var maxZoom: Double { max(1, shownLength / 0.005) }
    var visibleRange: (start: Double, end: Double) { (viewStart, viewStart + visibleLength) }

    private let zoomSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let zoomOutButton = NSButton()
    private let zoomInButton = NSButton()
    private let zoomControlsWidth: CGFloat = 170

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        setUpZoomControls()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpZoomControls()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let sourceEdgeTracking { removeTrackingArea(sourceEdgeTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        sourceEdgeTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let hit = sourceEdge(at: convert(event.locationInWindow, from: nil))
        if hoveredSourceEdge?.index != hit?.0 || hoveredSourceEdge?.left != hit?.1 {
            hoveredSourceEdge = hit.map { (index: $0.0, left: $0.1) }
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredSourceEdge = nil
        needsDisplay = true
    }

    private func setUpZoomControls() {
        zoomSlider.controlSize = .small
        zoomSlider.isContinuous = true
        zoomSlider.refusesFirstResponder = true   // keep Space / arrows working after you use it
        zoomSlider.target = self
        zoomSlider.action = #selector(zoomSliderMoved(_:))
        zoomSlider.toolTip = "Zoom the timeline (⌘+ / ⌘−, ⇧Z to fit, ⌥-scroll or pinch)"
        for (button, symbol, action, tip) in [
            (zoomOutButton, "minus.magnifyingglass", #selector(zoomOutClicked(_:)), "Zoom Out (⌘−)"),
            (zoomInButton, "plus.magnifyingglass", #selector(zoomInClicked(_:)), "Zoom In (⌘+)"),
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.contentTintColor = NSColor(white: 0.8, alpha: 1)
            button.refusesFirstResponder = true
            button.target = self
            button.action = action
            button.toolTip = tip
        }
        addSubview(zoomOutButton)
        addSubview(zoomSlider)
        addSubview(zoomInButton)
    }

    private var isDragging: Bool {
        if case .none = drag { return false }
        return true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let y = overviewRect.maxY + 2
        let right = stripRect.maxX
        zoomInButton.frame = NSRect(x: right - 18, y: y, width: 18, height: 18)
        zoomSlider.frame = NSRect(x: right - zoomControlsWidth + 22, y: y, width: zoomControlsWidth - 44, height: 18)
        zoomOutButton.frame = NSRect(x: right - zoomControlsWidth, y: y, width: 18, height: 18)
    }

    // MARK: Zoom

    func zoomIn() { setZoom(zoom * 1.6) }
    func zoomOut() { setZoom(zoom / 1.6) }
    func zoomToFit() { setZoom(1) }

    /// Changes zoom, keeping `anchor` (default: the playhead) at the same spot on screen.
    func setZoom(_ z: Double, around anchor: Double? = nil) {
        guard duration > 0 else { return }
        let newZoom = min(max(1, z), maxZoom)
        let a = shown(anchor ?? playhead)
        var frac = (a - viewStart) / visibleLength
        if !(0...1).contains(frac) { frac = 0.5 }   // playhead off screen: bring it to the middle
        zoom = newZoom
        viewStart = a - frac * visibleLength
        clampView()
        syncZoomSlider()
        viewChanged()
    }

    private func clampView() {
        viewStart = min(max(0, viewStart), max(0, shownLength - visibleLength))
    }

    private func viewChanged() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// The slider is logarithmic, so each bit of travel zooms by the same ratio.
    private func syncZoomSlider() {
        zoomSlider.doubleValue = maxZoom > 1 ? log(zoom) / log(maxZoom) : 0
        zoomSlider.isEnabled = maxZoom > 1
    }

    @objc private func zoomSliderMoved(_ sender: NSSlider) {
        setZoom(pow(maxZoom, sender.doubleValue))
    }
    @objc private func zoomInClicked(_ sender: Any?) { zoomIn() }
    @objc private func zoomOutClicked(_ sender: Any?) { zoomOut() }

    /// During playback, page the view along so the playhead never runs off the edge.
    private func followPlayhead() {
        guard zoom > 1, isPlaying, !isDragging else { return }
        let r = visibleRange
        let ph = shown(playhead)
        if ph < r.start || ph > r.end {
            viewStart = ph - visibleLength * 0.05
            clampView()
            viewChanged()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard duration > 0 else { return super.scrollWheel(with: event) }
        let p = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.option) {
            // ⌥-scroll zooms around the mouse, like DaVinci.
            let d = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
            setZoom(zoom * pow(1.01, Double(d)), around: time(atX: p.x))
            return
        }
        guard zoom > 1 else { return super.scrollWheel(with: event) }
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        var d = abs(dx) > abs(dy) ? dx : dy
        if !event.hasPreciseScrollingDeltas { d *= 10 }
        viewStart -= Double(d) * visibleLength / Double(stripRect.width)
        clampView()
        viewChanged()
    }

    override func magnify(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        setZoom(zoom * (1 + Double(event.magnification)), around: time(atX: p.x))
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func resetThumbnails(count: Int) {
        thumbnails = Array(repeating: nil, count: count)
        zoomThumbs.removeAll()
        requestedThumbs.removeAll()
        waveform = nil
        waveformRequested = false
        waveformGeneration += 1
        needsDisplay = true
    }

    // MARK: Display mode (3.0.0) — filmstrip everywhere except the Sound Design tab, which
    // shows the track's waveform instead. Geometry/hit-testing is unaffected either way.

    enum DisplayMode { case filmstrip, waveform }
    var displayMode: DisplayMode = .filmstrip { didSet { if displayMode != oldValue { needsDisplay = true } } }
    private var waveform: WaveformData?
    private var waveformRequested = false
    private var waveformGeneration = 0
    /// Asked once per clip for its waveform. Answer with setWaveform(_:generation:), passing the number back.
    var onNeedWaveform: ((Int) -> Void)?

    func setWaveform(_ data: WaveformData?, generation: Int) {
        guard generation == waveformGeneration else { return }   // an older clip's audio
        waveform = data
        data?.onChunkLoaded = { [weak self] in self?.needsDisplay = true }
        needsDisplay = true
    }

    /// True while the player is playing; the zoomed view only pages along with the playhead then.
    var isPlaying = false

    // Filmstrip tiles sit on a time grid, so they stretch and slide with the cuts as you zoom
    // and scroll. Frames for the tiles are fetched on demand, keyed by time in 1/100 s.
    private var zoomThumbs: [Int: NSImage] = [:]
    private var requestedThumbs: Set<Int> = []
    private var thumbRequestScheduled = false
    private var missingThumbs: Set<Int> = []
    private let tileWidth: CGFloat = 142   // 16:9 at the strip height
    /// Asked for frames at these times (key = seconds × 100). Answer with setThumbnail(_:forKey:).
    var onNeedThumbnails: (([Int]) -> Void)?

    func setThumbnail(_ image: CGImage, forKey key: Int) {
        if zoomThumbs.count > 800 { zoomThumbs.removeAll() }
        zoomThumbs[key] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        needsDisplay = true
    }

    /// A request was cancelled (you zoomed again first): allow asking for these again.
    func forgetThumbnailRequests(_ keys: [Int]) {
        requestedThumbs.subtract(keys)
    }

    func setThumbnail(_ image: CGImage, at index: Int) {
        guard thumbnails.indices.contains(index) else { return }
        thumbnails[index] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        needsDisplay = true
    }

    // MARK: Geometry

    private var stripRect: NSRect {
        NSRect(x: 20, y: 50, width: max(10, bounds.width - 40), height: 80)
    }

    private func x(for time: Double) -> CGFloat {
        guard duration > 0 else { return stripRect.minX }
        return stripRect.minX + CGFloat((shown(time) - viewStart) / visibleLength) * stripRect.width
    }

    private func time(atX x: CGFloat) -> Double {
        guard duration > 0 else { return 0 }
        let d = viewStart + Double((x - stripRect.minX) / stripRect.width) * visibleLength
        return min(max(clipTime(shown: d), 0), duration)
    }

    /// Thin bar under the strip: the whole clip, with the part you're zoomed into highlighted.
    private var overviewRect: NSRect {
        NSRect(x: stripRect.minX, y: audioLaneRect.maxY + 6, width: stripRect.width, height: 5)
    }

    /// A1: the audio waveform, under V1 on every tab (2026-11-11). As tall as V1 (3.3.3).
    private var audioLaneRect: NSRect {
        NSRect(x: stripRect.minX, y: stripRect.maxY + 4, width: stripRect.width, height: stripRect.height)
    }

    private var startHandleRect: NSRect {
        NSRect(x: x(for: start) - handleWidth, y: stripRect.minY - 3, width: handleWidth, height: stripRect.height + 6)
    }

    private var endHandleRect: NSRect {
        NSRect(x: x(for: end), y: stripRect.minY - 3, width: handleWidth, height: stripRect.height + 6)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.11, alpha: 1).setFill()
        bounds.fill()
        guard duration > 0 else { return }

        let strip = stripRect

        drawFilmstrip(in: strip)
        drawV1Highlight(in: strip)
        drawWaveform(in: audioLaneRect)

        // When zoomed, keep everything on the strip (plus room for the trim handles).
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: strip.insetBy(dx: -handleWidth, dy: -8)).addClip()

        // Show the target clip and edge before the user commits to a drag.
        let target: (index: Int, left: Bool)?
        if case .sourceEdge(let index, let left) = drag { target = (index, left) }
        else { target = hoveredSourceEdge }
        if let target, sourceClipCount > 0 {
            let edges = [0.0] + sourceClipBoundaries + [duration]
            if target.index >= 0, target.index + 1 < edges.count {
                let clipLeft = x(for: edges[target.index])
                let clipRight = x(for: edges[target.index + 1])
                let visible = NSRect(x: clipLeft, y: strip.minY, width: max(0, clipRight - clipLeft), height: strip.height).intersection(strip)
                if !visible.isEmpty {
                    NSColor.systemYellow.withAlphaComponent(0.18).setFill()
                    visible.fill()
                    let edgeX = target.left ? clipLeft : clipRight
                    NSColor.systemYellow.setFill()
                    let markerX = target.left ? edgeX : edgeX - 6
                    NSRect(x: markerX, y: strip.minY, width: 6, height: strip.height).fill()
                    let label = "Clip \(target.index + 1) · \(target.left ? "START" : "END")" as NSString
                    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 10), .foregroundColor: NSColor.white]
                    let size = label.size(withAttributes: attrs)
                    let boxWidth = size.width + 12
                    let boxX = min(max(strip.minX, target.left ? edgeX + 8 : edgeX - boxWidth - 8), strip.maxX - boxWidth)
                    let box = NSRect(x: boxX, y: strip.maxY - size.height - 9, width: boxWidth, height: size.height + 5)
                    NSColor.black.withAlphaComponent(0.85).setFill()
                    NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
                    label.draw(at: NSPoint(x: box.minX + 6, y: box.minY + 2), withAttributes: attrs)
                }
            }
        }

        // Dim what's trimmed away
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSRect(x: strip.minX, y: strip.minY, width: max(0, x(for: start) - strip.minX), height: strip.height).fill()
        NSRect(x: x(for: end), y: strip.minY, width: max(0, strip.maxX - x(for: end)), height: strip.height).fill()

        // Keep the source clips visibly distinct even though playback uses one composition.
        for boundary in sourceClipBoundaries where boundary > start && boundary < end {
            if showsClips && cuts.contains(where: { boundary > $0.start && boundary < $0.end }) { continue }
            let edge = x(for: boundary)
            NSColor.systemYellow.setFill()
            NSRect(x: edge - 1.5, y: strip.minY, width: 3, height: strip.height).fill()
        }
        if case .sourceEdge(let index, let left) = drag {
            let edges = [0.0] + sourceClipBoundaries + [duration]
            let edgeIndex = left ? index : index + 1
            if edges.indices.contains(edgeIndex) {
                let edge = x(for: edges[edgeIndex]) + CGFloat(sourceEdgeDelta / visibleLength) * strip.width
                NSColor.systemYellow.setFill()
                NSRect(x: edge - 1, y: strip.minY, width: 2, height: strip.height).fill()
            }
        }

        if showsClips {
            // Clips: a thin outline around each kept part, and an edit point at each cut.
            for g in segs {
                let r = NSRect(x: x(for: g.s), y: strip.minY, width: x(for: g.e) - x(for: g.s), height: strip.height)
                guard r.width > 2 else { continue }
                NSColor.white.withAlphaComponent(0.35).setStroke()
                let outline = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 0.5), xRadius: 3, yRadius: 3)
                outline.lineWidth = 1
                outline.stroke()
            }
            for c in cuts where c.end > start && c.start < end {
                let ex = x(for: c.start)
                NSColor.systemYellow.setFill()
                NSRect(x: ex - 1.5, y: strip.minY, width: 3, height: strip.height).fill()
                NSColor.systemRed.setFill()
                NSRect(x: ex - 3, y: strip.maxY - 3, width: 6, height: 3).fill()
            }
        } else {
        // Cuts: red hatched regions; the selected one outlined in white.
        for (i, c) in cuts.enumerated() {
            let r = NSRect(x: x(for: c.start), y: strip.minY, width: max(2, x(for: c.end) - x(for: c.start)),
                           height: strip.height)
            NSColor.systemRed.withAlphaComponent(0.55).setFill()
            r.fill()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: r).addClip()
            NSColor.black.withAlphaComponent(0.35).setStroke()
            let hatch = NSBezierPath()
            let visible = r.intersection(strip.insetBy(dx: -r.height, dy: 0))
            var hx = visible.minX - r.height - (visible.minX - r.minX).truncatingRemainder(dividingBy: 6)
            while hx < visible.maxX {
                hatch.move(to: NSPoint(x: hx, y: r.maxY))
                hatch.line(to: NSPoint(x: hx + r.height, y: r.minY))
                hx += 6
            }
            hatch.lineWidth = 1
            hatch.stroke()
            NSGraphicsContext.restoreGraphicsState()
            if i == selectedCut {
                NSColor.white.setStroke()
                let outline = NSBezierPath(rect: r.insetBy(dx: -1, dy: -1))
                outline.lineWidth = 2
                outline.stroke()
            }
        }
        }
        // Dragging a cut edge: show where the edge is and how long the cut is now.
        if let c = resizing {
            var edgeTime = c.start
            if case .cutEnd = drag { edgeTime = c.end }
            NSColor.white.setFill()
            NSRect(x: x(for: edgeTime) - 1, y: strip.minY - 4, width: 2, height: strip.height + 8).fill()
            let label = "\(Self.format(edgeTime))  ·  cut \(String(format: "%.2f", c.length)) s" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let size = label.size(withAttributes: attrs)
            var lx = x(for: edgeTime) - size.width / 2
            lx = min(max(lx, strip.minX), strip.maxX - size.width - 8)
            let box = NSRect(x: lx - 4, y: strip.minY + 2, width: size.width + 8, height: size.height + 2)
            NSColor.black.withAlphaComponent(0.8).setFill()
            NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
            label.draw(at: NSPoint(x: box.minX + 4, y: box.minY + 1), withAttributes: attrs)
        }
        // Zooms: a band along the bottom of the strip while zoomed in, and a marker at each change.
        for (i, z) in zoomMarks.enumerated() {
            var at = z.at
            if case .zoomMark(let j) = drag, j == i, let m = movingZoomAt { at = m }
            let next = i + 1 < zoomMarks.count ? zoomMarks[i + 1].at : duration
            if z.scale > 1.001 {
                (z.scale >= ZoomList.ctaScale - 0.01 ? NSColor.systemPurple : NSColor.systemBlue)
                    .withAlphaComponent(0.85).setFill()
                NSRect(x: x(for: at), y: strip.maxY - 4, width: max(1, x(for: next) - x(for: at)), height: 4).fill()
            }
            let mx = x(for: at)
            let color: NSColor = z.scale >= ZoomList.ctaScale - 0.01 ? .systemPurple
                : (z.scale > 1.001 ? .systemBlue : NSColor(white: 0.75, alpha: 1))
            color.setFill()
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: mx - 5, y: strip.minY - 9))
            tri.line(to: NSPoint(x: mx + 5, y: strip.minY - 9))
            tri.line(to: NSPoint(x: mx, y: strip.minY - 1))
            tri.close()
            tri.fill()
            color.withAlphaComponent(0.6).setFill()
            NSRect(x: mx - 0.5, y: strip.minY, width: 1, height: strip.height).fill()
        }
        // A cut being marked: from the X press to the playhead.
        if let p = pendingCutStart {
            let a = min(p, playhead), b = max(p, playhead)
            let r = NSRect(x: x(for: a), y: strip.minY, width: max(2, x(for: b) - x(for: a)), height: strip.height)
            NSColor.systemRed.withAlphaComponent(0.3).setFill()
            r.fill()
            NSColor.systemRed.setFill()
            NSRect(x: x(for: p) - 1, y: strip.minY - 4, width: 2, height: strip.height + 8).fill()
        }

        // Yellow trim frame + handles
        let yellow = NSColor.systemYellow
        yellow.setFill()
        let frameTop = NSRect(x: x(for: start), y: strip.minY - 3, width: x(for: end) - x(for: start), height: 3)
        let frameBottom = NSRect(x: x(for: start), y: strip.maxY, width: x(for: end) - x(for: start), height: 3)
        frameTop.fill()
        frameBottom.fill()
        for handle in [startHandleRect, endHandleRect] {
            NSBezierPath(roundedRect: handle, xRadius: 3, yRadius: 3).fill()
            // grip line
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSRect(x: handle.midX - 1, y: handle.midY - 8, width: 2, height: 16).fill()
            yellow.setFill()
        }

        // Playhead
        let px = x(for: playhead)
        if px >= strip.minX - 1 && px <= strip.maxX + 1 {
            NSColor.white.setFill()
            NSRect(x: px - 1, y: strip.minY - 6, width: 2, height: strip.height + 12).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        // Overview bar (only when zoomed in)
        if zoom > 1.0001 {
            let o = overviewRect
            NSColor(white: 0.25, alpha: 1).setFill()
            NSBezierPath(roundedRect: o, xRadius: 2, yRadius: 2).fill()
            let oxShown: (Double) -> CGFloat = { o.minX + CGFloat($0 / self.shownLength) * o.width }
            let ox: (Double) -> CGFloat = { oxShown(self.shown($0)) }
            NSColor.systemRed.withAlphaComponent(0.8).setFill()
            for c in cuts { NSRect(x: ox(c.start), y: o.minY, width: max(1, ox(c.end) - ox(c.start)), height: o.height).fill() }
            let thumb = NSRect(x: oxShown(viewStart), y: o.minY - 1,
                               width: max(6, oxShown(viewStart + visibleLength) - oxShown(viewStart)), height: o.height + 2)
            NSColor.white.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: thumb, xRadius: 2, yRadius: 2).fill()
            NSColor.white.withAlphaComponent(0.8).setStroke()
            NSBezierPath(roundedRect: thumb, xRadius: 2, yRadius: 2).stroke()
            NSColor.white.setFill()
            NSRect(x: ox(playhead) - 0.5, y: o.minY - 1, width: 1, height: o.height + 2).fill()
        }

        drawBrollLane()

        // Times
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor(white: 0.8, alpha: 1)
        ]
        let textY = overviewRect.maxY + 4
        let left = NSAttributedString(string: "Start \(Self.format(start))", attributes: attrs)
        let cutTotal = CutList.totalLength(cuts)
        let lengthText = cutTotal > 0
            ? "Length \(Self.format(end - start - cutTotal))  (\(cuts.count) cut\(cuts.count == 1 ? "" : "s"), −\(Self.format(cutTotal)))"
            : "Length \(Self.format(end - start))"
        let middle = NSAttributedString(string: lengthText, attributes: attrs)
        let right = NSAttributedString(string: "End \(Self.format(end))", attributes: attrs)
        left.draw(at: NSPoint(x: strip.minX, y: textY))
        middle.draw(at: NSPoint(x: strip.midX - middle.size().width / 2, y: textY))
        right.draw(at: NSPoint(x: strip.maxX - zoomControlsWidth - 14 - right.size().width, y: textY))
    }

    private func drawFilmstrip(in strip: NSRect) {
        NSColor(white: 0.22, alpha: 1).setFill()
        strip.fill()
        guard !thumbnails.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: strip).addClip()
        // Seconds per tile: halves each time the zoom doubles, so tiles are 72–144 pt wide
        // and always line up with the same moments in the clip.
        let base = shownLength * Double(tileWidth / strip.width)
        let level = floor(log2(max(1, zoom)))
        let span = base / pow(2, level)
        let n = thumbnails.count
        let pps = Double(strip.width) / visibleLength          // points per second
        // Each clip gets its own run of tiles, starting fresh at its first frame.
        for g in segs {
            let gx0 = x(for: g.s), gx1 = x(for: g.e)
            guard gx1 > strip.minX, gx0 < strip.maxX, gx1 > gx0 else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: gx0, y: strip.minY, width: gx1 - gx0, height: strip.height)
                .intersection(strip)).addClip()
            let lo = max(g.s, g.s + (Double(strip.minX - gx0) / pps))
            let hi = min(g.e, g.s + (Double(strip.maxX - gx0) / pps))
            var k = Int(floor(lo / span))
            while Double(k) * span < hi {
                let t0 = Double(k) * span
                let mid = min(duration, t0 + span / 2)
                let key = Int((mid * 100).rounded())
                var image = zoomThumbs[key]
                if image == nil {
                    if !requestedThumbs.contains(key) { missingThumbs.insert(key) }
                    image = thumbnails[min(n - 1, max(0, Int(mid / duration * Double(n))))]   // placeholder
                }
                let x0 = gx0 + CGFloat((t0 - g.s) * pps)
                if let image {
                    drawAspectFill(image, in: NSRect(x: floor(x0), y: strip.minY, width: ceil(CGFloat(span * pps)) + 1,
                                                     height: strip.height))
                }
                k += 1
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        if !missingThumbs.isEmpty, !thumbRequestScheduled {
            thumbRequestScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.thumbRequestScheduled = false
                let keys = Array(self.missingThumbs)
                self.missingThumbs.removeAll()
                self.requestedThumbs.formUnion(keys)
                self.onNeedThumbnails?(keys)
            }
        }
    }

    /// The A1 lane: a teal waveform (2026-11-11: "more pleasing than that bland grey"),
    /// mirrored around the centre line, following the cuts like the filmstrip does.
    static let waveformColor = NSColor(srgbRed: 0.24, green: 0.80, blue: 0.78, alpha: 1)       // teal
    static let waveformPeakColor = NSColor(srgbRed: 0.62, green: 0.96, blue: 0.90, alpha: 1)   // pale aqua tips

    private func drawWaveform(in lane: NSRect) {
        NSColor(srgbRed: 0.07, green: 0.12, blue: 0.13, alpha: 1).setFill()
        NSBezierPath(roundedRect: lane, xRadius: 3, yRadius: 3).fill()
        let tag = NSAttributedString(string: "A1", attributes: [.font: NSFont.boldSystemFont(ofSize: 9),
                                                               .foregroundColor: NSColor(white: 0.5, alpha: 1)])
        tag.draw(at: NSPoint(x: lane.minX - 16, y: lane.midY - 6))
        guard let wf = waveform else {
            if !waveformRequested {
                waveformRequested = true
                onNeedWaveform?(waveformGeneration)
            }
            let note = NSAttributedString(string: "Reading audio…", attributes: [
                .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor(white: 0.45, alpha: 1)])
            note.draw(at: NSPoint(x: lane.minX + 8, y: lane.midY - 7))
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: lane).addClip()
        let midY = lane.midY
        let halfHeight = lane.height / 2 - 2
        if !drawSamples(wf, in: lane, midY: midY, half: halfHeight) {
            drawEnvelope(wf, in: lane, midY: midY, half: halfHeight)
        }
        NSColor.white.withAlphaComponent(0.08).setFill()
        NSRect(x: lane.minX, y: midY, width: lane.width, height: 0.5).fill()
        // The playhead runs through A1 too.
        let x0 = x(for: playhead)
        if x0 >= lane.minX - 1 && x0 <= lane.maxX + 1 {
            NSColor.white.setFill()
            NSRect(x: x0 - 1, y: lane.minY, width: 2, height: lane.height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Zoomed out: per device pixel, the true min/max of the samples under it (pale outer body)
    /// with the RMS inside it (solid core) — the DaVinci / Logic / Pro Tools look.
    private func drawEnvelope(_ wf: WaveformData, in lane: NSRect, midY: CGFloat, half: CGFloat) {
        let step = 1 / max(1, window?.backingScaleFactor ?? 2)
        let sr = WaveformData.sampleRate
        let secondsPerStep = visibleLength / Double(stripRect.width) * Double(step)
        var xs: [CGFloat] = [], tops: [CGFloat] = [], bottoms: [CGFloat] = [], rmsTop: [CGFloat] = [], rmsBottom: [CGFloat] = []
        let columns = Int(lane.width / step) + 2
        xs.reserveCapacity(columns); tops.reserveCapacity(columns); bottoms.reserveCapacity(columns)
        rmsTop.reserveCapacity(columns); rmsBottom.reserveCapacity(columns)
        let minThick = step * 0.5
        var px = lane.minX
        while px <= lane.maxX + step {
            let t0 = time(atX: px)
            var t1 = time(atX: px + step)
            if t1 <= t0 || t1 - t0 > secondsPerStep * 1.5 { t1 = t0 + secondsPerStep }   // across a cut
            let s0 = Int(t0 * sr), s1 = max(Int(t1 * sr), s0 + 1)
            let v = wf.summary(from: s0, to: s1) ?? (0, 0, 0)
            var top = midY - CGFloat(v.max) * half, bottom = midY - CGFloat(v.min) * half
            if bottom - top < minThick { top = (top + bottom) / 2 - minThick / 2; bottom = top + minThick }
            let r = CGFloat(v.rms) * half
            xs.append(px)
            tops.append(top); bottoms.append(bottom)
            rmsTop.append(max(top, midY - r)); rmsBottom.append(min(bottom, midY + r))
            px += step
        }
        guard xs.count > 1 else { return }
        func band(_ upper: [CGFloat], _ lower: [CGFloat]) -> NSBezierPath {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: xs[0], y: upper[0]))
            for i in 1..<xs.count { path.line(to: NSPoint(x: xs[i], y: upper[i])) }
            for i in stride(from: xs.count - 1, through: 0, by: -1) { path.line(to: NSPoint(x: xs[i], y: lower[i])) }
            path.close()
            return path
        }
        Self.waveformColor.withAlphaComponent(0.55).setFill()
        band(tops, bottoms).fill()
        Self.waveformColor.setFill()
        band(rmsTop, rmsBottom).fill()
    }

    /// Zoomed in past about one sample per device pixel: a line through the actual samples, filled
    /// down to zero, with a dot on each sample once they're 6 pt apart. False while the samples
    /// are still loading (the envelope is drawn meanwhile).
    private func drawSamples(_ wf: WaveformData, in lane: NSRect, midY: CGFloat, half: CGFloat) -> Bool {
        let sr = WaveformData.sampleRate
        let ptsPerSample = CGFloat(Double(stripRect.width) / (visibleLength * sr))
        let scale = max(1, window?.backingScaleFactor ?? 2)
        guard ptsPerSample * scale >= 0.75 else { return false }
        let first = Int(floor(time(atX: lane.minX) * sr)) - 1
        let last = Int(ceil(time(atX: lane.maxX) * sr)) + 1
        guard last > first, last - first < 20_000 else { return false }
        var points: [NSPoint?] = []
        points.reserveCapacity(last - first + 1)
        var prevX: CGFloat = -.greatestFiniteMagnitude
        for i in max(0, first)...min(wf.sampleCount - 1, max(0, last)) {
            let t = Double(i) / sr
            let px = x(for: t)
            // Samples inside a cut all land on its edge: leave a gap there instead of a scribble.
            if px - prevX < ptsPerSample * 0.25 { points.append(nil); continue }
            guard let v = wf.sample(i) else { return false }
            points.append(NSPoint(x: px, y: midY - CGFloat(v) * half))
            prevX = px
        }
        let line = NSBezierPath(), fill = NSBezierPath()
        var runStart: NSPoint?, runEnd: NSPoint?
        func closeRun() {
            if let a = runStart, let b = runEnd {
                fill.line(to: NSPoint(x: b.x, y: midY))
                fill.line(to: NSPoint(x: a.x, y: midY))
                fill.close()
            }
            runStart = nil; runEnd = nil
        }
        for p in points {
            guard let p else { closeRun(); continue }
            if runStart == nil {
                runStart = p
                line.move(to: p)
                fill.move(to: NSPoint(x: p.x, y: midY))
                fill.line(to: p)
            } else {
                line.line(to: p)
                fill.line(to: p)
            }
            runEnd = p
        }
        closeRun()
        Self.waveformColor.withAlphaComponent(0.35).setFill()
        fill.fill()
        line.lineWidth = 1.25
        line.lineJoinStyle = .round
        Self.waveformPeakColor.setStroke()
        line.stroke()
        if ptsPerSample >= 6 {
            Self.waveformPeakColor.setFill()
            let r: CGFloat = min(2.5, ptsPerSample / 5)
            for case let p? in points {
                NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)).fill()
            }
        }
        return true
    }

    private func drawAspectFill(_ image: NSImage, in rect: NSRect) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let cropW = rect.width / scale
        let cropH = rect.height / scale
        let source = NSRect(x: (size.width - cropW) / 2, y: (size.height - cropH) / 2, width: cropW, height: cropH)
        image.draw(in: rect, from: source, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.medium.rawValue])
    }

    /// Frames per second of the open video (29.97 counts as 30, 59.94 as 60).
    static var frameRate: Double = 30

    static func format(_ seconds: Double) -> String {
        // Minutes:seconds:frames, e.g. 03:27:14. Minutes keep counting past 59.
        let fps = max(1, Int(frameRate.rounded()))
        let t = max(0, seconds.isFinite ? seconds : 0)
        // Tiny nudge so a time sitting exactly on a frame doesn't round down to the previous one.
        let totalFrames = Int((t * Double(fps) + 0.001).rounded(.down))
        let secs = totalFrames / fps
        return String(format: "%02d:%02d:%02d", secs / 60, secs % 60, totalFrames % fps)
    }

    /// Inverse of `format(_:)`: "MM:SS:FF", "SS:FF" or a bare number of seconds. nil if unparseable.
    static func parseTimecode(_ text: String) -> Double? {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        let fps = max(1, Int(frameRate.rounded()))
        switch parts.count {
        case 3: return parts[0] * 60 + parts[1] + parts[2] / Double(fps)
        case 2: return parts[0] + parts[1] / Double(fps)
        default: return parts[0]
        }
    }

    // MARK: Mouse

    /// The zoom marker under the mouse (the little triangles above the strip), if any.
    private func zoomMarkIndex(at p: NSPoint) -> Int? {
        guard duration > 0, p.y < stripRect.minY + 2, p.y > stripRect.minY - 12 else { return nil }
        var best: (Int, CGFloat)?
        for (i, z) in zoomMarks.enumerated() {
            let d = abs(p.x - x(for: z.at))
            if d <= 6, best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }

    /// The cut edge under the mouse, if any: (cut index, true = left edge).
    private func cutEdge(at p: NSPoint) -> (Int, Bool)? {
        guard duration > 0, stripRect.insetBy(dx: 0, dy: -4).contains(p) else { return nil }
        var best: (Int, Bool, CGFloat)?
        if showsClips {
            // An edit point: just left of it is the end of the clip before (the cut's start),
            // just right of it is the start of the clip after (the cut's end).
            for (i, c) in cuts.enumerated() where c.end > start && c.start < end {
                let d = p.x - x(for: c.start)
                if abs(d) <= cutEdgeGrab + 1, best == nil || abs(d) < best!.2 { best = (i, d < 0, abs(d)) }
            }
            return best.map { ($0.0, $0.1) }
        }
        for (i, c) in cuts.enumerated() {
            let left = abs(p.x - x(for: c.start)), right = abs(p.x - x(for: c.end))
            if left <= cutEdgeGrab, best == nil || left < best!.2 { best = (i, true, left) }
            if right <= cutEdgeGrab, best == nil || right < best!.2 { best = (i, false, right) }
        }
        return best.map { ($0.0, $0.1) }
    }

    private func snapToFrame(_ t: Double) -> Double {
        let fps = max(1, Self.frameRate)
        return (t * fps).rounded() / fps
    }

    /// New position for a dragged cut edge, kept inside the trim and clear of the neighbouring cuts.
    private func resized(_ i: Int, leftEdge: Bool, to t: Double) -> Cut {
        var c = cuts[i]
        let minCut = max(CutList.minimumLength, 1 / max(1, Self.frameRate))
        let t = snapToFrame(t)
        if leftEdge {
            let floor = max(start, i > 0 ? cuts[i - 1].end + 0.02 : 0)
            c.start = min(max(t, floor), c.end - minCut)
        } else {
            let ceiling = min(end, i + 1 < cuts.count ? cuts[i + 1].start - 0.02 : duration)
            c.end = max(min(t, ceiling), c.start + minCut)
        }
        return c
    }

    private func cutIndex(at p: NSPoint) -> Int? {
        guard stripRect.insetBy(dx: 0, dy: -8).contains(p) else { return nil }
        if showsClips {
            var best: (Int, CGFloat)?
            for (i, c) in cuts.enumerated() where c.end > start && c.start < end {
                let d = abs(p.x - x(for: c.start))
                if d <= 7, best == nil || d < best!.1 { best = (i, d) }
            }
            return best?.0
        }
        let t = time(atX: p.x)
        // A little slack so very short cuts are still easy to hit.
        let slack = Double(4 / max(stripRect.width, 1)) * visibleLength
        return cuts.firstIndex { t >= $0.start - slack && t <= $0.end + slack }
    }

    /// Right-click (or Control-click) a red cut: remove it, or play across it.
    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        if let z = zoomMarkIndex(at: p) { return zoomMenu(for: z) }
        if let hit = brollHit(p) {
            let i = hit.0
            let b = brollBlocks[i]
            let menu = NSMenu()
            let header = NSMenuItem(title: "B-roll \(Self.format(b.start)) – \(Self.format(b.end)) · \(b.label)",
                                    action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())
            let remove = NSMenuItem(title: "Remove B-roll", action: #selector(removeBrollChosen(_:)), keyEquivalent: "")
            remove.target = self
            remove.tag = i
            menu.addItem(remove)
            menu.autoenablesItems = false
            return menu
        }
        guard let i = cutIndex(at: p) else {
            guard stripRect.insetBy(dx: 0, dy: -12).contains(p) else { return nil }
            // Empty part of the strip: add a zoom here.
            menuTime = snapToFrame(time(atX: p.x))
            let menu = NSMenu()
            let header = NSMenuItem(title: "At \(Self.format(menuTime))", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())
            for (title, scale) in [("Add Punch-In Here (128%)", ZoomList.punchScale),
                                   ("Add Subscribe Zoom Here (140%)", ZoomList.ctaScale),
                                   ("Add Back-to-Normal Here (100%)", 1.0)] {
                let item = NSMenuItem(title: title, action: #selector(addZoomChosen(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = scale
                menu.addItem(item)
            }
            menu.autoenablesItems = false
            return menu
        }
        selectedCut = i
        onSelectCut?(i)
        let c = cuts[i]
        let menu = NSMenu()
        var title = "Cut \(Self.format(c.start)) – \(Self.format(c.end))  (\(String(format: "%.1f", c.length)) s)"
        if let reason = c.reason { title += " · \(reason)" }
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if let note = c.note, !note.isEmpty {
            let n = NSMenuItem(title: note, action: nil, keyEquivalent: "")
            n.isEnabled = false
            menu.addItem(n)
        }
        menu.addItem(.separator())
        let remove = NSMenuItem(title: "Remove Cut (keep this part)", action: #selector(removeCutChosen(_:)), keyEquivalent: "")
        remove.target = self
        remove.tag = i
        menu.addItem(remove)
        let play = NSMenuItem(title: "Play Across Cut", action: #selector(playAcrossChosen(_:)), keyEquivalent: "")
        play.target = self
        play.tag = i
        menu.addItem(play)
        menu.autoenablesItems = false
        return menu
    }

    private func zoomMenu(for i: Int) -> NSMenu {
        let z = zoomMarks[i]
        let menu = NSMenu()
        var title = "Zoom at \(Self.format(z.at)) · \(Int((z.scale * 100).rounded()))%"
        if let reason = z.reason { title += " · \(reason)" }
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if let words = z.words, !words.isEmpty {
            let w = NSMenuItem(title: "“\(words)”", action: nil, keyEquivalent: "")
            w.isEnabled = false
            menu.addItem(w)
        }
        menu.addItem(.separator())
        for (title, scale) in [("Punch-In (128%)", ZoomList.punchScale),
                               ("Subscribe Zoom (140%)", ZoomList.ctaScale),
                               ("Back to Normal (100%)", 1.0)] {
            let item = NSMenuItem(title: title, action: #selector(changeZoomChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.representedObject = scale
            item.state = abs(z.scale - scale) < 0.01 ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let remove = NSMenuItem(title: "Remove Zoom", action: #selector(removeZoomChosen(_:)), keyEquivalent: "")
        remove.target = self
        remove.tag = i
        menu.addItem(remove)
        menu.autoenablesItems = false
        return menu
    }

    @objc private func changeZoomChosen(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? Double { onChangeZoom?(sender.tag, s) }
    }
    @objc private func removeZoomChosen(_ sender: NSMenuItem) { onChangeZoom?(sender.tag, nil) }
    @objc private func addZoomChosen(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? Double { onAddZoom?(menuTime, s) }
    }

    @objc private func removeCutChosen(_ sender: NSMenuItem) { onRemoveCut?(sender.tag) }
    @objc private func playAcrossChosen(_ sender: NSMenuItem) { onPlayAcrossCut?(sender.tag) }

    override func resetCursorRects() {
        guard duration > 0 else { return }
        let visible = stripRect.insetBy(dx: -handleWidth - 4, dy: -8)
        let addCursorRect: (NSRect, NSCursor) -> Void = { r, c in
            let r = r.intersection(visible)
            if !r.isEmpty { self.addCursorRect(r, cursor: c) }
        }
        addCursorRect(startHandleRect.insetBy(dx: -4, dy: 0), .resizeLeftRight)
        addCursorRect(endHandleRect.insetBy(dx: -4, dy: 0), .resizeLeftRight)
        if sourceClipCount > 0 {
            for t in [0.0] + sourceClipBoundaries + [duration] {
                addCursorRect(NSRect(x: x(for: t) - 8, y: stripRect.minY, width: 16, height: stripRect.height), .resizeLeftRight)
            }
        }
        for b in brollBlocks {
            let r = brollBlockRect(b)
            addCursorRect(NSRect(x: r.minX - 5, y: r.minY, width: 10, height: r.height), .resizeLeftRight)
            addCursorRect(NSRect(x: r.maxX - 5, y: r.minY, width: 10, height: r.height), .resizeLeftRight)
        }
        for z in zoomMarks {
            addCursorRect(NSRect(x: x(for: z.at) - 6, y: stripRect.minY - 12, width: 12, height: 13), .openHand)
        }
        // Each red cut's left and right edge can be grabbed and dragged.
        let s = stripRect
        for c in cuts {
            for t in [c.start, c.end] {
                addCursorRect(NSRect(x: x(for: t) - cutEdgeGrab, y: s.minY - 4,
                                     width: cutEdgeGrab * 2, height: s.height + 8), .resizeLeftRight)
            }
        }
    }

    private func sourceEdge(at point: NSPoint) -> (Int, Bool)? {
        guard sourceClipCount > 0, stripRect.contains(point) else { return nil }
        let edges = [0.0] + sourceClipBoundaries + [duration]
        guard edges.count == sourceClipCount + 1 else { return nil }
        for i in 0..<sourceClipCount {
            let left = edges[i], right = edges[i + 1]
            let lx = x(for: left), rx = x(for: right)
            if left >= start - 0.001, point.x >= lx, point.x < min(lx + 8, rx),
               !cuts.contains(where: { left > $0.start && left < $0.end }) { return (i, true) }
            if right <= end + 0.001, point.x <= rx, point.x > max(rx - 8, lx),
               !cuts.contains(where: { right > $0.start && right < $0.end }) { return (i, false) }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        guard duration > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        if zoom > 1.0001, overviewRect.insetBy(dx: 0, dy: -3).contains(p) {
            // Grab the highlighted window in the overview bar and slide it.
            let t = Double((p.x - overviewRect.minX) / overviewRect.width) * shownLength
            let r = visibleRange
            let offset = (r.start...r.end).contains(t) ? t - r.start : visibleLength / 2
            drag = .pan(offset)
            viewStart = t - offset
            clampView()
            viewChanged()
            return
        }
        dragOriginX = p.x
        if let hit = brollHit(p) {
            let i = hit.0
            let b = brollBlocks[i]
            drag = .broll(i, hit.1)
            brollDrag = (p.x, b.start, b.end, x(for: b.start), x(for: b.end))
            brollLive = (i, b.start, b.end)
            onPickClip?(.broll(i))
            return
        }
        if let hit = graphicsHit(p) {
            let g = graphicsBlocks[hit.0]
            drag = .graphics(hit.0, hit.1)
            graphicsDrag = (p.x, g.start, g.end, x(for: g.start), x(for: g.end))
            graphicsLive = (hit.0, g.start, g.end)
            return
        }
        // Visual Design: any click on V1 picks that clip's design group, including clicks that land
        // on a clip edge, trim handle, zoom marker or cut edge (those still start their drag below).
        if stripRect.insetBy(dx: 0, dy: -8).contains(p) {
            onPickClip?(.aroll(time(atX: p.x)))
        }
        if let edge = sourceEdge(at: p) {
            drag = .sourceEdge(edge.0, edge.1)
            sourceEdgeDelta = 0
            layoutFrozen = true
        } else if startHandleRect.insetBy(dx: -6, dy: -4).contains(p) {
            drag = .start
            dragOriginValue = start
            layoutFrozen = true
        } else if endHandleRect.insetBy(dx: -6, dy: -4).contains(p) {
            drag = .end
            dragOriginValue = end
            layoutFrozen = true
        } else if let i = zoomMarkIndex(at: p) {
            drag = .zoomMark(i)
            movingZoomAt = zoomMarks[i].at
        } else if let edge = cutEdge(at: p) {
            let i = edge.0
            drag = edge.1 ? .cutStart(i) : .cutEnd(i)
            resizing = cuts[i]
            dragOriginValue = edge.1 ? cuts[i].start : cuts[i].end
            layoutFrozen = true
            selectedCut = i
            onSelectCut?(i)
        } else if stripRect.insetBy(dx: 0, dy: -8).contains(p) || laneRect.insetBy(dx: 0, dy: -4).contains(p)
                    || audioLaneRect.insetBy(dx: 0, dy: -2).contains(p) {
            // Click anywhere on the clips or the empty part of V2 to move the playhead.
            drag = .playhead
            playhead = time(atX: p.x)
            let hit = cutIndex(at: p)
            selectedCut = hit
            onSelectCut?(hit)
            onScrub?(playhead, false)
            onPickClip?(.aroll(playhead))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if case .pan(let offset) = drag {
            viewStart = Double((p.x - overviewRect.minX) / overviewRect.width) * shownLength - offset
            clampView()
            viewChanged()
            return
        }
        // Dragging past either end of a zoomed strip scrolls it.
        if zoom > 1, isDragging {
            let s = stripRect
            if p.x < s.minX { viewStart -= Double(s.minX - p.x) / Double(s.width) * visibleLength * 0.5 }
            if p.x > s.maxX { viewStart += Double(p.x - s.maxX) / Double(s.width) * visibleLength * 0.5 }
            clampView()
            viewChanged()
        }
        let t = time(atX: p.x)
        // Clip view: edges move by how far the mouse moved (the clips don't reflow until you let go).
        let edgeT = showsClips ? dragOriginValue + Double(p.x - dragOriginX) * visibleLength / Double(stripRect.width) : t
        switch drag {
        case .sourceEdge:
            sourceEdgeDelta = Double(p.x - dragOriginX) * visibleLength / Double(stripRect.width)
            needsDisplay = true
        case .start:
            start = min(max(0, edgeT), end - minLength)
            onTrimChanged?(start, end, true, false)
        case .end:
            end = max(min(duration, edgeT), start + minLength)
            onTrimChanged?(start, end, false, false)
        case .playhead:
            playhead = t
            onScrub?(t, false)
        case .pan:
            break
        case .graphics(let i, let part):
            guard let d = graphicsDrag else { break }
            let dx = p.x - d.x0
            var s = d.start, e = d.end
            switch part {
            case 1: s = min(time(atX: d.sx + dx), e - 0.5)
            case 2: e = max(time(atX: d.ex + dx), s + 0.5)
            default:
                s = time(atX: d.sx + dx)
                e = s + (d.end - d.start)
            }
            graphicsLive = (i, snapToFrame(s), snapToFrame(e))
            needsDisplay = true
        case .broll(let i, let part):
            guard let d = brollDrag else { break }
            let dx = p.x - d.x0
            var s = d.start, e = d.end
            switch part {
            case 1: s = min(time(atX: d.sx + dx), e - 0.5)
            case 2: e = max(time(atX: d.ex + dx), s + 0.5)
            default:
                s = time(atX: d.sx + dx)
                e = s + (d.end - d.start)     // the app keeps the on-screen length when it's applied
            }
            brollLive = (i, snapToFrame(s), snapToFrame(e))
            needsDisplay = true
        case .zoomMark(let i):
            guard zoomMarks.indices.contains(i) else { break }
            let lo = i > 0 ? zoomMarks[i - 1].at + 0.1 : 0
            let hi = i + 1 < zoomMarks.count ? zoomMarks[i + 1].at - 0.1 : duration
            movingZoomAt = min(max(snapToFrame(t), lo), hi)
            needsDisplay = true
        case .cutStart(let i), .cutEnd(let i):
            guard cuts.indices.contains(i) else { break }
            var isLeft = false
            if case .cutStart = drag { isLeft = true }
            let c = resized(i, leftEdge: isLeft, to: edgeT)
            resizing = c
            cuts[i] = c          // draw it live; the player is rebuilt when you let go
        case .none:
            break
        }
    }

    /// True when the mouse came up where it went down (a click, not a drag).
    private func clicked(_ event: NSEvent) -> Bool {
        abs(convert(event.locationInWindow, from: nil).x - dragOriginX) < 3
    }

    /// Puts the playhead one frame into a block, so its shot or plate is on screen.
    private func snapPlayhead(to t: Double) {
        playhead = min(duration, max(0, t + 1.0 / 30))
        needsDisplay = true
        onScrub?(playhead, true)
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .sourceEdge(let index, let left):
            if abs(sourceEdgeDelta) > 0.001 { onResizeSourceClip?(index, left, sourceEdgeDelta) }
            sourceEdgeDelta = 0
        case .start: onTrimChanged?(start, end, true, true)
        case .end: onTrimChanged?(start, end, false, true)
        case .playhead: onScrub?(playhead, true)
        case .cutStart(let i), .cutEnd(let i):
            if let c = resizing { onResizeCut?(i, c) }
        case .zoomMark(let i):
            if let m = movingZoomAt, zoomMarks.indices.contains(i), abs(m - zoomMarks[i].at) > 0.001 { onMoveZoom?(i, m) }
            movingZoomAt = nil
        case .broll(let i, let part):
            // A click (no drag) snaps the playhead to the shot's start (2026-11-12).
            if clicked(event), brollBlocks.indices.contains(i) {
                snapPlayhead(to: brollBlocks[i].start)
            } else if let live = brollLive, live.0 == i { onEditBroll?(i, live.1, live.2, part) }
            brollDrag = nil
            brollLive = nil
        case .graphics(let i, let part):
            if clicked(event), graphicsBlocks.indices.contains(i) {
                snapPlayhead(to: graphicsBlocks[i].start)
            } else if let live = graphicsLive, live.0 == i { onEditGraphics?(i, live.1, live.2, part) }
            graphicsDrag = nil
            graphicsLive = nil
        case .pan, .none: break
        }
        resizing = nil
        drag = .none
        if layoutFrozen {
            layoutFrozen = false
            relayout()
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }
}

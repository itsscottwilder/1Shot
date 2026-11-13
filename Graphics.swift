// Motion graphics (V3): plates drawn over the edit, in a playful look.
// Black, white and red. Arial Black stickers tilted a few degrees with hard drop shadows, a red marker
// swiping in behind the key word, red scribbles that draw on, and pieces that pop in with a bounce.
// Mark the key word in any text with asterisks: "People are *people.*".
//
// One renderer draws every plate. The color stage composites it over each frame after color, zoom
// and B-roll (so plates are never zoomed or graded), for the preview and the export alike.
// Plates are laid out on a 1920×1080 design and scaled to the video's size.

import Cocoa
import CoreText
import CoreImage
import AVFoundation
import Vision

// MARK: - The plate

struct GraphicPlate: Codable, Equatable {
    var id = UUID().uuidString
    var at: Double                 // start, original-clip seconds
    var length: Double             // seconds on screen
    var template: String           // see GraphicsTemplates.all
    var kicker: String? = nil      // small red label: "PART 2", "TIP", "EPISODE 04"
    var title: String? = nil
    var subtitle: String? = nil
    var items: [String]? = nil     // bullets / bar sections
    var side: String? = nil        // overlays: which side the TEXT goes ("left" default, or "right")
    var style: String? = nil       // bullets and keyword: "clean" (default) or "panel"
    var build: Bool? = nil         // bullets / top bar: items appear one at a time
    var builds: [Double]? = nil    // original-clip seconds each item appears (from the transcript)
    var current: Int? = nil        // top bar: highlighted section (0-based) when not building
    var avoid: [Double]? = nil     // the speaker's face [x, y, w, h] in the 1920×1080 design (found by the app)
    var overFace: Bool? = nil      // true = may cover his face on purpose (a comedic beat)
    var scale: Double? = nil       // The user's size tweak for this plate (1 = automatic size)
    var dx: Double? = nil          // nudge right (+) / left (−), design px (1920 wide)
    var dy: Double? = nil          // nudge down (+) / up (−), design px (1080 tall)
    var words: String? = nil       // what the speaker says there (for the record)
    var reason: String? = nil

    var isFullScreen: Bool { GraphicsTemplates.find(template)?.fullScreen ?? false }
}


struct GraphicsTemplate {
    let name: String
    let fullScreen: Bool
    let fields: String
    let example: [String: Any]
}

enum GraphicsTemplates {
    static let all: [GraphicsTemplate] = [
        .init(name: "lowerThird", fullScreen: false,
              fields: "title (handle), subtitle (tagline). Tilted name sticker + tagline sticker pop in; a red arrow draws toward the speaker. side = where the stickers sit (left default).",
              example: ["title": "@yourchannel", "subtitle": "Your tagline here", "side": "left"]),
        .init(name: "tip", fullScreen: false,
              fields: "kicker (red label, default TIP), title (*word* gets a red underline drawn under it). A white note with red tape slides in. side.",
              example: ["kicker": "THE ADVICE", "title": "Start your camera *anywhere*", "side": "left"]),
        .init(name: "bullets", fullScreen: false,
              fields: "title (black sticker; *word* red), items (≤4, ≤6 words; each a tilted white sticker with a red number that pops in), side, style clean|panel (panel adds a dark see-through panel), build true + builds [clip seconds per item] to pop each in on its word.",
              example: ["title": "Creative *ruts*", "items": ["Same clothes", "Same desk", "Same *setup*"], "side": "left", "build": true]),
        .init(name: "keyword", fullScreen: false,
              fields: "title (a short line; words pop in one by one beside the speaker; *marked* words get the red marker swipe), subtitle (optional sticker under it, as wide as the title), side, style clean|panel (panel puts it on a rounded black box). Use this instead of a full-screen statement.",
              example: ["title": "People are *people.*", "side": "left"]),
        .init(name: "circle", fullScreen: false,
              fields: "kicker (small line above), title (the big word: slams in and a red scribble circles it), side.",
              example: ["kicker": "Change your", "title": "surroundings", "side": "left"]),
        .init(name: "ring", fullScreen: false,
              fields: "No text. A red hand-drawn ring draws itself around a spot on screen (a control, the pointer, a number) to point it out. It's centered on the frame: place it with dx/dy (px from the center of a 1920×1080 frame, +dx right, +dy down) and size it with scale (1 = 220×160). Never moved to clear the speaker's face. Use snapshot_frame to find the spot.",
              example: ["dx": 212, "dy": 256, "scale": 1]),
        .init(name: "stamp", fullScreen: false,
              fields: "title (1 word: TRUE. / MYTH! / YES.), subtitle (optional caption sticker), side. A red rubber stamp slams on.",
              example: ["title": "TRUE.", "subtitle": "Every guru says it", "side": "left"]),
        .init(name: "subscribe", fullScreen: false,
              fields: "title (button text, default SUBSCRIBE), subtitle (caption sticker), side. Red button pops, a cursor bobs and clicks it.",
              example: ["title": "SUBSCRIBE", "subtitle": "It helps the algorithm", "side": "left"]),
        .init(name: "bigNumberOverlay", fullScreen: false,
              fields: "title (the number, e.g. −14; slams in with red burst lines), subtitle (unit sticker, e.g. LUFS), kicker (caption line). Real numbers only. side.",
              example: ["title": "−14", "subtitle": "LUFS", "kicker": "How loud YouTube plays every video", "side": "left"]),
        .init(name: "topBar", fullScreen: false,
              fields: "items (sections), current or build + builds. Bar across the top. Only when the speaker fills the frame.",
              example: ["items": ["Picture", "Sound", "Location"], "current": 1]),
        .init(name: "statement", fullScreen: true,
              fields: "FULL SCREEN, big moments only (1–2 per video). title: words slam in one by one; *marked* phrase gets the red marker.",
              example: ["title": "YouTube can be a *tough slog.*"]),
        .init(name: "title", fullScreen: true,
              fields: "FULL SCREEN opener. kicker (small sticker), title (\\n for a new line; words slam in; *marked* gets the marker).",
              example: ["kicker": "THE BIG IDEA", "title": "Start before\\nyou're *ready*"]),
        .init(name: "chapter", fullScreen: true,
              fields: "FULL SCREEN section break. kicker (PART 2 sticker), title (1–2 words, slams in, red underline draws), subtitle (gray line).",
              example: ["kicker": "PART 2", "title": "Sound", "subtitle": "Why bad audio loses viewers"]),
        .init(name: "bigNumber", fullScreen: true,
              fields: "FULL SCREEN number. title (number, slams in with burst), subtitle (unit sticker), kicker (caption). Real numbers only.",
              example: ["title": "−14", "subtitle": "LUFS", "kicker": "How loud YouTube plays every video"])
    ]

    static func find(_ name: String) -> GraphicsTemplate? {
        all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

// MARK: - Renderer (used by the color stage, preview and export)
//
// Each plate is a list of elements (stickers, words, marker swipes, scribbles). Each element is drawn
// once into its own picture, then animated per frame: pop (bounce in), slam (drop from big), swipe
// (red marker wipes in), draw (scribble reveals left to right), slide (note slides in), fade.

final class GraphicsRenderer {
    static let fadeOut = 0.25

    private struct Rendered {
        let image: CIImage
        let px: CGRect          // pixel rect in the frame (Core Image coords, y up)
        let anchor: CGPoint     // pixel anchor for scaling
        let elem: PlateDrawing.Elem
    }

    private let lock = NSLock()
    private var _plates: [GraphicPlate] = []
    private var _cuts: [Cut] = []
    private var _red: CGColor = GraphicsStyle.red
    private var cache: [String: [Rendered]] = [:]
    private var cacheOrder: [String] = []

    /// While a plate is dragged on screen (3.2): its rendered parts moved/scaled by this design-space
    /// transform, so the drag is live without redrawing the plate. Cleared when the drag ends.
    private var _live: (id: String, transform: CGAffineTransform)?
    func setLive(_ id: String?, _ transform: CGAffineTransform = .identity) {
        lock.lock(); _live = id.map { ($0, transform) }; lock.unlock()
    }

    func update(plates: [GraphicPlate], cuts: [Cut], red: CGColor) {
        lock.lock()
        _plates = plates; _cuts = cuts; _red = red
        cache.removeAll(); cacheOrder.removeAll()
        lock.unlock()
    }

    /// The graphics for clip time `t` over a frame of `extent`, or nil when none is on.
    func image(at t: Double, extent: CGRect) -> CIImage? {
        let tune = GraphicsTuningStore.current
        lock.lock(); let plates = _plates; let cuts = _cuts; let live = _live; lock.unlock()
        let red = GraphicsStyle.red
        _ = tune
        let edited = t - CutList.removed(before: t, cuts: cuts)
        var out: CIImage?
        for p in plates {
            let start = p.at - CutList.removed(before: p.at, cuts: cuts)
            let into = edited - start
            guard into >= 0, into < p.length else { continue }
            let rel: (Double) -> Double = { c in (c - CutList.removed(before: c, cuts: cuts)) - start }
            let move = live.flatMap { $0.id == p.id ? Self.pixelTransform($0.transform, extent: extent) : nil }
            guard let img = plateImage(p, into: into, extent: extent, red: red, rel: rel, move: move) else { continue }
            out = out.map { img.composited(over: $0) } ?? img
        }
        return out
    }

    /// A design-space (1920×1080, y down) transform as the same move in this frame's pixels (y up).
    static func pixelTransform(_ a: CGAffineTransform, extent: CGRect) -> CGAffineTransform {
        let W = extent.width, H = extent.height
        let s = min(W / PlateDrawing.W, H / PlateDrawing.H)
        let ox = (W - PlateDrawing.W * s) / 2, oy = (H - PlateDrawing.H * s) / 2
        let d = CGAffineTransform(a: s, b: 0, c: 0, d: -s, tx: extent.minX + ox, ty: extent.minY + H - oy)
        return d.inverted().concatenating(a).concatenating(d)
    }

    private func plateImage(_ p: GraphicPlate, into: Double, extent: CGRect, red: CGColor, rel: (Double) -> Double,
                            move: CGAffineTransform? = nil) -> CIImage? {
        let parts = rendered(p, extent: extent, red: red, rel: rel)
        let tune = GraphicsTuningStore.current
        let exit = max(0, min(1, (p.length - into) / max(0.01, tune.fadeOutSeconds)))
        var out: CIImage?
        if p.isFullScreen {
            let a = CGFloat(min(1, into / 0.2) * exit)
            out = GraphicsRenderer.withAlpha(CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent), a)
        }
        for r in parts {
            let te = into - r.elem.at
            guard te >= 0 else { continue }
            guard var img = animate(r, te: te, alpha: CGFloat(exit), extent: extent, tune: tune) else { continue }
            if let move, !r.elem.fixed { img = img.transformed(by: move) }
            out = out.map { img.composited(over: $0) } ?? img
        }
        return out?.cropped(to: extent)
    }

    private func animate(_ r: Rendered, te: Double, alpha: CGFloat, extent: CGRect, tune: GraphicsTuning) -> CIImage? {
        var img = r.image
        var scale: CGFloat = 1, a: CGFloat = 1, reveal: CGFloat = 1, dx: CGFloat = 0, dy: CGFloat = 0
        func lerp(_ x: Double, _ y: Double, _ k: Double) -> Double { x + (y - x) * k }
        func easeOut(_ k: Double) -> Double { 1 - pow(1 - min(1, max(0, k)), 3) }
        switch r.elem.anim {
        case .pop:
            let k = te / max(0.05, tune.popSeconds)
            let s: Double
            if k < 0.5 { s = lerp(0, 1.18, easeOut(k / 0.5)) }
            else if k < 0.78 { s = lerp(1.18, 0.94, (k - 0.5) / 0.28) }
            else if k < 1 { s = lerp(0.94, 1, (k - 0.78) / 0.22) }
            else { s = 1 }
            scale = CGFloat(s); a = CGFloat(min(1, te / 0.12))
        case .slam:
            let k = te / max(0.05, tune.slamSeconds)
            let s: Double
            if k < 0.5 { s = lerp(2.6, 0.92, easeOut(k / 0.5)) }
            else if k < 0.75 { s = lerp(0.92, 1.04, (k - 0.5) / 0.25) }
            else if k < 1 { s = lerp(1.04, 1, (k - 0.75) / 0.25) }
            else { s = 1 }
            scale = CGFloat(s); a = CGFloat(min(1, te / 0.1))
        case .swipe:
            let k = min(1, te / max(0.05, tune.swipeSeconds))
            reveal = CGFloat(k < 0.5 ? 4 * k * k * k : 1 - pow(-2 * k + 2, 3) / 2)
        case .draw:
            reveal = CGFloat(easeOut(te / max(0.05, tune.drawSeconds)))
        case .slide:
            let k = te / max(0.05, tune.slideSeconds)
            let off: Double
            if k < 0.7 { off = lerp(-1.4, 0.06, easeOut(k / 0.7)) }
            else if k < 1 { off = lerp(0.06, 0, (k - 0.7) / 0.3) }
            else { off = 0 }
            dx = CGFloat(off) * r.px.width; a = CGFloat(min(1, te / 0.15))
        case .fade:
            a = CGFloat(min(1, te / 0.25))
        }
        switch r.elem.idle {
        case .none: break
        case .bob: dy += CGFloat(sin(te * 2 * .pi / 1.6)) * 14 * (r.px.width / max(1, r.elem.rect.width))
        case .press:
            let c = te.truncatingRemainder(dividingBy: 3)
            if c > 1.3 && c < 1.6 { scale *= 0.95 }
        }
        if reveal <= 0.001 { return nil }
        if reveal < 1 {
            img = img.cropped(to: CGRect(x: r.px.minX, y: r.px.minY, width: r.px.width * reveal, height: r.px.height))
        }
        if abs(scale - 1) > 0.001 {
            guard scale > 0.01 else { return nil }
            img = img.transformed(by: CGAffineTransform(translationX: -r.anchor.x, y: -r.anchor.y)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: r.anchor.x, y: r.anchor.y)))
        }
        if dx != 0 || dy != 0 { img = img.transformed(by: CGAffineTransform(translationX: dx, y: -dy)) }
        let total = a * alpha
        if total < 0.999 { img = Self.withAlpha(img, max(0, total)) }
        return img
    }

    private func rendered(_ p: GraphicPlate, extent: CGRect, red: CGColor, rel: (Double) -> Double) -> [Rendered] {
        // The style file's version is in the key, so editing Graphics Style.json redraws everything.
        let key = "\(p.id)|\(Int(extent.width))x\(Int(extent.height))|\(GraphicsTuningStore.version)|\(GraphicsStyle.redHex)"
        lock.lock()
        if let c = cache[key] { lock.unlock(); return c }
        lock.unlock()
        let W = extent.width, H = extent.height
        let s = min(W / PlateDrawing.W, H / PlateDrawing.H)
        let ox = (W - PlateDrawing.W * s) / 2, oy = (H - PlateDrawing.H * s) / 2
        var out: [Rendered] = []
        for e in PlateDrawing.elements(p, red: red, rel: rel) {
            guard let cg = PlateDrawing.renderElement(e, scale: s) else { continue }
            let px = CGRect(x: extent.minX + ox + e.rect.minX * s,
                            y: extent.minY + H - oy - e.rect.maxY * s,
                            width: CGFloat(cg.width), height: CGFloat(cg.height))
            let img = CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: px.minX, y: px.minY))
            let anchor = CGPoint(x: extent.minX + ox + e.anchor.x * s, y: extent.minY + H - oy - e.anchor.y * s)
            out.append(Rendered(image: img, px: px, anchor: anchor, elem: e))
        }
        lock.lock()
        cache[key] = out
        cacheOrder.append(key)
        if cacheOrder.count > 12 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
        lock.unlock()
        return out
    }

    static func withAlpha(_ img: CIImage, _ a: CGFloat) -> CIImage {
        img.applyingFilter("CIColorMatrix", parameters: [
            // Core Image's color filters work on unpremultiplied color, so only alpha changes.
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: a),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
    }
}

// MARK: - Drawing (Core Graphics + Core Text, thread-safe)

enum PlateDrawing {
    static let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    static let gray = CGColor(srgbRed: 0.75, green: 0.75, blue: 0.75, alpha: 1)
    static let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    static let W: CGFloat = 1920, H: CGFloat = 1080

    enum Anim { case pop, slam, swipe, draw, slide, fade }
    enum Idle { case none, bob, press }

    /// One animated piece of a plate, laid out in design space (1920×1080, origin top-left).
    struct Elem {
        var rect: CGRect               // everything it draws, margins included
        var anim: Anim
        var at: Double                 // on-screen seconds after the plate starts
        var anchor: CGPoint            // pops and slams scale around this point
        var idle: Idle = .none
        var fixed = false              // backgrounds (panels, bars): never moved to clear the face
        var aside = false              // pointers (arrows): move with the plate but may reach toward the face
        var draw: (Pen) -> Void
    }

    struct Pen {
        let ctx: CGContext
        let scale: CGFloat
    }

    /// One element as its own picture.
    static func renderElement(_ e: Elem, scale s: CGFloat) -> CGImage? {
        let w = Int((e.rect.width * s).rounded(.up)), h = Int((e.rect.height * s).rounded(.up))
        guard w > 0, h > 0, w < 16384, h < 16384, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: s, y: -s)
        ctx.translateBy(x: -e.rect.minX, y: -e.rect.minY)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.setShouldAntialias(true)
        e.draw(Pen(ctx: ctx, scale: s))
        return ctx.makeImage()
    }

    /// The whole plate, fully animated in, as one picture (for preview sheets).
    static func render(_ p: GraphicPlate, width: Int, height: Int, red: CGColor) -> CGImage? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if p.isFullScreen {
            ctx.setFillColor(black); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let s = min(CGFloat(width) / W, CGFloat(height) / H)
        let ox = (CGFloat(width) - W * s) / 2, oy = (CGFloat(height) - H * s) / 2
        ctx.translateBy(x: ox, y: CGFloat(height) - oy)
        ctx.scaleBy(x: s, y: -s)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let pen = Pen(ctx: ctx, scale: s)
        for e in elements(p, red: red, rel: { c in c - p.at }) { e.draw(pen) }
        return ctx.makeImage()
    }

    // MARK: Plates → elements

    /// The plate's elements, in order: the template's layout, the global size from Graphics Style.json,
    /// moved off the speaker's face, then the user's own per-plate size and nudge.
    static func elements(_ p: GraphicPlate, red: CGColor, rel: (Double) -> Double) -> [Elem] {
        let tune = GraphicsTuningStore.current
        let right = (p.side ?? "left") == "right"
        var out = layout(p, red: red, rel: rel)
        func pivot(_ u: CGRect) -> CGPoint {
            p.isFullScreen ? CGPoint(x: u.midX, y: u.midY) : CGPoint(x: right ? u.maxX : u.minX, y: u.midY)
        }
        let g = CGFloat(p.isFullScreen ? tune.fullScreenScale : tune.overlayScale)
        if abs(g - 1) > 0.001, let u = footprint(out) {
            let c = pivot(u)
            out = transform(out, CGAffineTransform(translationX: c.x, y: c.y).scaledBy(x: g, y: g).translatedBy(x: -c.x, y: -c.y))
        }
        // No face checks (2026-11-11): a plate goes exactly where its side, scale and dx/dy
        // put it. The user moves and resizes it from the Graphics tab when it needs it.
        let s = CGFloat(p.scale ?? 1), dx = CGFloat(p.dx ?? 0), dy = CGFloat(p.dy ?? 0)
        if abs(s - 1) > 0.001 || dx != 0 || dy != 0, let u = footprint(out) {
            let c = pivot(u)
            out = transform(out, CGAffineTransform(translationX: c.x + dx, y: c.y + dy).scaledBy(x: s, y: s).translatedBy(x: -c.x, y: -c.y))
        }
        return out
    }

    /// Where a plate sits before the user's own size/nudge (design space), and the point their size
    /// scales around. The plate's on-screen box is `placed(...)` of these.
    static func placement(_ p: GraphicPlate) -> (base: CGRect, pivot: CGPoint)? {
        var q = p
        q.scale = nil; q.dx = nil; q.dy = nil
        guard let u = footprint(elements(q, red: GraphicsStyle.red, rel: { $0 - q.at })) else { return nil }
        let right = (p.side ?? "left") == "right"
        let c = p.isFullScreen ? CGPoint(x: u.midX, y: u.midY) : CGPoint(x: right ? u.maxX : u.minX, y: u.midY)
        return (u, c)
    }

    /// The box a plate fills at this size and nudge (matches what elements() draws).
    static func placed(_ base: CGRect, pivot c: CGPoint, scale s: CGFloat, dx: CGFloat, dy: CGFloat) -> CGRect {
        CGRect(x: c.x + s * (base.minX - c.x) + dx, y: c.y + s * (base.minY - c.y) + dy,
               width: base.width * s, height: base.height * s)
    }

    /// the speaker's face (padded per Graphics Style.json: sides, hair, chin), in design space.
    static func faceRect(_ p: GraphicPlate, _ t: GraphicsTuning) -> CGRect? {
        guard let a = p.avoid, a.count == 4, a[2] > 0, a[3] > 0 else { return nil }
        let r = CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
        let sp = CGFloat(t.faceSidePad), tp = CGFloat(t.faceTopPad), ch = CGFloat(t.faceChinPad)
        return CGRect(x: r.minX - r.width * sp, y: r.minY - r.height * tp,
                      width: r.width * (1 + 2 * sp), height: r.height * (1 + tp + ch))
    }

    /// The part of the plate that moves (backgrounds and pointers excluded), in design space.
    static func footprint(_ elems: [Elem]) -> CGRect? {
        elems.filter { !$0.fixed && !$0.aside }.map { $0.rect }.reduce(CGRect?.none) { u, r in u.map { $0.union(r) } ?? r }
    }

    /// Every element but the backgrounds, moved by `t`.
    static func transform(_ elems: [Elem], _ t: CGAffineTransform) -> [Elem] {
        elems.map { e in
            guard !e.fixed else { return e }
            var m = e
            let draw = e.draw
            m.rect = e.rect.applying(t)
            m.anchor = e.anchor.applying(t)
            m.draw = { pen in
                pen.ctx.saveGState(); pen.ctx.concatenate(t); draw(pen); pen.ctx.restoreGState()
            }
            return m
        }
    }

    /// Moves the plate off the face, keeping it as big as possible. Three tries, biggest wins:
    /// beside the face (slid to the frame edge, shrunk only as much as needed), below the chin, above the head.
    static func fit(_ elems: [Elem], clearOf face: CGRect, right: Bool, tune: GraphicsTuning) -> [Elem] {
        guard let u = footprint(elems), u.intersects(face) else { return elems }
        let edge = CGFloat(tune.edge), gap = CGFloat(tune.gap)
        typealias Option = (scale: CGFloat, from: CGPoint, to: CGPoint)
        var options: [Option] = []
        let room = right ? (W - edge) - (face.maxX + gap) : (face.minX - gap) - edge
        options.append((min(1, room / u.width),
                        CGPoint(x: right ? u.maxX : u.minX, y: u.midY), CGPoint(x: right ? W - edge : edge, y: u.midY)))
        let below = (H - 40) - (face.maxY + gap)
        options.append((min(1, below / u.height, (W - 2 * edge) / u.width),
                        CGPoint(x: right ? u.maxX : u.minX, y: u.minY), CGPoint(x: right ? W - edge : edge, y: face.maxY + gap)))
        let above = (face.minY - gap) - 40
        options.append((min(1, above / u.height, (W - 2 * edge) / u.width),
                        CGPoint(x: right ? u.maxX : u.minX, y: u.maxY), CGPoint(x: right ? W - edge : edge, y: face.minY - gap)))
        let best = options.max { $0.scale < $1.scale }!
        let s = max(CGFloat(tune.minScale), best.scale)
        return transform(elems, CGAffineTransform(translationX: best.to.x, y: best.to.y).scaledBy(x: s, y: s)
            .translatedBy(x: -best.from.x, y: -best.from.y))
    }

    /// True when the plate still covers the face (after fitting and the user's tweaks).
    static func coversFace(_ p: GraphicPlate) -> Bool {
        guard !p.isFullScreen, p.overFace != true, let face = faceRect(p, GraphicsTuningStore.current),
              let u = footprint(elements(p, red: GraphicsStyle.red, rel: { $0 - p.at })) else { return false }
        return u.insetBy(dx: 20, dy: 20).intersects(face)
    }

    static func layout(_ p: GraphicPlate, red: CGColor, rel: (Double) -> Double) -> [Elem] {
        let k = Kit(red: red, right: (p.side ?? "left") == "right")
        switch p.template {
        case "lowerThird": return lowerThird(p, k)
        case "tip": return tip(p, k)
        case "bullets": return bullets(p, k, rel: rel)
        case "keyword": return keyword(p, k)
        case "circle": return circle(p, k)
        case "ring": return ring(p, k)
        case "stamp": return stamp(p, k)
        case "subscribe": return subscribe(p, k)
        case "bigNumberOverlay": return bigNumber(p, k, full: false)
        case "topBar": return topBar(p, k, rel: rel)
        case "statement": return statement(p, k)
        case "title": return titleCard(p, k)
        case "chapter": return chapter(p, k)
        case "bigNumber": return bigNumber(p, k, full: true)
        default: return []
        }
    }

    static func lowerThird(_ p: GraphicPlate, _ k: Kit) -> [Elem] {
        var out: [Elem] = []
        let name = k.sticker(p.title ?? "", size: 76, bg: black, fg: white, shadow: k.red, rot: -3, at: 0)
        let tag = p.subtitle.map { k.sticker($0, size: 34, bg: white, fg: black, shadow: black, rot: 2, at: 0.35, padX: 22, padY: 10) }
        let gap: CGFloat = 18
        let totalH = name.size.height + (tag.map { gap + $0.size.height } ?? 0)
        let top = H - 110 - totalH
        let x = k.right ? W - 140 - name.size.width : 140
        out.append(name.place(x: x, top: top))
        if let tag { out.append(tag.place(x: k.right ? W - 190 - tag.size.width : 190, top: top + name.size.height + gap)) }
        // Arrow drawn toward the speaker (the other side of the frame).
        let ax: CGFloat = k.right ? x - 280 : x + name.size.width + 20
        var arrow = k.arrow(from: CGPoint(x: k.right ? ax + 250 : ax, y: top + 40),
                            to: CGPoint(x: k.right ? ax + 20 : ax + 230, y: top - 90), at: 0.6)
        arrow.aside = true
        out.append(arrow)
        return out
    }

    static func tip(_ p: GraphicPlate, _ k: Kit) -> [Elem] {
        let w: CGFloat = 660, pad: CGFloat = 50
        let kick = PlateText.text((p.kicker ?? "TIP").uppercased(), size: 40, color: k.red, red: k.red, heavy: true, kern: 6)
        let body = PlateText.text(p.title ?? "", size: 72, color: black, red: black, heavy: true, width: w - pad * 2, lineHeight: 1.12)
        let h = 70 + kick.height + 18 + body.height + pad
        let x = k.right ? W - 150 - w : 150, top = (H - h) / 2 - 40
        let box = CGRect(x: x, y: top, width: w, height: h)
        var out: [Elem] = []
        out.append(Elem(rect: box.insetBy(dx: -70, dy: -70).offsetBy(dx: 7, dy: 7), anim: .slide, at: 0,
                        anchor: CGPoint(x: box.midX, y: box.midY)) { pen in
            k.rotated(pen, around: CGPoint(x: box.midX, y: box.midY), deg: k.right ? 4 : -4) {
                k.fill(pen, box.offsetBy(dx: 14, dy: 14), black)
                k.fill(pen, box, white)
                k.rotated(pen, around: CGPoint(x: box.midX, y: box.minY), deg: 3) {
                    k.fill(pen, CGRect(x: box.midX - 100, y: box.minY - 26, width: 200, height: 56), k.red)
                }
                kick.draw(pen, x: box.minX + pad, top: box.minY + 70)
                body.draw(pen, x: box.minX + pad, top: box.minY + 70 + kick.height + 18)
            }
        })
        // Red underline drawn under the *marked* words.
        if let r = body.markedRect {
            let ul = CGRect(x: box.minX + pad + r.minX - 10, y: box.minY + 70 + kick.height + 18 + r.maxY - 6, width: r.width + 20, height: 30)
            out.append(k.underline(ul, at: 0.7, rotateAround: CGPoint(x: box.midX, y: box.midY), deg: k.right ? 4 : -4))
        }
        return out
    }

    static func bullets(_ p: GraphicPlate, _ k: Kit, rel: (Double) -> Double) -> [Elem] {
        let items = Array((p.items ?? []).prefix(5))
        let building = p.build == true && (p.builds?.count ?? 0) >= 1
        var head = p.title.map { k.sticker($0, size: 92, bg: black, fg: white, shadow: white, rot: -3, at: 0) }
        let rows = items.enumerated().map { i, t -> Kit.Sticker in
            let at: Double = building ? max(0.2, rel(p.builds![min(i, p.builds!.count - 1)])) : 0.5 + 0.45 * Double(i)
            return k.numberSticker(i + 1, t, rot: [-2, 1.5, -1.5, 2, -1][i % 5], at: at)
        }
        let gap: CGFloat = 30
        let total = (head.map { $0.size.height + gap + 8 } ?? 0) + rows.reduce(0) { $0 + $1.size.height } + gap * CGFloat(max(0, rows.count - 1))
        var y = (H - total) / 2
        let widest = max(head?.size.width ?? 0, rows.map { $0.size.width }.max() ?? 0)
        let x0: CGFloat = k.right ? W - 130 - widest : 130
        var out: [Elem] = []
        if (p.style ?? "clean") == "panel" {
            let panel = CGRect(x: k.right ? W - 980 : 0, y: 0, width: 980, height: H)
            out.append(Elem(rect: panel, anim: .fade, at: 0, anchor: CGPoint(x: panel.midX, y: panel.midY), fixed: true) { pen in
                k.fill(pen, panel, CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.6))
            })
        }
        if head != nil {
            out.append(head!.place(x: k.right ? W - 130 - head!.size.width : x0, top: y))
            y += head!.size.height + gap + 8
            head = nil
        }
        for r in rows {
            out.append(r.place(x: k.right ? W - 130 - r.size.width : x0, top: y, anchorLeft: !k.right))
            y += r.size.height + gap
        }
        return out
    }

    static func keyword(_ p: GraphicPlate, _ k: Kit) -> [Elem] {
        let words = k.words(p.title ?? "", size: 150, maxWidth: 920, lineHeight: 1.08)
        // The caption sticker runs as wide as the title above it (2026-11-11), so it reads as
        // part of the graphic instead of a footnote. Its text grows to fit, up to 110 pt.
        let tagAt = 0.22 * Double(words.items.count) + 0.4
        let tag: Kit.Sticker? = p.subtitle.map { sub in
            let natural = PlateText.text(sub, size: 44, color: white, red: k.red, heavy: true, lineHeight: 1.05).width
            let size = max(44, min(110, 44 * (words.width - 52) / max(natural, 1)))
            return k.sticker(sub, size: size, bg: black, fg: white, shadow: white, rot: 3, at: tagAt,
                             padX: 26 * size / 44, padY: 12 * size / 44)
        }
        let total = words.height + (tag.map { 40 + $0.size.height } ?? 0)
        let top = (H - total) / 2
        let x: CGFloat = k.right ? W - 130 - words.width : 130
        var out: [Elem] = []
        if p.style == "panel" {
            // A rounded black box behind the words (2026-11-11): reads cleanly over busy screens.
            let pad: CGFloat = 56
            let box = CGRect(x: x - pad, y: top - pad,
                             width: max(words.width, tag?.size.width ?? 0) + pad * 2 + 12,
                             height: total + pad * 2 + 40)   // extra below: the red marker sits low
            out.append(Elem(rect: box, anim: .pop, at: 0, anchor: CGPoint(x: box.midX, y: box.midY)) { pen in
                let path = CGPath(roundedRect: box, cornerWidth: 44, cornerHeight: 44, transform: nil)
                pen.ctx.addPath(path); pen.ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.88)); pen.ctx.fillPath()
            })
        }
        out += words.elements(x: x, top: top, anim: .pop, start: 0, step: 0.22, shadow: true, markerDelay: 0.25)
        if let tag { out.append(tag.place(x: x, top: top + words.height + 40)) }
        return out
    }

    /// A red ring around a spot on screen (2026-11-11). Centered on the frame; dx/dy place it
    /// (the plate offset) and scale sizes it, so it lands exactly where it's told.
    static func ring(_ p: GraphicPlate, _ k: Kit) -> [Elem] {
        let r = CGRect(x: W / 2 - 110, y: H / 2 - 80, width: 220, height: 160)
        return [k.scribbleCircle(r, at: 0.05)]
    }

    static func circle(_ p: GraphicPlate, _ k: Kit) -> [Elem] {
        let small = p.kicker.map { k.words($0, size: 110, maxWidth: 1000, lineHeight: 1) }
        let big = k.words(p.title ?? "", size: 150, maxWidth: 1100, lineHeight: 1.2, marker: false)
        let gapBelowSmall: CGFloat = small == nil ? 0 : 50
        let total = (small?.height ?? 0) + gapBelowSmall + big.height
        let top = (H - total) / 2
        let x: CGFloat = k.right ? W - 110 - max(big.width, small?.width ?? 0) : 110
        var out: [Elem] = []
        if let small { out += small.elements(x: x, top: top, anim: .pop, start: 0, step: 0.15, shadow: true) }
        let bigTop = top + (small?.height ?? 0) + gapBelowSmall
        out += big.elements(x: x, top: bigTop, anim: .slam, start: 0.3, step: 0.12, shadow: true)
        let ring = CGRect(x: x - 40, y: bigTop - 12, width: big.width + 80, height: big.height + 24)
        out.append(k.scribbleCircle(ring, at: 0.75))
        return out
    }

    static func stamp(_ p: GraphicPlate, _ k: Kit) -> [Elem] {
        let word = PlateText.text((p.title ?? "TRUE.").uppercased(), size: 150, color: k.red, red: k.red, heavy: true, kern: 8, lineHeight: 1)
        let box = CGRect(x: 0, y: 0, width: word.width + 100 + 28, height: word.height + 40 + 28)
        let x: CGFloat = k.right ? W - 200 - box.width : 200
        let r = box.offsetBy(dx: x, dy: 300)
        var out: [Elem] = [Elem(rect: r.insetBy(dx: -90, dy: -90), anim: .slam, at: 0.1, anchor: CGPoint(x: r.midX, y: r.midY)) { pen in
            k.rotated(pen, around: CGPoint(x: r.midX, y: r.midY), deg: k.right ? 10 : -10) {
                let path = CGPath(roundedRect: r.insetBy(dx: 7, dy: 7), cornerWidth: 18, cornerHeight: 18, transform: nil)
                pen.ctx.addPath(path); pen.ctx.setStrokeColor(k.red); pen.ctx.setLineWidth(14); pen.ctx.strokePath()
                word.draw(pen, x: r.minX + 64, top: r.minY + 34)
            }
        }]
        if let sub = p.subtitle {
            let s = k.sticker(sub, size: 46, bg: black, fg: white, shadow: white, rot: 3, at: 0.6, padX: 26, padY: 12)
            out.append(s.place(x: k.right ? W - 240 - s.size.width : 240, top: r.maxY + 60))
        }
        return out
    }

    static func subscribe(_ p: GraphicPlate, _ k: Kit) -> [Elem] {
        let label = PlateText.text((p.title ?? "SUBSCRIBE").uppercased(), size: 80, color: white, red: white, heavy: true, kern: 4, lineHeight: 1)
        let bw = label.width + 128, bh = label.height + 60
        let x: CGFloat = k.right ? W - 180 - bw : 180
        let btn = CGRect(x: x, y: H - 200 - bh, width: bw, height: bh)
        var out: [Elem] = [Elem(rect: btn.insetBy(dx: -60, dy: -60).offsetBy(dx: 6, dy: 6), anim: .pop, at: 0,
                                anchor: CGPoint(x: btn.midX, y: btn.midY), idle: .press) { pen in
            k.rotated(pen, around: CGPoint(x: btn.midX, y: btn.midY), deg: -3) {
                let sh = CGPath(roundedRect: btn.offsetBy(dx: 12, dy: 12), cornerWidth: bh / 2, cornerHeight: bh / 2, transform: nil)
                pen.ctx.addPath(sh); pen.ctx.setFillColor(black); pen.ctx.fillPath()
                let b = CGPath(roundedRect: btn, cornerWidth: bh / 2, cornerHeight: bh / 2, transform: nil)
                pen.ctx.addPath(b); pen.ctx.setFillColor(k.red); pen.ctx.fillPath()
                label.draw(pen, x: btn.minX + 64, top: btn.minY + 30)
            }
        }]
        // Cursor bobbing over the button.
        let c = CGRect(x: btn.maxX - 70, y: btn.midY - 10, width: 130, height: 150)
        out.append(Elem(rect: c.insetBy(dx: -10, dy: -10), anim: .pop, at: 0.35, anchor: CGPoint(x: c.minX, y: c.minY), idle: .bob) { pen in
            let sx = c.width / 24, sy = c.height / 28
            let pts: [(CGFloat, CGFloat)] = [(4, 2), (4, 22), (9, 17), (12.5, 25), (16, 23.5), (12.5, 15.5), (19, 15.5)]
            pen.ctx.beginPath()
            for (i, pt) in pts.enumerated() {
                let q = CGPoint(x: c.minX + pt.0 * sx, y: c.minY + pt.1 * sy)
                if i == 0 { pen.ctx.move(to: q) } else { pen.ctx.addLine(to: q) }
            }
            pen.ctx.closePath()
            pen.ctx.setFillColor(white); pen.ctx.setStrokeColor(black); pen.ctx.setLineWidth(8); pen.ctx.setLineJoin(.round)
            pen.ctx.drawPath(using: .fillStroke)
        })
        if let sub = p.subtitle {
            let s = k.sticker(sub, size: 40, bg: white, fg: black, shadow: black, rot: 2, at: 0.5, padX: 24, padY: 10)
            out.append(s.place(x: k.right ? W - 190 - s.size.width : 190, top: btn.maxY + 40))
        }
        return out
    }

    static func bigNumber(_ p: GraphicPlate, _ k: Kit, full: Bool) -> [Elem] {
        let num = PlateText.text(p.title ?? "", size: full ? 340 : 300, color: white, red: k.red, heavy: true, lineHeight: 1)
        let unit = p.subtitle.map { k.sticker($0, size: 90, bg: white, fg: black, shadow: black, rot: -3, at: 0.4, padX: 30, padY: 8) }
        let cap = p.kicker.map { PlateText.text($0, size: 50, color: white, red: k.red, heavy: false, width: full ? 1600 : 900) }
        let total = num.height + (unit.map { 30 + $0.size.height } ?? 0) + (cap.map { 26 + $0.height } ?? 0)
        var y = (H - total) / 2
        let x: CGFloat = full ? (W - num.width) / 2 : (k.right ? W - 140 - num.width : 140)
        let nr = CGRect(x: x, y: y, width: num.width, height: num.height)
        var out: [Elem] = [Elem(rect: nr.insetBy(dx: -20, dy: -20).offsetBy(dx: 12, dy: 12), anim: .slam, at: 0, anchor: CGPoint(x: nr.midX, y: nr.midY)) { pen in
            num.draw(pen, x: nr.minX + 12, top: nr.minY + 12, flat: k.red)
            num.draw(pen, x: nr.minX, top: nr.minY)
        }]
        out.append(k.burst(center: CGPoint(x: nr.maxX + 60, y: nr.minY + 20), at: 0.5))
        y += num.height
        if let unit { y += 30; out.append(unit.place(x: full ? (W - unit.size.width) / 2 : x, top: y)); y += unit.size.height }
        if let cap {
            y += 26
            let cx = full ? (W - cap.width) / 2 : x
            let cy = y
            let cr = CGRect(x: cx, y: cy, width: cap.width, height: cap.height)
            out.append(Elem(rect: cr.insetBy(dx: -10, dy: -10).offsetBy(dx: 4, dy: 4), anim: .pop, at: 0.7, anchor: CGPoint(x: cr.minX, y: cr.midY)) { pen in
                cap.draw(pen, x: cx + 4, top: cy + 4, flat: black)
                cap.draw(pen, x: cx, top: cy)
            })
        }
        return out
    }

    static func statement(_ p: GraphicPlate, _ k: Kit) -> [Elem] {
        let words = k.words(p.title ?? "", size: 150, maxWidth: 1600, lineHeight: 1.15, center: true)
        return words.elements(x: (W - 1600) / 2, top: (H - words.height) / 2, anim: .slam, start: 0.15, step: 0.18, shadow: false, markerDelay: 0.25)
    }

    static func titleCard(_ p: GraphicPlate, _ k: Kit) -> [Elem] {
        let kick = p.kicker.map { k.sticker($0.uppercased(), size: 40, bg: k.red, fg: white, shadow: white, rot: -2, at: 0, padX: 26, padY: 10) }
        let words = k.words(p.title ?? "", size: 170, maxWidth: 1700, lineHeight: 1.1, center: true)
        let total = (kick.map { $0.size.height + 50 } ?? 0) + words.height
        var y = (H - total) / 2
        var out: [Elem] = []
        if let kick { out.append(kick.place(x: (W - kick.size.width) / 2, top: y)); y += kick.size.height + 50 }
        out += words.elements(x: (W - 1700) / 2, top: y, anim: .slam, start: 0.3, step: 0.18, shadow: false, markerDelay: 0.25)
        return out
    }

    static func chapter(_ p: GraphicPlate, _ k: Kit) -> [Elem] {
        let kick = p.kicker.map { k.sticker($0.uppercased(), size: 56, bg: k.red, fg: white, shadow: white, rot: -3, at: 0, padX: 30, padY: 12) }
        let big = PlateText.text(p.title ?? "", size: 260, color: white, red: k.red, heavy: true, lineHeight: 1)
        let sub = p.subtitle.map { PlateText.text($0, size: 50, color: gray, red: k.red, heavy: false, width: 1500) }
        let x: CGFloat = 200
        let total = (kick.map { $0.size.height + 30 } ?? 0) + big.height + 40 + (sub.map { 30 + $0.height } ?? 0)
        var y = (H - total) / 2
        var out: [Elem] = []
        if let kick { out.append(kick.place(x: x, top: y)); y += kick.size.height + 30 }
        let br = CGRect(x: x, y: y, width: big.width, height: big.height)
        out.append(Elem(rect: br.insetBy(dx: -10, dy: -10), anim: .slam, at: 0.3, anchor: CGPoint(x: br.midX, y: br.midY)) { pen in
            big.draw(pen, x: br.minX, top: br.minY)
        })
        y += big.height
        out.append(k.underline(CGRect(x: x - 10, y: y, width: big.width + 40, height: 40), at: 0.6))
        y += 40
        if let sub {
            let sy = y + 30
            out.append(Elem(rect: CGRect(x: x, y: sy, width: sub.width, height: sub.height).insetBy(dx: -6, dy: -6), anim: .pop, at: 0.9,
                            anchor: CGPoint(x: x, y: sy + sub.height / 2)) { pen in sub.draw(pen, x: x, top: sy) })
        }
        return out
    }

    static func topBar(_ p: GraphicPlate, _ k: Kit, rel: (Double) -> Double) -> [Elem] {
        let items = Array((p.items ?? []).prefix(6))
        guard !items.isEmpty else { return [] }
        let building = p.build == true && (p.builds?.isEmpty == false)
        var out: [Elem] = []
        let bar = CGRect(x: 0, y: 0, width: W, height: 140)
        out.append(Elem(rect: bar, anim: .fade, at: 0, anchor: CGPoint(x: bar.midX, y: bar.midY), fixed: true) { pen in
            k.fill(pen, bar, CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.75))
        })
        let labels = items.map { PlateText.text($0, size: 48, color: white, red: k.red, heavy: true) }
        let widths = labels.map { $0.width }
        let space = items.count > 1 ? ((W - 240) - widths.reduce(0, +)) / CGFloat(items.count - 1) : 0
        var x: CGFloat = items.count > 1 ? 120 : (W - widths[0]) / 2
        for (i, l) in labels.enumerated() {
            let at: Double = building ? max(0, rel(p.builds![min(i, p.builds!.count - 1)])) : 0.2 + 0.2 * Double(i)
            let r = CGRect(x: x, y: (140 - l.height) / 2, width: l.width, height: l.height)
            let isCurrent = !building && i == (p.current ?? -1)
            out.append(Elem(rect: r.insetBy(dx: -10, dy: -10), anim: .pop, at: at, anchor: CGPoint(x: r.midX, y: r.midY)) { pen in
                l.draw(pen, x: r.minX, top: r.minY, flat: isCurrent ? k.red : nil)
            })
            x += widths[i] + space
        }
        return out
    }

    // MARK: Kit (stickers, words, scribbles)

    struct Kit {
        let red: CGColor
        let right: Bool

        struct Sticker {
            let size: CGSize                     // the box (shadow not included)
            let make: (CGPoint, Bool) -> Elem    // top-left, anchor at left
            func place(x: CGFloat, top: CGFloat, anchorLeft: Bool = false) -> Elem { make(CGPoint(x: x, y: top), anchorLeft) }
        }

        /// Text on a tilted box with a hard drop shadow.
        func sticker(_ text: String, size: CGFloat, bg: CGColor, fg: CGColor, shadow: CGColor, rot: CGFloat, at: Double,
                     padX: CGFloat = 34, padY: CGFloat = 18) -> Sticker {
            let block = PlateText.text(text, size: size, color: fg, red: red, heavy: true, lineHeight: 1.05)
            let sz = CGSize(width: block.width + padX * 2, height: block.height + padY * 2)
            return Sticker(size: sz) { o, anchorLeft in
                let box = CGRect(origin: o, size: sz)
                let m = max(sz.width, sz.height) * 0.08 + 16
                let rect = CGRect(x: box.minX - m, y: box.minY - m, width: box.width + 2 * m + 12, height: box.height + 2 * m + 12)
                let anchor = anchorLeft ? CGPoint(x: box.minX, y: box.midY) : CGPoint(x: box.midX, y: box.midY)
                return Elem(rect: rect, anim: .pop, at: at, anchor: anchor) { pen in
                    rotated(pen, around: CGPoint(x: box.midX, y: box.midY), deg: rot) {
                        fill(pen, box.offsetBy(dx: 12, dy: 12), shadow)
                        fill(pen, box, bg)
                        block.draw(pen, x: box.minX + padX, top: box.minY + padY)
                    }
                }
            }
        }

        /// A white sticker with a red numbered circle.
        func numberSticker(_ n: Int, _ text: String, rot: CGFloat, at: Double) -> Sticker {
            let block = PlateText.text(text, size: 62, color: black, red: red, heavy: true, lineHeight: 1.05)
            let circle: CGFloat = 78, padL: CGFloat = 18, gap: CGFloat = 26, padR: CGFloat = 34
            let sz = CGSize(width: padL + circle + gap + block.width + padR, height: max(circle, block.height) + 32)
            return Sticker(size: sz) { o, anchorLeft in
                let box = CGRect(origin: o, size: sz)
                let m = max(sz.width, sz.height) * 0.06 + 16
                let rect = CGRect(x: box.minX - m, y: box.minY - m, width: box.width + 2 * m + 10, height: box.height + 2 * m + 10)
                let anchor = anchorLeft ? CGPoint(x: box.minX, y: box.midY) : CGPoint(x: box.maxX, y: box.midY)
                return Elem(rect: rect, anim: .pop, at: at, anchor: anchor) { pen in
                    rotated(pen, around: CGPoint(x: box.midX, y: box.midY), deg: rot) {
                        fill(pen, box.offsetBy(dx: 10, dy: 10), black)
                        fill(pen, box, white)
                        let c = CGRect(x: box.minX + padL, y: box.midY - circle / 2, width: circle, height: circle)
                        pen.ctx.setFillColor(red); pen.ctx.fillEllipse(in: c)
                        let num = PlateText.text("\(n)", size: 46, color: white, red: white, heavy: true, lineHeight: 1)
                        num.draw(pen, x: c.midX - num.width / 2, top: c.midY - num.height / 2)
                        block.draw(pen, x: c.maxX + gap, top: box.midY - block.height / 2)
                    }
                }
            }
        }

        /// Words laid out for popping in one by one. *marked* words get a red marker behind them (white text).
        struct Words {
            let items: [(text: String, marked: Bool, rect: CGRect, block: PlateText.Block)]
            let width: CGFloat
            let height: CGFloat
            let kit: Kit
            let marker: Bool

            func elements(x: CGFloat, top: CGFloat, anim: Anim, start: Double, step: Double, shadow: Bool, markerDelay: Double = 0.25) -> [Elem] {
                var out: [Elem] = []
                for (i, w) in items.enumerated() {
                    let r = w.rect.offsetBy(dx: x, dy: top)
                    let at = start + step * Double(i)
                    if w.marked && marker {
                        let mk = CGRect(x: r.minX - 14, y: r.minY + r.height * 0.14, width: r.width + 28, height: r.height * 0.8)
                        let red = kit.red
                        out.append(Elem(rect: mk.insetBy(dx: -20, dy: -4), anim: .swipe, at: at + markerDelay,
                                        anchor: CGPoint(x: mk.minX, y: mk.midY)) { pen in
                            let skew = mk.height * 0.14
                            pen.ctx.beginPath()
                            pen.ctx.move(to: CGPoint(x: mk.minX + skew, y: mk.minY))
                            pen.ctx.addLine(to: CGPoint(x: mk.maxX + skew, y: mk.minY))
                            pen.ctx.addLine(to: CGPoint(x: mk.maxX - skew, y: mk.maxY))
                            pen.ctx.addLine(to: CGPoint(x: mk.minX - skew, y: mk.maxY))
                            pen.ctx.closePath()
                            pen.ctx.setFillColor(red); pen.ctx.fillPath()
                        })
                    }
                    let block = w.block
                    let flat: CGColor? = (w.marked && marker) ? PlateDrawing.white : nil
                    let sh: CGFloat = shadow ? 8 : 0
                    out.append(Elem(rect: r.insetBy(dx: -12, dy: -12).offsetBy(dx: sh, dy: sh), anim: anim,
                                    at: at + ((w.marked && marker) ? markerDelay + 0.1 : 0),
                                    anchor: CGPoint(x: r.midX, y: r.midY)) { pen in
                        if shadow { block.draw(pen, x: r.minX + sh, top: r.minY + sh, flat: PlateDrawing.black) }
                        block.draw(pen, x: r.minX, top: r.minY, flat: flat)
                    })
                }
                return out
            }
        }

        func words(_ raw: String, size: CGFloat, maxWidth: CGFloat, lineHeight: CGFloat, center: Bool = false, marker: Bool = true) -> Words {
            // Tokenize into words, remembering which were *marked*.
            var tokens: [(String, Bool)] = []
            var cur = "", marked = false, curMarked = false
            func flush() { if !cur.isEmpty { tokens.append((cur, curMarked)) }; cur = ""; curMarked = false }
            var lines: [[(String, Bool)]] = [[]]
            for ch in raw.replacingOccurrences(of: "\\n", with: "\n") {
                if ch == "*" { marked.toggle(); continue }
                if ch == " " { flush(); continue }
                if ch == "\n" { flush(); lines[lines.count - 1] += tokens; tokens = []; lines.append([]); continue }
                cur.append(ch); if marked { curMarked = true }
            }
            flush(); lines[lines.count - 1] += tokens
            let font = CTFontCreateWithName("Arial-Black" as CFString, size, nil)
            let space = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: " ", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])), nil, nil, nil)) + size * 0.06
            let lh = size * lineHeight
            var placed: [(String, Bool, CGRect, PlateText.Block)] = []
            var rows: [[(String, Bool, CGFloat, PlateText.Block)]] = []
            for line in lines {
                var row: [(String, Bool, CGFloat, PlateText.Block)] = []
                var w: CGFloat = 0
                for (t, m) in line {
                    let b = PlateText.text(t, size: size, color: PlateDrawing.white, red: m && !marker ? red : PlateDrawing.white,
                                   heavy: true, lineHeight: lineHeight, allRed: m && !marker)
                    let add = (row.isEmpty ? 0 : space) + b.width
                    if !row.isEmpty && w + add > maxWidth { rows.append(row); row = []; w = 0 }
                    row.append((t, m, b.width, b))
                    w += (row.count == 1 ? 0 : space) + b.width
                }
                rows.append(row)
            }
            var widest: CGFloat = 0
            for (ri, row) in rows.enumerated() {
                let rowW = row.reduce(0) { $0 + $1.2 } + space * CGFloat(max(0, row.count - 1))
                widest = max(widest, rowW)
                var x = center ? (maxWidth - rowW) / 2 : 0
                for (t, m, w, b) in row {
                    placed.append((t, m, CGRect(x: x, y: CGFloat(ri) * lh, width: w, height: lh), b))
                    x += w + space
                }
            }
            return Words(items: placed.map { (text: $0.0, marked: $0.1, rect: $0.2, block: $0.3) },
                         width: center ? maxWidth : widest, height: CGFloat(rows.count) * lh, kit: self, marker: marker)
        }

        /// Red scribble drawn around `r`.
        func scribbleCircle(_ r: CGRect, at: Double) -> Elem {
            Elem(rect: r.insetBy(dx: -30, dy: -30), anim: .draw, at: at, anchor: CGPoint(x: r.minX, y: r.midY)) { pen in
                let c = pen.ctx
                c.beginPath()
                c.move(to: CGPoint(x: r.minX + r.width * 0.1, y: r.minY + r.height * 0.15))
                c.addCurve(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.3),
                           control1: CGPoint(x: r.minX + r.width * 0.35, y: r.minY - r.height * 0.05),
                           control2: CGPoint(x: r.maxX - r.width * 0.05, y: r.minY))
                c.addCurve(to: CGPoint(x: r.minX + r.width * 0.65, y: r.maxY),
                           control1: CGPoint(x: r.maxX + r.width * 0.05, y: r.minY + r.height * 0.7),
                           control2: CGPoint(x: r.maxX - r.width * 0.15, y: r.maxY))
                c.addCurve(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.55),
                           control1: CGPoint(x: r.minX + r.width * 0.3, y: r.maxY + r.height * 0.05),
                           control2: CGPoint(x: r.minX - r.width * 0.02, y: r.maxY - r.height * 0.1))
                c.addCurve(to: CGPoint(x: r.minX + r.width * 0.22, y: r.minY + r.height * 0.05),
                           control1: CGPoint(x: r.minX + r.width * 0.02, y: r.minY + r.height * 0.3),
                           control2: CGPoint(x: r.minX + r.width * 0.1, y: r.minY + r.height * 0.1))
                stroke(pen)
            }
        }

        func underline(_ r: CGRect, at: Double, rotateAround: CGPoint? = nil, deg: CGFloat = 0) -> Elem {
            Elem(rect: r.insetBy(dx: -40, dy: -40), anim: .draw, at: at, anchor: CGPoint(x: r.minX, y: r.midY)) { pen in
                let body = {
                    let c = pen.ctx
                    c.beginPath()
                    c.move(to: CGPoint(x: r.minX, y: r.midY + 6))
                    c.addCurve(to: CGPoint(x: r.midX, y: r.midY), control1: CGPoint(x: r.minX + r.width * 0.2, y: r.minY),
                               control2: CGPoint(x: r.minX + r.width * 0.35, y: r.maxY))
                    c.addCurve(to: CGPoint(x: r.maxX, y: r.midY - 2), control1: CGPoint(x: r.midX + r.width * 0.15, y: r.minY),
                               control2: CGPoint(x: r.maxX - r.width * 0.15, y: r.maxY))
                    stroke(pen, width: 10)
                }
                if let o = rotateAround { rotated(pen, around: o, deg: deg, body) } else { body() }
            }
        }

        func arrow(from a: CGPoint, to b: CGPoint, at: Double) -> Elem {
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)).insetBy(dx: -60, dy: -60)
            return Elem(rect: r, anim: .draw, at: at, anchor: CGPoint(x: r.minX, y: r.midY)) { pen in
                let c = pen.ctx
                let mid = CGPoint(x: (a.x + b.x) / 2 - (b.y - a.y) * 0.25, y: (a.y + b.y) / 2 + (b.x - a.x) * 0.1 - 40)
                c.beginPath(); c.move(to: a); c.addQuadCurve(to: b, control: mid); stroke(pen)
                // Head: two strokes back from the tip along the curve's last direction.
                let dx = b.x - mid.x, dy = b.y - mid.y, len = max(1, sqrt(dx * dx + dy * dy))
                let ux = dx / len, uy = dy / len
                for sgn: CGFloat in [-1, 1] {
                    let px = -uy * sgn, py = ux * sgn
                    c.beginPath(); c.move(to: b)
                    c.addLine(to: CGPoint(x: b.x - ux * 46 + px * 30, y: b.y - uy * 46 + py * 30))
                    stroke(pen)
                }
            }
        }

        func burst(center o: CGPoint, at: Double) -> Elem {
            Elem(rect: CGRect(x: o.x - 130, y: o.y - 130, width: 260, height: 260), anim: .draw, at: at, anchor: o) { pen in
                for i in 0..<8 {
                    let ang = CGFloat(i) * .pi / 4
                    pen.ctx.beginPath()
                    pen.ctx.move(to: CGPoint(x: o.x + cos(ang) * 70, y: o.y + sin(ang) * 70))
                    pen.ctx.addLine(to: CGPoint(x: o.x + cos(ang) * 110, y: o.y + sin(ang) * 110))
                    stroke(pen)
                }
            }
        }

        func stroke(_ pen: Pen, width: CGFloat = 12) {
            pen.ctx.setStrokeColor(red); pen.ctx.setLineWidth(width)
            pen.ctx.setLineCap(.round); pen.ctx.setLineJoin(.round)
            pen.ctx.strokePath()
        }

        func fill(_ pen: Pen, _ r: CGRect, _ c: CGColor) {
            pen.ctx.setFillColor(c); pen.ctx.fill(r)
        }

        func rotated(_ pen: Pen, around o: CGPoint, deg: CGFloat, _ body: () -> Void) {
            pen.ctx.saveGState()
            pen.ctx.translateBy(x: o.x, y: o.y)
            pen.ctx.rotate(by: deg * .pi / 180)
            pen.ctx.translateBy(x: -o.x, y: -o.y)
            body()
            pen.ctx.restoreGState()
        }
    }
}

// MARK: - Text (Core Text; *marked* runs in red)

enum PlateText {
    struct Block {
        let lines: [CTLine]
        let flatLines: (CGColor) -> [CTLine]
        let lineHeight: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
        let width: CGFloat
        /// Where the *marked* text sits, relative to the block's top-left (first marked run only).
        let markedRect: CGRect?
        var height: CGFloat { CGFloat(lines.count) * lineHeight }

        func draw(_ pen: PlateDrawing.Pen, x: CGFloat, top: CGFloat, flat: CGColor? = nil) {
            let ls = flat.map { flatLines($0) } ?? lines
            var y = top
            for line in ls {
                pen.ctx.textPosition = CGPoint(x: x, y: y + (lineHeight + ascent - descent) / 2)
                CTLineDraw(line, pen.ctx)
                y += lineHeight
            }
        }
    }

    /// heavy = Arial Black, otherwise Arial Bold. allRed paints every run red.
    static func text(_ raw: String, size: CGFloat, color: CGColor, red: CGColor, heavy: Bool, kern: CGFloat = 0,
                     width: CGFloat? = nil, lineHeight: CGFloat = 1.1, allRed: Bool = false) -> Block {
        let font = CTFontCreateWithName((heavy ? "Arial-Black" : "Arial-BoldMT") as CFString, size, nil)
        let paragraphs = raw.replacingOccurrences(of: "\\n", with: "\n").components(separatedBy: "\n")
        func build(_ colorOverride: CGColor?) -> ([CTLine], CGFloat, CGRect?) {
            var lines: [CTLine] = []
            var widest: CGFloat = 0
            var marked: CGRect?
            let lh = size * lineHeight
            for para in paragraphs {
                let (a, ranges) = attributed(para, font: font, color: color, red: allRed ? red : red, kern: kern,
                                             override: colorOverride ?? (allRed ? red : nil))
                if a.length == 0 { lines.append(CTLineCreateWithAttributedString(a)); continue }
                let ts = CTTypesetterCreateWithAttributedString(a)
                var start = 0
                while start < a.length {
                    var count = width.map { CTTypesetterSuggestLineBreak(ts, start, Double($0)) } ?? (a.length - start)
                    if count <= 0 { count = a.length - start }
                    let line = CTTypesetterCreateLine(ts, CFRange(location: start, length: count))
                    let lw = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
                    widest = max(widest, lw)
                    if marked == nil, let r = ranges.first, r.location >= start, r.location < start + count {
                        let x0 = CTLineGetOffsetForStringIndex(line, r.location, nil)
                        let x1 = CTLineGetOffsetForStringIndex(line, min(r.location + r.length, start + count), nil)
                        marked = CGRect(x: x0, y: CGFloat(lines.count) * lh, width: x1 - x0, height: lh)
                    }
                    lines.append(line)
                    start += count
                }
            }
            return (lines, widest, marked)
        }
        let (lines, widest, marked) = build(nil)
        return Block(lines: lines, flatLines: { c in build(c).0 }, lineHeight: size * lineHeight,
                     ascent: CTFontGetAscent(font), descent: CTFontGetDescent(font), width: widest, markedRect: marked)
    }

    /// Plain text with *asterisk* runs in red (the asterisks are removed). Also returns the red ranges.
    static func attributed(_ s: String, font: CTFont, color: CGColor, red: CGColor, kern: CGFloat,
                           override: CGColor?) -> (NSAttributedString, [NSRange]) {
        let out = NSMutableAttributedString()
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let kernKey = NSAttributedString.Key(kCTKernAttributeName as String)
        var ranges: [NSRange] = []
        var isRed = false
        for (i, piece) in s.components(separatedBy: "*").enumerated() {
            if i > 0 { isRed.toggle() }
            guard !piece.isEmpty else { continue }
            var attrs: [NSAttributedString.Key: Any] = [fontKey: font, colorKey: override ?? (isRed ? red : color)]
            if kern != 0 { attrs[kernKey] = kern }
            if isRed { ranges.append(NSRange(location: out.length, length: (piece as NSString).length)) }
            out.append(NSAttributedString(string: piece, attributes: attrs))
        }
        return (out, ranges)
    }
}

enum GraphicsStyle {
    static let defaultRedHex = "#FF2D2D"
    static let redKey = "GraphicsRed"

    /// The emphasis red (Settings; matches the user's thumbnails once they set it).
    /// The emphasis red: Graphics Style.json's "red" if set, else the app setting, else the default.
    static var redHex: String {
        get {
            if let r = GraphicsTuningStore.current.red, color(hex: r) != nil { return r }
            return UserDefaults.standard.string(forKey: redKey) ?? defaultRedHex
        }
        set {
            UserDefaults.standard.set(newValue, forKey: redKey)
            _ = try? GraphicsTuningStore.update(["red": newValue])
        }
    }

    static func color(hex: String) -> CGColor? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static var red: CGColor { color(hex: redHex) ?? color(hex: defaultRedHex)! }
}


// MARK: - Preview sheet (MCP: graphics_preview)

enum GraphicsSheet {
    /// Each plate drawn over its frame of the video, numbered, in a grid. JPEG data.
    static func make(_ plates: [GraphicPlate], frames: [CGImage?], title: String, red: CGColor) -> (data: Data, width: Int, height: Int)? {
        let tw = 640, th = 360, gap = 12, caption = 30, header = 48
        let cols = min(3, max(1, plates.count))
        let rows = (plates.count + cols - 1) / cols
        let width = cols * tw + (cols + 1) * gap
        let height = header + rows * (th + caption + gap) + gap
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: NSColor.white]
        NSAttributedString(string: "Motion graphics: \(title)", attributes: titleAttrs).draw(at: NSPoint(x: gap, y: height - header + 14))
        let capAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(white: 0.85, alpha: 1)]
        let numAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: NSColor.white]
        for (i, p) in plates.enumerated() {
            let col = i % cols, row = i / cols
            let x = gap + col * (tw + gap)
            let top = height - header - row * (th + caption + gap)
            let rect = CGRect(x: x, y: top - th, width: tw, height: th)
            ctx.setFillColor(CGColor(gray: 0.25, alpha: 1)); ctx.fill(rect)
            if !p.isFullScreen, i < frames.count, let f = frames[i] {
                ctx.saveGState(); ctx.clip(to: rect); ctx.interpolationQuality = .high
                let k = max(CGFloat(tw) / CGFloat(f.width), CGFloat(th) / CGFloat(f.height))
                let w = CGFloat(f.width) * k, h = CGFloat(f.height) * k
                ctx.draw(f, in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
                ctx.restoreGState()
            }
            // Every element fully in.
            if let g = PlateDrawing.render(p, width: tw, height: th, red: red) {
                ctx.draw(g, in: rect)
            }
            let n = NSAttributedString(string: "\(i + 1)", attributes: numAttrs)
            let ns = n.size()
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.75))
            ctx.fill(CGRect(x: rect.minX + 6, y: rect.maxY - ns.height - 12, width: ns.width + 16, height: ns.height + 6))
            n.draw(at: NSPoint(x: rect.minX + 14, y: rect.maxY - ns.height - 9))
            let cap = "\(MCP.tc(p.at)) · \(String(format: "%.1f", p.length)) s · \(p.template)"
            NSAttributedString(string: cap, attributes: capAttrs).draw(at: NSPoint(x: rect.minX, y: rect.minY - 22))
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let img = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: img)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        return (data, width, height)
    }
}

// MARK: - Reading plates from JSON (id is optional; a new one is made)

extension GraphicPlate {
    enum CodingKeys: String, CodingKey {
        case id, at, length, template, kicker, title, subtitle, items, side, style, build, builds, current, avoid, overFace, scale, dx, dy, words, reason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        at = try c.decode(Double.self, forKey: .at)
        length = try c.decodeIfPresent(Double.self, forKey: .length) ?? 0
        template = try c.decode(String.self, forKey: .template)
        kicker = try c.decodeIfPresent(String.self, forKey: .kicker)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        items = try c.decodeIfPresent([String].self, forKey: .items)
        side = try c.decodeIfPresent(String.self, forKey: .side)
        style = try c.decodeIfPresent(String.self, forKey: .style)
        build = try c.decodeIfPresent(Bool.self, forKey: .build)
        builds = try c.decodeIfPresent([Double].self, forKey: .builds)
        current = try c.decodeIfPresent(Int.self, forKey: .current)
        avoid = try c.decodeIfPresent([Double].self, forKey: .avoid)
        overFace = try c.decodeIfPresent(Bool.self, forKey: .overFace)
        scale = try c.decodeIfPresent(Double.self, forKey: .scale)
        dx = try c.decodeIfPresent(Double.self, forKey: .dx)
        dy = try c.decodeIfPresent(Double.self, forKey: .dy)
        words = try c.decodeIfPresent(String.self, forKey: .words)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
    }

    /// Words on the plate (asterisks dropped), for the reading-time rule.
    var wordCount: Int {
        let all = [kicker, title, subtitle].compactMap { $0 } + (items ?? [])
        return all.joined(separator: " ").replacingOccurrences(of: "*", with: "")
            .split(whereSeparator: { $0 == " " || $0 == "\n" }).count
    }

    /// Long enough to read: words ÷ 3 + 1 s, at least 2 s (building plates: until the last item
    /// has been up 2 s). Lengths are on-screen (edited) seconds, so cuts in between don't count.
    func minimumLength(cuts: [Cut]) -> Double {
        var m = max(2, Double(wordCount) / 3 + 1)
        if build == true, let last = builds?.max() {
            let span = (last - CutList.removed(before: last, cuts: cuts)) - (at - CutList.removed(before: at, cuts: cuts))
            m = max(m, span + 2)
        }
        return m
    }
}

// MARK: - Finding the speaker's face (so overlays stay off it)

enum FaceFinder {
    /// For each overlay plate: looks for the speaker's face at its start, middle and end (as the viewer sees
    /// the frame: stabilized and zoomed, without graphics) and stores the padded union in `avoid`.
    /// A plate with no side gets the side with more room. Slow-ish: call off the main thread.
    static func find(_ plates: [GraphicPlate], asset: AVAsset, composition: AVVideoComposition, cuts: [Cut]) -> [GraphicPlate] {
        // Face checks are off (2026-11-11: "Don't do checks. Just make the plates"). Plates
        // keep the side they're given (left when none) and no face box; nothing is searched.
        return plates.map { p0 in
            var p = p0
            p.avoid = nil
            if p.side == nil, !p.isFullScreen { p.side = "left" }
            return p
        }
    }

    /// The old face search, kept for reference; not called.
    static func findFaces(_ plates: [GraphicPlate], asset: AVAsset, composition: AVVideoComposition, cuts: [Cut]) -> [GraphicPlate] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.videoComposition = composition
        generator.maximumSize = CGSize(width: 960, height: 960)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        return plates.map { p0 in
            var p = p0
            guard !p.isFullScreen, p.overFace != true else { return p }
            let e0 = p.at - CutList.removed(before: p.at, cuts: cuts)
            let edits = [e0 + min(0.3, p.length / 2), e0 + p.length / 2, e0 + max(p.length - 0.3, p.length / 2)]
            var union: CGRect?
            for e in edits {
                let t = CutList.sourceTime(e, cuts: cuts)
                guard let img = try? generator.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil),
                      let face = face(in: img) else { continue }
                union = union.map { $0.union(face) } ?? face
            }
            if let f = union {
                p.avoid = [Double(f.minX), Double(f.minY), Double(f.width), Double(f.height)].map { ($0 * 10).rounded() / 10 }
                if p.side == nil { p.side = f.minX >= PlateDrawing.W - f.maxX ? "left" : "right" }
            }
            return p
        }
    }

    /// The biggest face in `image`, in 1920×1080 design space.
    static func face(in image: CGImage) -> CGRect? {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let best = (request.results ?? []).max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height })
        else { return nil }
        let bb = best.boundingBox                       // normalized, origin bottom-left
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let s = min(w / PlateDrawing.W, h / PlateDrawing.H)
        let ox = (w - PlateDrawing.W * s) / 2, oy = (h - PlateDrawing.H * s) / 2
        let px = CGRect(x: bb.minX * w, y: (1 - bb.maxY) * h, width: bb.width * w, height: bb.height * h)
        // Stored as found; the padding (hair, chin, sides) comes from Graphics Style.json when drawing.
        let r = CGRect(x: (px.minX - ox) / s, y: (px.minY - oy) / s, width: px.width / s, height: px.height / s)
        return r.intersection(CGRect(x: 0, y: 0, width: PlateDrawing.W, height: PlateDrawing.H))
    }
}

// MARK: - Graphics Style.json (live tuning, no rebuild)
//
// ~/Movies/1Shot/Style Guides/Graphics Style.json holds the numbers the user tunes by eye.
// The app re-reads it while running (checked twice a second), so a change shows on the next frame.

struct GraphicsTuning: Codable, Equatable {
    var overlayScale = 1.0        // every overlay plate's size (1 = as designed)
    var fullScreenScale = 1.0     // full-screen plates' size
    var faceSidePad = 0.15        // room kept beside the speaker's face, as a share of its width (each side)
    var faceTopPad = 0.35         // room above it for hair, share of its height
    var faceChinPad = 0.25        // room below it for the chin, share of its height
    var minScale = 0.6            // smallest a plate may shrink to clear his face
    var edge = 60.0               // distance from the frame edge, px of 1920
    var gap = 24.0                // gap between a plate and his face, px of 1920
    var popSeconds = 0.45
    var slamSeconds = 0.36
    var swipeSeconds = 0.35
    var drawSeconds = 0.7
    var slideSeconds = 0.5
    var fadeOutSeconds = 0.25
    var red: String? = nil        // emphasis red as hex, e.g. "#E3242B" (matches the thumbnails)

    static let keys = ["overlayScale", "fullScreenScale", "faceSidePad", "faceTopPad", "faceChinPad", "minScale", "edge", "gap",
                       "popSeconds", "slamSeconds", "swipeSeconds", "drawSeconds", "slideSeconds", "fadeOutSeconds", "red"]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GraphicsTuning()
        func v(_ k: CodingKeys, _ def: Double) -> Double { ((try? c.decodeIfPresent(Double.self, forKey: k)) ?? nil) ?? def }
        overlayScale = v(.overlayScale, d.overlayScale)
        fullScreenScale = v(.fullScreenScale, d.fullScreenScale)
        faceSidePad = v(.faceSidePad, d.faceSidePad)
        faceTopPad = v(.faceTopPad, d.faceTopPad)
        faceChinPad = v(.faceChinPad, d.faceChinPad)
        minScale = v(.minScale, d.minScale)
        edge = v(.edge, d.edge)
        gap = v(.gap, d.gap)
        popSeconds = v(.popSeconds, d.popSeconds)
        slamSeconds = v(.slamSeconds, d.slamSeconds)
        swipeSeconds = v(.swipeSeconds, d.swipeSeconds)
        drawSeconds = v(.drawSeconds, d.drawSeconds)
        slideSeconds = v(.slideSeconds, d.slideSeconds)
        fadeOutSeconds = v(.fadeOutSeconds, d.fadeOutSeconds)
        red = (try? c.decodeIfPresent(String.self, forKey: .red)) ?? nil
    }
}

enum GraphicsTuningStore {
    static var url: URL { Project.styleGuidesFolder.appendingPathComponent("Graphics Style.json") }

    private static let lock = NSLock()
    private static var cached = GraphicsTuning()
    private static var stamp: Date?
    private static var lastCheck = Date.distantPast
    private static var _version = 0

    /// Bumps whenever the file changes (part of the renderer's cache key).
    static var version: Int { lock.lock(); defer { lock.unlock() }; return _version }

    static var current: GraphicsTuning {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if now.timeIntervalSince(lastCheck) > 0.5 {
            lastCheck = now
            let m = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            if m != stamp {
                stamp = m
                if let data = try? Data(contentsOf: url), let t = try? JSONDecoder().decode(GraphicsTuning.self, from: data) {
                    cached = t
                } else if m == nil {
                    cached = GraphicsTuning()
                }
                _version += 1
            }
        }
        return cached
    }

    /// Writes the file with every setting (current values) if it isn't there yet.
    static func ensureFile() {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(GraphicsTuning()) { try? data.write(to: url) }
    }

    /// Changes some settings (keys from GraphicsTuning.keys) and saves the file. Unknown keys are refused.
    @discardableResult
    static func update(_ changes: [String: Any]) throws -> GraphicsTuning {
        ensureFile()
        var dict = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any]) ?? [:]
        for (k, v) in changes {
            guard GraphicsTuning.keys.contains(k) else { throw MCPError("Graphics Style has no setting “\(k)”. Settings: \(GraphicsTuning.keys.joined(separator: ", ")).") }
            if v is NSNull { dict.removeValue(forKey: k) } else { dict[k] = v }
        }
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        guard (try? JSONDecoder().decode(GraphicsTuning.self, from: data)) != nil else { throw MCPError("Those values don't fit the settings (numbers, and red as \"#RRGGBB\").") }
        try data.write(to: url)
        lock.lock(); lastCheck = .distantPast; lock.unlock()
        return current
    }

    static func asDictionary(_ t: GraphicsTuning) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(t), let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return d
    }
}

// ColorGrade — exposure / highlights / shadows / color (temperature) / tint / saturation,
// applied with Core Image to every frame (live in the player, and in the export).

import Cocoa
import CoreImage
import AVFoundation

final class ColorGrade {
    /// All values run −100…+100, 0 = untouched.
    struct Settings: Equatable {
        var exposure: Double = 0
        var highlights: Double = 0
        var shadows: Double = 0
        var temperature: Double = 0     // "Color": − cooler (blue), + warmer (yellow)
        var tint: Double = 0            // − green, + magenta
        var saturation: Double = 0
        var vibrance: Double = 0        // −100…100
        var sharpen: Double = 0         // 0…100
        var denoise: Double = 0         // 0…100
        var blackPoint: Double = 0      // Levels, 0…1 (input tone that becomes pure black)
        var whitePoint: Double = 1      // Levels, 0…1 (input tone that becomes pure white)
        var isNeutral: Bool { self == Settings() }
    }

    /// How hard the sliders push: 0.5 means a slider at ±100 does what ±50 did originally,
    /// giving finer control for small corrections. (Saturation and highlight recovery run at full strength.)
    static let range: Double = 0.5

    private let lock = NSLock()
    private var _settings = Settings()
    private var _framesGraded = 0
    private var _lut: CubeLUT?
    private var _creativeLUT: CubeLUT?

    /// The LUT applied first (like a camera profile), or nil for none.
    var lut: CubeLUT? {
        get { lock.lock(); defer { lock.unlock() }; return _lut }
        set { lock.lock(); _lut = newValue; lock.unlock() }
    }

    /// A look LUT applied right after the camera LUT, or nil for none.
    var creativeLUT: CubeLUT? {
        get { lock.lock(); defer { lock.unlock() }; return _creativeLUT }
        set { lock.lock(); _creativeLUT = newValue; lock.unlock() }
    }

    var settings: Settings {
        get { lock.lock(); defer { lock.unlock() }; return _settings }
        set {
            lock.lock(); _settings = newValue; lock.unlock()
            NSLog("1Shot: color settings now \(newValue)")
        }
    }

    /// Diagnostics: logs the first frame and then every 100th, so we can see the grade is running.
    private func noteFrame(_ s: Settings) {
        lock.lock(); _framesGraded += 1; let n = _framesGraded; lock.unlock()
        if n == 1 || n % 100 == 0 {
            NSLog("1Shot: color stage graded frame #\(n) (neutral: \(s.isNeutral))")
        }
    }

    // MARK: Visual Design groups (3.2)

    /// A group's look, ready to render. The "aroll" group uses `settings`/`lut`/`creativeLUT` above.
    struct GroupGrade { var settings = Settings(); var lut: CubeLUT? = nil; var creativeLUT: CubeLUT? = nil
        var isNeutral: Bool { settings.isNeutral && lut == nil && creativeLUT == nil } }
    private var _groupGrades: [String: GroupGrade] = [:]
    private var _arollBoundaries: [Double] = []      // where each A-roll clip ends (clip time), last one left out
    private var _arollGroups: [String] = []          // group per A-roll clip, in order

    func setGroupGrades(_ grades: [String: GroupGrade]) { lock.lock(); _groupGrades = grades; lock.unlock() }
    func setGroupSettings(_ id: String, _ s: Settings) {
        lock.lock(); var g = _groupGrades[id] ?? GroupGrade(); g.settings = s; _groupGrades[id] = g; lock.unlock()
    }
    func setGroupLUT(_ id: String, camera: Bool, _ lut: CubeLUT?) {
        lock.lock(); var g = _groupGrades[id] ?? GroupGrade()
        if camera { g.lut = lut } else { g.creativeLUT = lut }
        _groupGrades[id] = g; lock.unlock()
    }
    func setArollGroups(boundaries: [Double], groups: [String]) {
        lock.lock(); _arollBoundaries = boundaries; _arollGroups = groups; lock.unlock()
    }

    /// The look for the A-roll clip playing at clip time `t`.
    private func arollGrade(at t: Double) -> (Settings, CubeLUT?, CubeLUT?) {
        lock.lock()
        let idx = _arollBoundaries.filter { t >= $0 }.count
        let gid = idx < _arollGroups.count ? _arollGroups[idx] : VisualGroup.arollID
        let g = _groupGrades[gid]
        let base = (_settings, _lut, _creativeLUT)
        lock.unlock()
        guard gid != VisualGroup.arollID, let g else { return base }
        return (g.settings, g.lut, g.creativeLUT)
    }

    private func groupGrade(_ id: String?) -> GroupGrade? {
        guard let id else { return nil }
        lock.lock(); defer { lock.unlock() }
        if id == VisualGroup.arollID { return GroupGrade(settings: _settings, lut: _lut, creativeLUT: _creativeLUT) }
        return _groupGrades[id]
    }

    /// White balance → camera LUT → creative LUT → the rest of the sliders (the shared chain).
    static func grade(_ input: CIImage, _ s: Settings, lut: CubeLUT?, creativeLUT: CubeLUT?) -> CIImage {
        var image = input.clampedToExtent()
        if s.temperature != 0 || s.tint != 0 {
            image = whiteBalance(image, temperature: s.temperature, tint: s.tint)
        }
        if let lut { image = lut.apply(to: image) }
        if let creativeLUT { image = creativeLUT.apply(to: image) }
        var rest = s
        rest.temperature = 0
        rest.tint = 0
        return apply(rest, to: image).cropped(to: input.extent)
    }

    private static func bypassedSettings(_ s: Settings) -> Settings {
        var levelsOnly = Settings()
        levelsOnly.blackPoint = s.blackPoint
        levelsOnly.whitePoint = s.whitePoint
        return levelsOnly
    }

    private var _bypassed = false
    private var _fadeOutEnd: Double?
    static let fadeDuration = 0.5

    /// When set, the picture fades to black over the 0.5 s before this time (the trim end).
    var fadeOutEnd: Double? {
        get { lock.lock(); defer { lock.unlock() }; return _fadeOutEnd }
        set { lock.lock(); _fadeOutEnd = newValue; lock.unlock() }
    }

    private var _zooms: [ZoomEvent] = []
    /// Punch-in zooms (original-clip time). Applied right after stabilization, as an instant crop.
    var zooms: [ZoomEvent] {
        get { lock.lock(); defer { lock.unlock() }; return _zooms }
        set { lock.lock(); _zooms = newValue; lock.unlock() }
    }

    /// B-roll on the V2 track: replaces the talking head (ungraded, unzoomed) while it's on.
    let broll = BrollRenderer()

    /// Motion graphics (V3): drawn over everything (after zoom, color and B-roll), never zoomed or graded.
    let graphics = GraphicsRenderer()

    /// Camera-shake removal applied ahead of everything else (set once by the window).
    var stabilizer: Stabilizer?

    /// Bypass turns off the Color section (white balance + sliders) in the player, keeping the
    /// LUT and Levels, for a quick before/after. Export ignores it.
    var bypassed: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _bypassed }
        set { lock.lock(); _bypassed = newValue; lock.unlock() }
    }

    /// Video composition that runs every frame through the grade. Output is standard
    /// (Rec. 709) color, so the preview matches the YouTube export.
    /// `honorsBypass`: true for the player, false for export (always graded).
    /// `mapTime`: when the asset is the edited timeline (cuts taken out), turns its time back into
    /// original-clip time for stabilization and the fade.
    /// `includeGraphics`: false leaves the motion graphics out (used to find the speaker's face under them).
    /// `forDisplay`: the player's composition. Its frames are tagged sRGB instead of Rec. 709 (3.2,
    /// 2026-11-12: "1Shot is falling apart" next to QuickTime): macOS shows 709-tagged
    /// *RGB* frames with the full Rec. 709 curve, which lifts the shadows (and their compression
    /// noise) well above what QuickTime shows for the same file. Core Image decodes 709 with the
    /// same 1.961 gamma QuickTime uses, so handing the display sRGB values puts the preview back in
    /// line with QuickTime. Export and stills stay Rec. 709.
    func makeVideoComposition(for asset: AVAsset, honorsBypass: Bool = true,
                              mapTime: ((Double) -> Double)? = nil, includeGraphics: Bool = true,
                              forDisplay: Bool = false) -> AVVideoComposition {
        let comp = AVMutableVideoComposition(asset: asset) { [weak self] request in
            let source = request.sourceImage
            guard let self else { request.finish(with: source, context: nil); return }
            // Time on the original clip (differs from the player's time when cuts are taken out).
            let clipTime = mapTime.map { CMTime(seconds: $0(request.compositionTime.seconds), preferredTimescale: 60_000) }
                ?? request.compositionTime
            // The look of the Visual Design group that owns this A-roll clip (3.2).
            var (s, lut, creativeLUT) = self.arollGrade(at: clipTime.seconds)
            let bypass = honorsBypass && self.bypassed
            if bypass { s = ColorGrade.bypassedSettings(s) }   // keep only LUTs and Levels
            self.noteFrame(s)
            // Stabilization first (shift + slight zoom), then LUT and color.
            var image = source
            if let plan = self.stabilizer?.activePlan {
                image = plan.apply(to: source, at: clipTime)
            }
            // Punch-in zoom: scale around a point a little above center (keeps the eyes high).
            // Scaling around the eyes keeps them exactly where they were in the wide frame.
            if let z = ZoomList.active(at: clipTime.seconds, in: self.zooms), z.scale > 1.001 {
                let e = source.extent
                let ax = e.minX + e.width * CGFloat(z.anchorX ?? 0.5)
                let ay = e.maxY - e.height * CGFloat(z.anchorY ?? ZoomList.anchorFromTop)
                let k = CGFloat(z.scale)
                image = image.transformed(by: CGAffineTransform(translationX: -ax, y: -ay)
                    .concatenating(CGAffineTransform(scaleX: k, y: k))
                    .concatenating(CGAffineTransform(translationX: ax, y: ay)))
            }
            // White balance goes BEFORE the LUT, like setting it in the camera: a log/conversion
            // LUT expects a neutral picture going in, and correcting after it can't fully undo a cast.
            var graded = ColorGrade.grade(image.cropped(to: source.extent), s, lut: lut, creativeLUT: creativeLUT)

            // B-roll (V2) covers the talking head while it's on, graded by its own group's look.
            // A picture-in-picture shot (3.2) sits in its box over the talking head instead.
            if let (b, group, pip) = self.broll.image(at: clipTime.seconds, extent: source.extent) {
                var shot = b
                if var g = self.groupGrade(group), !g.isNeutral {
                    if bypass { g.settings = ColorGrade.bypassedSettings(g.settings) }
                    shot = ColorGrade.grade(b, g.settings, lut: g.lut, creativeLUT: g.creativeLUT)
                }
                if let pip {
                    graded = BrollRenderer.placeInPicture(shot, pip, extent: source.extent).composited(over: graded)
                } else {
                    graded = shot
                }
            }

            // Motion graphics (V3) on top; the fade to black below covers them too.
            if includeGraphics, let g = self.graphics.image(at: clipTime.seconds, extent: source.extent) {
                graded = g.composited(over: graded).cropped(to: source.extent)
            }

            // Fade to black over the last half second before the (trimmed) end.
            if let end = self.fadeOutEnd {
                let remaining = end - clipTime.seconds
                if remaining < ColorGrade.fadeDuration {
                    let f = max(0, remaining / ColorGrade.fadeDuration)
                    let k = CGFloat(pow(f, 2.2))      // even-looking fade (values are linear light)
                    graded = graded.applyingFilter("CIColorMatrix", parameters: [
                        "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
                        "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
                    ])
                }
            }
            request.finish(with: graded, context: nil)
        }
        comp.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        comp.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        comp.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        if forDisplay, #available(macOS 15.0, *) {
            comp.colorTransferFunction = AVVideoTransferFunction_IEC_sRGB   // sRGB shares 709's primaries
        }
        return comp
    }

    /// What the eyedropper measures: the frame exactly as the player's pipeline has it right
    /// before white balance — stabilized (so a click lines up with what you see), before the LUT.
    /// Measuring the pipeline's own frame avoids a separate decode that can read log/HDR
    /// footage differently from the player.
    func makeEyedropperComposition(for asset: AVAsset) -> AVVideoComposition {
        let comp = AVMutableVideoComposition(asset: asset) { [weak self] request in
            let source = request.sourceImage
            guard let self else { request.finish(with: source, context: nil); return }
            var image = source
            if let plan = self.stabilizer?.activePlan {
                image = plan.apply(to: source, at: request.compositionTime)
            }
            request.finish(with: image.cropped(to: source.extent), context: nil)
        }
        comp.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        comp.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        comp.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return comp
    }

    // MARK: The filter chain

    /// Rolls off luminance above `knee` (linear light), scaling RGB together so hue and
    /// saturation are kept. Values above 1.0 (HDR headroom) are pulled back into range.
    private static let highlightRecoveryKernel: CIColorKernel? = CIColorKernel(source: """
        kernel vec4 recoverHighlights(__sample s, float amount, float knee) {
            vec3 c = s.rgb;
            float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
            if (l <= knee || amount <= 0.0) { return s; }
            float x = l - knee;
            float y = x / (1.0 + amount * x / max(1.0 - knee, 0.0001));
            return vec4(c * ((knee + y) / l), s.a);
        }
        """)

    static func apply(_ s: Settings, to input: CIImage) -> CIImage {
        guard !s.isNeutral else { return input }
        var image = input

        // Noise reduction first, so later steps (and sharpening) don't amplify grain.
        if s.denoise > 0, let f = CIFilter(name: "CINoiseReduction") {
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(0.06 * s.denoise / 100, forKey: "inputNoiseLevel")
            f.setValue(0.4, forKey: "inputSharpness")
            image = f.outputImage ?? image
        }

        // (White balance isn't here: it runs before the LUT, in the video composition.)

        // Exposure: ±2 stops.
        if s.exposure != 0, let f = CIFilter(name: "CIExposureAdjust") {
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(s.exposure * range / 50, forKey: kCIInputEVKey)
            image = f.outputImage ?? image
        }

        // Highlight recovery (Highlights −1…−100, full strength), Lightroom-style:
        // 1. compress only the bright tones, keeping their color (skies stay blue, not gray),
        //    which also pulls back HDR detail that sits above "white";
        // 2. restore local contrast so clouds keep their definition.
        if s.highlights < 0 {
            let h = -s.highlights / 100                       // 0…1
            if let kernel = Self.highlightRecoveryKernel {
                let knee = 0.38 - 0.18 * h                    // linear light where compression starts
                image = kernel.apply(extent: image.extent,
                                     arguments: [image, NSNumber(value: 4.5 * h), NSNumber(value: knee)]) ?? image
            }
            if let f = CIFilter(name: "CIHighlightShadowAdjust") {
                f.setValue(image, forKey: kCIInputImageKey)
                f.setValue(1 - 0.55 * h, forKey: "inputHighlightAmount")
                f.setValue(0, forKey: "inputShadowAmount")
                f.setValue(12, forKey: "inputRadius")
                image = f.outputImage ?? image
            }
            if let f = CIFilter(name: "CIUnsharpMask") {      // a touch of large-radius local contrast
                f.setValue(image, forKey: kCIInputImageKey)
                f.setValue(18, forKey: kCIInputRadiusKey)
                f.setValue(0.25 * h, forKey: kCIInputIntensityKey)
                image = f.outputImage ?? image
            }
        }

        // Shadows (lift / crush).
        if s.shadows != 0, let f = CIFilter(name: "CIHighlightShadowAdjust") {
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(s.shadows * range / 100, forKey: "inputShadowAmount")
            f.setValue(1, forKey: "inputHighlightAmount")
            image = f.outputImage ?? image
        }

        // Brightening highlights: lift the top of the tone curve.
        if s.highlights > 0, let f = CIFilter(name: "CIToneCurve") {
            let h = CGFloat(s.highlights * range / 100)
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(CIVector(x: 0, y: 0), forKey: "inputPoint0")
            f.setValue(CIVector(x: 0.25, y: 0.25), forKey: "inputPoint1")
            f.setValue(CIVector(x: 0.5, y: 0.5 + 0.03 * h), forKey: "inputPoint2")
            f.setValue(CIVector(x: 0.75, y: 0.75 + 0.12 * h), forKey: "inputPoint3")
            f.setValue(CIVector(x: 1, y: 1), forKey: "inputPoint4")
            image = f.outputImage ?? image
        }

        // Levels: stretch blackPoint…whitePoint to the full 0…1 range (done on
        // display-gamma values, like Photoshop/Lightroom levels).
        if s.blackPoint > 0.0001 || s.whitePoint < 0.9999 {
            let scale = 1 / max(0.02, s.whitePoint - s.blackPoint)
            let bias = -s.blackPoint * scale
            image = image.applyingFilter("CILinearToSRGBToneCurve")
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: CGFloat(scale), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: CGFloat(scale), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(scale), w: 0),
                "inputBiasVector": CIVector(x: CGFloat(bias), y: CGFloat(bias), z: CGFloat(bias), w: 0)
            ])
            image = image.applyingFilter("CISRGBToneCurveToLinear")
        }

        // Saturation (full strength): −100 = black & white … 2× at +100.
        if s.saturation != 0, let f = CIFilter(name: "CIColorControls") {
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(1 + s.saturation / 100, forKey: kCIInputSaturationKey)
            image = f.outputImage ?? image
        }

        // Vibrance: boosts muted colors more than strong ones (kind to skin tones).
        if s.vibrance != 0, let f = CIFilter(name: "CIVibrance") {
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(s.vibrance / 100, forKey: "inputAmount")
            image = f.outputImage ?? image
        }

        // Sharpen last: brightness detail only, so colors don't fringe.
        if s.sharpen > 0, let f = CIFilter(name: "CISharpenLuminance") {
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(1.2 * s.sharpen / 100, forKey: kCIInputSharpnessKey)
            f.setValue(1.6, forKey: "inputRadius")
            image = f.outputImage ?? image
        }
        return image
    }

    static func whiteBalance(_ image: CIImage, temperature: Double, tint: Double) -> CIImage {
        guard let f = CIFilter(name: "CITemperatureAndTint") else { return image }
        f.setValue(image, forKey: kCIInputImageKey)
        // Scene light guess vs. target: a higher "neutral" Kelvin warms the picture.
        f.setValue(CIVector(x: CGFloat(6500 + temperature * range * 35), y: CGFloat(tint * range)), forKey: "inputNeutral")
        f.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")
        return f.outputImage ?? image
    }

    // MARK: Eyedropper

    /// Finds the Color/Tint values that make the picked color come out neutral gray at the
    /// END of white balance + LUT — so it's right whatever the LUT does to color.
    /// The picked color is in Rec. 709 video values (what the eyedropper composition outputs).
    static func solveWhiteBalance(red r: CGFloat, green g: CGFloat, blue b: CGFloat, lut: CubeLUT?) -> (temperature: Double, tint: Double) {
        guard let sRGB = CGColorSpace(name: CGColorSpace.itur_709),
              let color = CIColor(red: r, green: g, blue: b, alpha: 1, colorSpace: sRGB) else { return (0, 0) }
        let context = CIContext(options: [.cacheIntermediates: false])
        let pixel = CGRect(x: 0, y: 0, width: 1, height: 1)
        let base = CIImage(color: color).cropped(to: pixel)

        func castError(_ t: Double, _ ti: Double) -> Double {
            var px = [Float](repeating: 0, count: 4)
            var img = whiteBalance(base.clampedToExtent(), temperature: t, tint: ti)
            if let lut { img = lut.apply(to: img) }
            context.render(img.cropped(to: pixel), toBitmap: &px, rowBytes: 16,
                           bounds: pixel, format: .RGBAf, colorSpace: sRGB)
            let (R, G, B) = (Double(px[0]), Double(px[1]), Double(px[2]))
            let mean = max((R + G + B) / 3, 0.001)
            return ((R - G) * (R - G) + (B - G) * (B - G)) / (mean * mean)
        }

        var best = (t: 0.0, ti: 0.0, err: castError(0, 0))
        // Coarse sweep, then two finer passes around the best spot.
        for (step, span) in [(10.0, 100.0), (2.0, 10.0), (0.5, 2.0)] {
            let center = best
            var t = max(-100, center.t - span)
            while t <= min(100, center.t + span) {
                var ti = max(-100, center.ti - span)
                while ti <= min(100, center.ti + span) {
                    let e = castError(t, ti)
                    if e < best.err { best = (t, ti, e) }
                    ti += step
                }
                t += step
            }
        }
        return (best.t.rounded(), best.ti.rounded())
    }
}

/// Transparent layer over the video while the eyedropper is active.
final class EyedropperView: NSView {
    var onPick: ((NSPoint) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) { onPick?(convert(event.locationInWindow, from: nil)) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }   // Esc
    }
}

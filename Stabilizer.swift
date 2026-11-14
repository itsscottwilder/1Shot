// Stabilizer — analyzes camera shake once (frame-to-frame block matching on small grayscale
// frames), then removes jitter with adjustable smoothness and a crop limit. Applied to every
// frame in the color stage, so the preview and the export match.

import Foundation
import AVFoundation
import CoreImage
import Accelerate

final class Stabilizer {
    enum StabilizeError: LocalizedError {
        case noVideo, cancelled, failed(String)
        var errorDescription: String? {
            switch self {
            case .noVideo: return "This file has no video track."
            case .cancelled: return "Analysis was cancelled."
            case .failed(let m): return m
            }
        }
    }

    /// Per-frame corrections ready to apply (immutable, swapped in atomically).
    final class Plan {
        let times: [Double]
        let shiftX: [CGFloat]      // fraction of frame width
        let shiftY: [CGFloat]      // fraction of frame height
        let zoom: CGFloat

        init(times: [Double], shiftX: [CGFloat], shiftY: [CGFloat], zoom: CGFloat) {
            self.times = times
            self.shiftX = shiftX
            self.shiftY = shiftY
            self.zoom = zoom
        }

        func apply(to image: CIImage, at time: CMTime) -> CIImage {
            guard !times.isEmpty else { return image }
            let i = index(near: time.seconds)
            let e = image.extent
            let move = CGAffineTransform(translationX: shiftX[i] * e.width, y: shiftY[i] * e.height)
            let scale = CGAffineTransform(translationX: -e.midX, y: -e.midY)
                .concatenating(CGAffineTransform(scaleX: zoom, y: zoom))
                .concatenating(CGAffineTransform(translationX: e.midX, y: e.midY))
            return image.transformed(by: move.concatenating(scale))
        }

        private func index(near t: Double) -> Int {
            var lo = 0, hi = times.count - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if times[mid] < t { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0, abs(times[lo - 1] - t) < abs(times[lo] - t) { return lo - 1 }
            return lo
        }
    }

    // Settings (main thread)
    var smoothness: Double = 50      // 0…100 (100 = Lock)
    var maxCrop: Double = 10         // percent

    private let lock = NSLock()
    private var _plan: Plan?
    private var _enabled = false
    private var _cancelled = false
    private var path: (times: [Double], x: [Double], y: [Double])?

    var isAnalyzed: Bool { path != nil }

    var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _enabled }
        set { lock.lock(); _enabled = newValue; lock.unlock() }
    }

    /// What the color stage should apply right now (nil = no stabilization).
    var activePlan: Plan? {
        lock.lock(); defer { lock.unlock() }
        return _enabled ? _plan : nil
    }

    var zoomPercent: Double? {
        lock.lock(); defer { lock.unlock() }
        return _plan.map { Double(($0.zoom - 1) * 100) }
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }

    func reset() {
        lock.lock()
        _cancelled = true
        _plan = nil
        _enabled = false
        lock.unlock()
        path = nil
    }

    // MARK: Analysis

    /// Measures frame-to-frame shake across the whole clip. Callbacks arrive on the main thread.
    func analyze(asset: AVAsset, progress: @escaping (Double) -> Void,
                 completion: @escaping (Error?) -> Void) {
        lock.lock(); _cancelled = false; lock.unlock()
        Task {
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let geometry = try? await track.load(.naturalSize, .preferredTransform),
                  let duration = try? await asset.load(.duration) else {
                await MainActor.run { completion(StabilizeError.noVideo) }
                return
            }
            let upright = geometry.0.applying(geometry.1)
            let fullW = abs(upright.width), fullH = abs(upright.height)
            let scale = 256 / max(fullW, fullH, 1)        // small frames: fast and plenty accurate
            let small = CGSize(width: max(16, (fullW * scale / 2).rounded() * 2),
                               height: max(16, (fullH * scale / 2).rounded() * 2))

            // Small, upright frames for fast analysis.
            let comp = AVMutableVideoComposition(asset: asset) { request in
                request.finish(with: request.sourceImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
                               context: nil)
            }
            comp.renderSize = small

            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.measure(asset: asset, track: track, composition: comp, size: small,
                                          duration: duration.seconds, progress: progress)
                DispatchQueue.main.async {
                    switch result {
                    case .success(let p):
                        self.path = p
                        self.enabled = true
                        self.rebuildPlan()
                        completion(nil)
                    case .failure(let error):
                        completion(error)
                    }
                }
            }
        }
    }

    private func measure(asset: AVAsset, track: AVAssetTrack, composition: AVVideoComposition, size: CGSize,
                         duration: Double, progress: @escaping (Double) -> Void)
        -> Result<(times: [Double], x: [Double], y: [Double]), Error> {
        do {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            output.videoComposition = composition
            // Must copy: we hold on to the previous frame, and a recycled buffer would make
            // "previous" and "current" the same image (= no movement measured).
            output.alwaysCopiesSampleData = true
            guard reader.canAdd(output) else { return .failure(StabilizeError.failed("Couldn't read the video.")) }
            reader.add(output)
            guard reader.startReading() else {
                return .failure(reader.error ?? StabilizeError.failed("Couldn't start reading the video."))
            }

            var times: [Double] = [], xs: [Double] = [], ys: [Double] = []
            var previous: [Float]?
            var x = 0.0, y = 0.0
            let w = Int(size.width), h = Int(size.height)
            var measured = 0, skipped = 0
            var travel = 0.0

            // One pool per frame: this loop runs for the whole clip inside a single block, so
            // anything autoreleased along the way would otherwise pile up until it ends.
            while let sample = autoreleasepool(invoking: { output.copyNextSampleBuffer() }) {
                if isCancelled { reader.cancelReading(); return .failure(StabilizeError.cancelled) }
                guard let pixels = CMSampleBufferGetImageBuffer(sample),
                      let gray = Self.grayscale(pixels, width: w, height: h) else { continue }
                let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds

                if let previous {
                    // How far the picture moved since the previous frame (pixels, y pointing down).
                    let (dx, dy) = Self.estimateShift(from: previous, to: gray, width: w, height: h)
                    let fx = Double(dx) / Double(w), fy = Double(dy) / Double(h)
                    // Ignore huge jumps (scene cuts, glitches) rather than chasing them.
                    if abs(fx) < 0.2 && abs(fy) < 0.2 {
                        x += fx          // content position, image x → right
                        y -= fy          // flip to Core Image's y-up coordinates
                        measured += 1
                        travel += abs(fx) + abs(fy)
                    } else {
                        skipped += 1
                    }
                }
                times.append(t)
                xs.append(x)
                ys.append(y)
                previous = gray
                if times.count % 15 == 0, duration > 0 {
                    let p = min(1, t / duration)
                    DispatchQueue.main.async { progress(p) }
                }
            }
            if reader.status == .failed {
                return .failure(reader.error ?? StabilizeError.failed("Reading the video failed."))
            }
            NSLog("1Shot: stabilize analysis — frames \(times.count) (\(w)×\(h)), measured \(measured), skipped jumps \(skipped), avg shake \(String(format: "%.5f", travel / Double(max(measured, 1)))) of frame")
            guard times.count > 2 else { return .failure(StabilizeError.failed("The clip is too short to stabilize.")) }
            return .success((times, xs, ys))
        } catch {
            return .failure(error)
        }
    }

    // MARK: Motion estimation (block matching)

    /// BGRA frame → brightness values (0…1), with the frame's average removed so
    /// auto-exposure changes don't look like movement.
    private static func grayscale(_ buffer: CVPixelBuffer, width: Int, height: Int) -> [Float]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = min(width, CVPixelBufferGetWidth(buffer))
        let h = min(height, CVPixelBufferGetHeight(buffer))
        guard w == width, h == height else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let src = base.assumingMemoryBound(to: UInt8.self)
        var out = [Float](repeating: 0, count: w * h)
        var sum: Float = 0
        for yy in 0..<h {
            let row = src + yy * rowBytes
            for xx in 0..<w {
                let p = row + xx * 4
                let v = (0.0722 * Float(p[0]) + 0.7152 * Float(p[1]) + 0.2126 * Float(p[2])) / 255
                out[yy * w + xx] = v
                sum += v
            }
        }
        let mean = sum / Float(w * h)
        for i in 0..<out.count { out[i] -= mean }
        return out
    }

    /// Finds (dx, dy) so that `current` shifted by it best matches `previous`.
    /// Coarse search on a half-size copy, then a fine search, then sub-pixel refinement.
    private static func estimateShift(from previous: [Float], to current: [Float],
                                      width w: Int, height h: Int) -> (Float, Float) {
        let hw = w / 2, hh = h / 2
        let prevHalf = halfSize(previous, w, h)
        let curHalf = halfSize(current, w, h)

        // Coarse: ±12 px at half size (≈ ±24 px full, about 10% of the frame).
        let coarseRadius = 12
        var best = (dx: 0, dy: 0, cost: Float.greatestFiniteMagnitude)
        prevHalf.withUnsafeBufferPointer { a in
            curHalf.withUnsafeBufferPointer { b in
                for dy in -coarseRadius...coarseRadius {
                    for dx in -coarseRadius...coarseRadius {
                        let c = sad(a.baseAddress!, b.baseAddress!, w: hw, h: hh, dx: dx, dy: dy,
                                    margin: coarseRadius + 1, step: 2)
                        if c < best.cost { best = (dx, dy, c) }
                    }
                }
            }
        }

        // Fine: ±2 px around the coarse answer at full size, then sub-pixel.
        let cx = best.dx * 2, cy = best.dy * 2
        let fineRadius = 2
        let margin = coarseRadius * 2 + fineRadius + 2
        var costs = [[Float]](repeating: [Float](repeating: 0, count: 2 * fineRadius + 1), count: 2 * fineRadius + 1)
        var fine = (dx: cx, dy: cy, cost: Float.greatestFiniteMagnitude)
        previous.withUnsafeBufferPointer { a in
            current.withUnsafeBufferPointer { b in
                for oy in -fineRadius...fineRadius {
                    for ox in -fineRadius...fineRadius {
                        let c = sad(a.baseAddress!, b.baseAddress!, w: w, h: h, dx: cx + ox, dy: cy + oy,
                                    margin: margin, step: 1)
                        costs[oy + fineRadius][ox + fineRadius] = c
                        if c < fine.cost { fine = (cx + ox, cy + oy, c) }
                    }
                }
            }
        }
        let ix = fine.dx - cx + fineRadius, iy = fine.dy - cy + fineRadius
        var subX: Float = 0, subY: Float = 0
        if ix > 0 && ix < 2 * fineRadius {
            subX = parabola(costs[iy][ix - 1], costs[iy][ix], costs[iy][ix + 1])
        }
        if iy > 0 && iy < 2 * fineRadius {
            subY = parabola(costs[iy - 1][ix], costs[iy][ix], costs[iy + 1][ix])
        }
        return (Float(fine.dx) + subX, Float(fine.dy) + subY)
    }

    /// Sum of absolute differences between previous(x, y) and current(x + dx, y + dy).
    private static func sad(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, w: Int, h: Int,
                            dx: Int, dy: Int, margin: Int, step: Int) -> Float {
        guard margin * 2 < w, margin * 2 < h else { return .greatestFiniteMagnitude }
        var sum: Float = 0
        var count: Float = 0
        var y = margin
        while y < h - margin {
            let ra = a + y * w
            let rb = b + (y + dy) * w + dx
            var x = margin
            while x < w - margin {
                sum += abs(ra[x] - rb[x])
                x += step
            }
            count += 1
            y += step
        }
        return count > 0 ? sum : .greatestFiniteMagnitude
    }

    private static func halfSize(_ img: [Float], _ w: Int, _ h: Int) -> [Float] {
        let hw = w / 2, hh = h / 2
        var out = [Float](repeating: 0, count: hw * hh)
        for y in 0..<hh {
            for x in 0..<hw {
                let i = (2 * y) * w + 2 * x
                out[y * hw + x] = (img[i] + img[i + 1] + img[i + w] + img[i + w + 1]) * 0.25
            }
        }
        return out
    }

    /// Sub-pixel offset of a minimum from three neighboring costs.
    private static func parabola(_ left: Float, _ mid: Float, _ right: Float) -> Float {
        let denom = left - 2 * mid + right
        guard denom > 0.000_001 else { return 0 }
        return max(-0.5, min(0.5, 0.5 * (left - right) / denom))
    }

    // MARK: Smoothing (main thread, fast)

    /// Recomputes corrections from the measured path and current Smoothness / Max Crop.
    func rebuildPlan() {
        guard let path, path.times.count > 2 else {
            lock.lock(); _plan = nil; lock.unlock()
            return
        }
        let n = path.times.count
        let span = max(0.001, path.times[n - 1] - path.times[0])
        let fps = Double(n - 1) / span

        let smoothX: [Double], smoothY: [Double]
        if smoothness >= 99.5 {
            // Lock: hold the average position, like a tripod.
            let mx = path.x.reduce(0, +) / Double(n)
            let my = path.y.reduce(0, +) / Double(n)
            smoothX = Array(repeating: mx, count: n)
            smoothY = Array(repeating: my, count: n)
        } else {
            // Gaussian smoothing: from ~1 frame (light) up to ~4 seconds (very smooth).
            let sigma = max(0.8, pow(4 * fps, smoothness / 99))
            smoothX = Self.gaussian(path.x, sigma: sigma)
            smoothY = Self.gaussian(path.y, sigma: sigma)
        }

        var cx = (0..<n).map { CGFloat(smoothX[$0] - path.x[$0]) }
        var cy = (0..<n).map { CGFloat(smoothY[$0] - path.y[$0]) }
        var biggest = max(cx.map(abs).max() ?? 0, cy.map(abs).max() ?? 0)

        // Respect Max Crop: zoom never exceeds 1 + maxCrop%.
        let limit = CGFloat(maxCrop / 100 / 2)
        if biggest > limit, biggest > 0 {
            let k = limit / biggest
            cx = cx.map { $0 * k }
            cy = cy.map { $0 * k }
            biggest = limit
        }
        let plan = Plan(times: path.times, shiftX: cx, shiftY: cy, zoom: 1 + 2 * biggest)
        lock.lock(); _plan = plan; lock.unlock()
    }

    private static func gaussian(_ values: [Double], sigma: Double) -> [Double] {
        let n = values.count
        let radius = min(n, max(1, Int((3 * sigma).rounded(.up))))
        let weights = (0...radius).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        var out = [Double](repeating: 0, count: n)
        // Near the two ends the window is cut short, so the weights are re-totalled for each frame.
        func edge(_ i: Int) {
            var sum = 0.0, total = 0.0
            let lo = max(0, i - radius), hi = min(n - 1, i + radius)
            for j in lo...hi {
                let w = weights[abs(j - i)]
                sum += values[j] * w
                total += w
            }
            out[i] = sum / total
        }
        let interior = n - 2 * radius       // frames with the whole window inside the clip
        guard interior > 0 else {
            for i in 0..<n { edge(i) }
            return out
        }
        for i in 0..<radius { edge(i) }
        for i in (n - radius)..<n { edge(i) }
        // Everything in between uses the same full window: one vectorized pass (Accelerate) instead
        // of frames × window multiplications in a plain loop. This runs on every slider tick.
        let kernel = weights.reversed() + weights.dropFirst()        // symmetric, 2 × radius + 1 long
        var total = 0.0
        for w in kernel { total += w }
        values.withUnsafeBufferPointer { v in
            kernel.withUnsafeBufferPointer { k in
                out.withUnsafeMutableBufferPointer { o in
                    vDSP_convD(v.baseAddress!, 1, k.baseAddress!, 1, o.baseAddress! + radius, 1,
                               vDSP_Length(interior), vDSP_Length(kernel.count))
                    vDSP_vsdivD(o.baseAddress! + radius, 1, &total, o.baseAddress! + radius, 1, vDSP_Length(interior))
                }
            }
        }
        return out
    }
}

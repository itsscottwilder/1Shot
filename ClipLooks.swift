// ClipLooks — pipeline step 2 (3.4.0): lets Claude compare how the Assets-tab clips look, so clips
// shot the same way share a Visual Design group and a clip that looks different gets its own.
// For each clip: three frames as recorded (10 %, 50 %, 90 % of its in/out) on one contact sheet,
// plus a rough difference score for every pair of clips from tiny averaged thumbnails.

import AVFoundation
import Cocoa

enum ClipLooks {
    struct Clip {
        let number: Int
        let name: String
        let group: String
        let frames: [CGImage]
        let signature: [Double]     // 16×9 RGB, averaged over the frames, 0–255
    }

    static let positions = [0.1, 0.5, 0.9]

    /// Grabs the frames for one clip file between its in and out points.
    static func frames(url: URL, inPoint: Double, outPoint: Double) async -> [CGImage] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        var out: [CGImage] = []
        for p in positions {
            let t = CMTime(seconds: inPoint + (outPoint - inPoint) * p, preferredTimescale: 600)
            if let img = try? await generator.image(at: t).image { out.append(img) }
        }
        return out
    }

    /// The frames shrunk to 16×9 and averaged: a fingerprint of framing, light and colour.
    static func signature(_ images: [CGImage]) -> [Double] {
        let w = 16, h = 9
        var sum = [Double](repeating: 0, count: w * h * 3)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return sum }
        var used = 0
        for img in images {
            var px = [UInt8](repeating: 0, count: w * h * 4)
            let drawn: Bool = px.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
                ctx.interpolationQuality = .medium
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard drawn else { continue }
            used += 1
            for i in 0..<(w * h) {
                for c in 0..<3 { sum[i * 3 + c] += Double(px[i * 4 + c]) }
            }
        }
        return used > 0 ? sum.map { $0 / Double(used) } : sum
    }

    /// Mean absolute difference between two fingerprints, 0 (identical) to 255.
    static func difference(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 255 }
        return zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(a.count)
    }

    /// One row per clip: its number, file and group, then its three frames.
    static func sheet(_ clips: [Clip]) -> (data: Data, width: Int, height: Int)? {
        let thumbW = 400, thumbH = 225, gap = 12, label = 30
        let cols = positions.count
        let width = gap + cols * (thumbW + gap)
        let rowH = label + thumbH + gap
        let height = gap + clips.count * rowH
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 17), .foregroundColor: NSColor.white]
        for (row, clip) in clips.enumerated() {
            let top = height - gap - row * rowH
            NSAttributedString(string: "\(clip.number)  \(clip.name)  ·  \(clip.group)", attributes: attrs)
                .draw(at: NSPoint(x: gap, y: top - label + 6))
            for (col, img) in clip.frames.enumerated() {
                let box = CGRect(x: gap + col * (thumbW + gap), y: top - label - thumbH, width: thumbW, height: thumbH)
                let scale = min(box.width / CGFloat(img.width), box.height / CGFloat(img.height))
                let w = CGFloat(img.width) * scale, h = CGFloat(img.height) * scale
                ctx.draw(img, in: CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = ctx.makeImage() else { return nil }
        return MCP.jpeg(image, maxWidth: width)
    }
}

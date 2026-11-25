// MeterView — stereo output meter: peak bar, peak-hold tick and a latching
// clip light per channel, on a −60…0 dBFS scale.

import Cocoa

final class MeterView: NSView {
    static let height: CGFloat = 58

    private let floorDB: Float = -60
    private var rmsDB: [Float] = [-60, -60]        // displayed (with ballistics)
    private var peakDB: [Float] = [-60, -60]
    private var holdDB: [Float] = [-60, -60]
    private var holdAge: [Double] = [0, 0]
    private var clipped: [Bool] = [false, false]
    private var lastUpdate = ProcessInfo.processInfo.systemUptime

    override var isFlipped: Bool { true }

    /// Feed raw linear readings (0…1+) about 30× a second.
    func update(peak: [Float], rms: [Float]) {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = Float(min(0.2, now - lastUpdate))
        lastUpdate = now
        let before = (peakDB, holdDB, clipped)
        for c in 0..<2 {
            let p = toDB(c < peak.count ? peak[c] : 0)
            let r = toDB(c < rms.count ? rms[c] : 0)
            // Instant rise, smooth fall (about 24 dB per second).
            rmsDB[c] = r >= rmsDB[c] ? r : max(r, rmsDB[c] - 24 * dt)
            peakDB[c] = p >= peakDB[c] ? p : max(p, peakDB[c] - 24 * dt)   // instant rise, ~24 dB/s fall
            if p >= holdDB[c] {
                holdDB[c] = p
                holdAge[c] = 0
            } else {
                holdAge[c] += Double(dt)
                if holdAge[c] > 1.5 { holdDB[c] = max(peakDB[c], holdDB[c] - 30 * dt) }
            }
            // True clipping = reaching 0 dBFS. (The limiter's −0.1 dB ceiling must NOT light this.)
            if c < peak.count, peak[c] >= 0.9999 { clipped[c] = true }
        }
        // Redraw only when something on screen moved (at rest, nothing does).
        if before.0 != peakDB || before.1 != holdDB || before.2 != clipped { needsDisplay = true }
    }

    private func toDB(_ linear: Float) -> Float {
        linear <= 0.000_001 ? floorDB : max(floorDB, 20 * log10(linear))
    }

    // MARK: Geometry

    private let barHeight: CGFloat = 11
    private let labelWidth: CGFloat = 12
    private let clipWidth: CGFloat = 12

    private func barRect(_ channel: Int) -> NSRect {
        NSRect(x: labelWidth, y: 2 + CGFloat(channel) * (barHeight + 5),
               width: bounds.width - labelWidth - clipWidth - 4, height: barHeight)
    }

    private func clipRect(_ channel: Int) -> NSRect {
        let bar = barRect(channel)
        return NSRect(x: bar.maxX + 4, y: bar.minY, width: clipWidth, height: barHeight)
    }

    private func x(forDB db: Float, in bar: NSRect) -> CGFloat {
        bar.minX + CGFloat((db - floorDB) / -floorDB) * bar.width
    }

    // MARK: Drawing

    // The labels never change, so they are built once (not on every redraw).
    private static let channelLabels: [NSAttributedString] = ["L", "R"].map {
        NSAttributedString(string: $0, attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
    }
    private static let scaleLabels: [(db: Float, text: NSAttributedString, width: CGFloat)] =
        ([-48, -36, -24, -18, -12, -6, -3, 0] as [Float]).map { db in
            let text = NSAttributedString(string: "\(Int(db))", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor])
            return (db, text, text.size().width)
        }

    override func draw(_ dirtyRect: NSRect) {
        let green = NSColor.systemGreen, yellow = NSColor.systemYellow, red = NSColor.systemRed

        for c in 0..<2 {
            let bar = barRect(c)
            Self.channelLabels[c].draw(at: NSPoint(x: 1, y: bar.minY - 1))

            NSColor(white: 0.1, alpha: 1).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()

            // Peak bar, colored by zone: green to −18, yellow to −6, red above.
            let level = x(forDB: peakDB[c], in: bar)
            let zones: [(Float, Float, NSColor)] = [(floorDB, -18, green), (-18, -6, yellow), (-6, 0, red)]
            for (lo, hi, color) in zones {
                let x0 = x(forDB: lo, in: bar), x1 = min(level, x(forDB: hi, in: bar))
                if x1 > x0 {
                    color.withAlphaComponent(0.85).setFill()
                    NSRect(x: x0, y: bar.minY + 1, width: x1 - x0, height: bar.height - 2).fill()
                }
            }

            // Held peak tick
            if holdDB[c] > floorDB {
                (holdDB[c] > -6 ? red : NSColor(white: 0.85, alpha: 1)).setFill()
                NSRect(x: x(forDB: holdDB[c], in: bar) - 1, y: bar.minY, width: 2, height: bar.height).fill()
            }

            // Clip light
            (clipped[c] ? red : NSColor(white: 0.18, alpha: 1)).setFill()
            NSBezierPath(roundedRect: clipRect(c), xRadius: 2, yRadius: 2).fill()
        }

        // dB scale
        let bar = barRect(1)
        for label in Self.scaleLabels {
            let px = x(forDB: label.db, in: bar)
            NSColor(white: 1, alpha: 0.25).setFill()
            NSRect(x: px - 0.5, y: bar.maxY + 2, width: 1, height: 3).fill()
            label.text.draw(at: NSPoint(x: px - label.width / 2, y: bar.maxY + 5))
        }
    }

    // Click a clip light (or anywhere on the meter) to reset it.
    override func mouseDown(with event: NSEvent) {
        clipped = [false, false]
        holdDB = [floorDB, floorDB]
        needsDisplay = true
    }
}

// Draws ProjectIcon.png (1024 × 1024): the icon Finder shows for .1shot project files.
// A white page with a folded corner, the 1Shot app icon in the middle and a "1SHOT" label.
// Run it again after changing AppIcon.png (build.sh turns ProjectIcon.png into ProjectIcon.icns).
//   xcrun swift Tools/make-project-icon.swift AppIcon.png ProjectIcon.png
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let appIcon = NSImage(contentsOfFile: args[1]) else {
    print("usage: make-project-icon.swift AppIcon.png ProjectIcon.png"); exit(1)
}
let size: CGFloat = 1024
let green = NSColor(srgbRed: 0.24, green: 0.33, blue: 0.11, alpha: 1)      // the icon's olive green
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// The page: macOS document proportions, centred, with a folded top-right corner.
let page = NSRect(x: 160, y: 60, width: 704, height: 904)
let fold: CGFloat = 190
let outline = NSBezierPath()
outline.move(to: NSPoint(x: page.minX + 28, y: page.minY))
outline.line(to: NSPoint(x: page.maxX - 28, y: page.minY))
outline.curve(to: NSPoint(x: page.maxX, y: page.minY + 28), controlPoint1: NSPoint(x: page.maxX - 12, y: page.minY), controlPoint2: NSPoint(x: page.maxX, y: page.minY + 12))
outline.line(to: NSPoint(x: page.maxX, y: page.maxY - fold))
outline.line(to: NSPoint(x: page.maxX - fold, y: page.maxY))
outline.line(to: NSPoint(x: page.minX + 28, y: page.maxY))
outline.curve(to: NSPoint(x: page.minX, y: page.maxY - 28), controlPoint1: NSPoint(x: page.minX + 12, y: page.maxY), controlPoint2: NSPoint(x: page.minX, y: page.maxY - 12))
outline.line(to: NSPoint(x: page.minX, y: page.minY + 28))
outline.curve(to: NSPoint(x: page.minX + 28, y: page.minY), controlPoint1: NSPoint(x: page.minX, y: page.minY + 12), controlPoint2: NSPoint(x: page.minX + 12, y: page.minY))
outline.close()

// Soft shadow under the page.
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSColor(white: 0.985, alpha: 1).setFill()
outline.fill()
NSGraphicsContext.restoreGraphicsState()
NSColor(white: 0.80, alpha: 1).setStroke()
outline.lineWidth = 3
outline.stroke()

// The folded corner.
let flap = NSBezierPath()
flap.move(to: NSPoint(x: page.maxX - fold, y: page.maxY))
flap.line(to: NSPoint(x: page.maxX - fold + 14, y: page.maxY - fold + 30))
flap.curve(to: NSPoint(x: page.maxX - fold + 34, y: page.maxY - fold + 10), controlPoint1: NSPoint(x: page.maxX - fold + 16, y: page.maxY - fold + 16), controlPoint2: NSPoint(x: page.maxX - fold + 20, y: page.maxY - fold + 12))
flap.line(to: NSPoint(x: page.maxX, y: page.maxY - fold))
flap.close()
NSColor(white: 0.88, alpha: 1).setFill()
flap.fill()
NSColor(white: 0.78, alpha: 1).setStroke()
flap.lineWidth = 3
flap.stroke()

// The app icon, its rounded square cropped out of the PNG's transparent margin.
let iconSide: CGFloat = 470
let iconRect = NSRect(x: page.midX - iconSide / 2, y: 330, width: iconSide, height: iconSide)
let src = NSRect(x: 100, y: 100, width: 824, height: 824)     // the squircle inside AppIcon.png
appIcon.draw(in: iconRect, from: src, operation: .sourceOver, fraction: 1)

// The label.
let label = "1SHOT" as NSString
let font = NSFont.systemFont(ofSize: 120, weight: .heavy)
let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: green, .kern: 6]
let textSize = label.size(withAttributes: attrs)
label.draw(at: NSPoint(x: page.midX - textSize.width / 2, y: 130), withAttributes: attrs)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("Wrote \(args[2])")

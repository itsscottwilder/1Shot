// VisualGroups — 3.2: Visual Design per clip. Every A-roll clip (Assets) and every B-roll shot
// belongs to a Visual Design group; a group carries its own look (Color sliders, Levels, white
// balance, Camera and Creative LUT) and its own header colour. Two groups always exist:
//   "aroll"  Default — every imported clip starts here; the project's original look (what the Visual Design tab always had)
//   "broll"  B-roll — starts neutral, so stock footage looks as it did before
// Make a group per clip for one panel per video, or put several clips in one group to share a look.
// Stabilize and Fade to black stay whole-video settings.

import Cocoa

struct VisualGroup: Codable, Equatable {
    var id: String
    var name: String
    var colorIndex: Int
    var look: VisualDesignPanel.Look? = nil      // nil = neutral (no grade, no LUTs)

    static let arollID = "aroll"
    static let brollID = "broll"

    static let defaults: [VisualGroup] = [
        VisualGroup(id: arollID, name: "Default", colorIndex: 0),
        VisualGroup(id: brollID, name: "B-roll", colorIndex: 1)
    ]

    /// Header / timeline colours, one per group (cycles after eight).
    static let palette: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.62, blue: 0.04, alpha: 1),   // orange
        NSColor(srgbRed: 0.39, green: 0.82, blue: 1.00, alpha: 1),   // sky
        NSColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1),   // green
        NSColor(srgbRed: 0.75, green: 0.35, blue: 0.95, alpha: 1),   // purple
        NSColor(srgbRed: 1.00, green: 0.84, blue: 0.04, alpha: 1),   // yellow
        NSColor(srgbRed: 1.00, green: 0.22, blue: 0.37, alpha: 1),   // pink-red
        NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1),   // blue
        NSColor(srgbRed: 0.67, green: 0.56, blue: 0.41, alpha: 1)    // tan
    ]

    var color: NSColor { Self.palette[((colorIndex % Self.palette.count) + Self.palette.count) % Self.palette.count] }
}

/// The clip picked on the timeline in the Visual Design tab.
enum VisualClip: Equatable {
    case aroll(Int)      // index among the A-roll's included clips (0 for a single-video project)
    case broll(Int)      // index in the B-roll list
}

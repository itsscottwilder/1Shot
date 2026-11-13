// 1shot-mcp — the MCP server the Claude desktop app starts (version 2.4).
//
// It speaks MCP (JSON-RPC over stdin/stdout) to Claude and passes each tool call to the running
// 1Shot app over its private local socket (see ControlServer.swift). If the app isn't
// running, it opens it. Nothing goes over the network.
//
//   1shot-mcp            run as an MCP server (what Claude does)
//   1shot-mcp --install  add 1Shot to the Claude desktop app's settings (build.sh does this)
//   1shot-mcp --test     check that the app answers (opens it if needed) and print its status

import Foundation

let serverVersion = "2.7.0"
let bundleID = "com.itsscottwilder.timecodeplayer"
let supportPath = NSHomeDirectory() + "/Library/Application Support/1Shot"
let socketPath = supportPath + "/mcp.sock"
let styleGuidesPath = NSHomeDirectory() + "/Movies/1Shot/Style Guides"

struct HelperError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func logLine(_ s: String) {
    FileHandle.standardError.write(Data(("1shot-mcp: " + s + "\n").utf8))
}

// MARK: - Talking to the app

enum App {
    static func connect() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in raw.copyBytes(from: bytes) }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        guard ok == 0 else { close(fd); return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 120, tv_usec: 0)     // the app's own waits are 45 s at most
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    /// Opens the copy of the app that ran last (it writes its path at launch), or finds it by bundle ID.
    static func launch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        let recorded = (try? String(contentsOfFile: supportPath + "/app-path", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let path = recorded, !path.isEmpty, FileManager.default.fileExists(atPath: path) {
            p.arguments = [path]
        } else {
            p.arguments = ["-b", bundleID]
        }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { logLine("couldn't open the app: \(error)") }
    }

    static func connectOrLaunch() throws -> Int32 {
        if let fd = connect() { return fd }
        logLine("1Shot isn't running; opening it")
        launch()
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            usleep(250_000)
            if let fd = connect() { return fd }
        }
        throw HelperError("1Shot didn't open (or it's a version before 2.4). Open it once from Finder, then try again.")
    }

    /// Sends one command and waits for its answer.
    static func call(_ command: String, _ args: [String: Any]) throws -> Any {
        let fd = try connectOrLaunch()
        defer { close(fd) }
        let request: [String: Any] = ["id": 1, "command": command, "args": args]
        guard JSONSerialization.isValidJSONObject(request) else { throw HelperError("Those arguments aren't valid JSON.") }
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(0x0A)
        let sent = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard var p = raw.baseAddress else { return false }
            var left = raw.count
            while left > 0 {
                let n = write(fd, p, left)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                p = p.advanced(by: n)
                left -= n
            }
            return true
        }
        guard sent else { throw HelperError("Couldn't reach 1Shot.") }

        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while reply.firstIndex(of: 0x0A) == nil {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                throw HelperError("1Shot didn't answer for 2 minutes. A dialog may be open in the app; ask the user to check it.")
            }
            if n <= 0 { throw HelperError("1Shot closed the connection (did it quit?).") }
            reply.append(contentsOf: chunk[0..<n])
        }
        let line = reply.prefix(upTo: reply.firstIndex(of: 0x0A)!)
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            throw HelperError("1Shot sent an answer that isn't JSON.")
        }
        if object["ok"] as? Bool == true { return object["result"] ?? NSNull() }
        throw HelperError(object["error"] as? String ?? "1Shot reported an error.")
    }
}

// MARK: - Style guides (read straight from the folder; the app doesn't need to be open)

func readStyleGuide(_ args: [String: Any]) throws -> Any {
    let fm = FileManager.default
    let files = ((try? fm.contentsOfDirectory(atPath: styleGuidesPath)) ?? [])
        .filter { $0.lowercased().hasSuffix(".md") && !$0.contains("(previous v") }
        .sorted()
    guard let name = args["name"] as? String, !name.isEmpty else {
        return ["folder": styleGuidesPath, "guides": files.map { ($0 as NSString).deletingPathExtension }] as [String: Any]
    }
    let wanted = name.lowercased().hasSuffix(".md") ? name.lowercased() : name.lowercased() + ".md"
    guard let file = files.first(where: { $0.lowercased() == wanted }) else {
        throw HelperError("No style guide named “\(name)”. Guides: \(files.map { ($0 as NSString).deletingPathExtension }.joined(separator: ", ")).")
    }
    let text = try String(contentsOfFile: styleGuidesPath + "/" + file, encoding: .utf8)
    return ["text": text] as [String: Any]
}

// MARK: - Tools

func prop(_ type: Any, _ description: String) -> [String: Any] { ["type": type, "description": description] }

let numberOrString: [String] = ["number", "string"]
let objectOrString: [String] = ["object", "string"]

let tool_status: [String: Any] = [
    "name": "status",
    "description": "What 1Shot has open right now (in the window you work in; openProjects lists every open project): project, clip (length, fps), trim, playhead, how many cuts/zooms/B-roll, drawers, and any running job. Opens the app if it isn't running. Pass wait (up to 45 s) to wait for a running job (create_transcript, B-roll downloads) to finish.",
    "inputSchema": ["type": "object", "properties": [
        "wait": prop("number", "Seconds to wait for a running job to finish (0–45). Leave out to answer right away.")
    ]],
    "annotations": ["readOnlyHint": true]
]

let tool_open_project: [String: Any] = [
    "name": "open_project",
    "description": "Pipeline step 0. Opens an existing project (path = the project folder or its .1shot file), or makes a new one (name + video: the video is copied into the project's Media folder; it goes in ~/Movies/1Shot unless you give location), or opens a video with no project (video alone). Answers with the status and the first frame of the trim. Show the user the project name, clip length and the frame, then stop for their approval.",
    "inputSchema": ["type": "object", "properties": [
        "path": prop("string", "An existing project: its folder or .1shot file. ~ is allowed."),
        "name": prop("string", "Name for a new project (with video)."),
        "video": prop("string", "Path to the video for a new project, or to open on its own."),
        "location": prop("string", "Folder to make the new project in. Default ~/Movies/1Shot.")
    ]]
]

let tool_snapshot_frame: [String: Any] = [
    "name": "snapshot_frame",
    "description": "A picture of the video at a moment, as the export will look (graded: stabilization, zoom, LUTs, color and B-roll), or as recorded (graded: false). Use it to see the shot, judge the user's Visual Design choices, check a zoom or a B-roll spot.",
    "inputSchema": ["type": "object", "properties": [
        "at": prop("number", "Seconds on the original clip. Default: the playhead."),
        "times": ["type": "array", "items": ["type": "number"], "description": "Up to 6 times for several frames at once."],
        "graded": prop("boolean", "true (default) = finished look; false = as recorded (stabilized only)."),
        "maxWidth": prop("number", "Image width in pixels, 320–1920 (default 1280).")
    ]],
    "annotations": ["readOnlyHint": true]
]

let tool_get_settings: [String: Any] = [
    "name": "get_settings",
    "description": "Every Visual Design setting (white balance, LUTs, Levels, sliders, stabilize, fade) and Sound Design setting (voice isolation, high pass, gate, compressor, de-esser, limiter) in raw and plain units, plus the live output meter. Also the live Loudness (LUFS) meters. measure: true also measures the original recording inside the trim (integrated LUFS, peak, noise floor, speech level) and the whole edit after Sound Design, exactly as it will export (target −14 LUFS; the export can normalize to it). Pipeline steps 1–2 are the user's for now: read their settings, explain what you think each choice is for, say which you can't explain, and stop for their approval.",
    "inputSchema": ["type": "object", "properties": [
        "measure": prop("boolean", "Also measure the loudness of the original recording and of the whole edit after Sound Design (pauses playback; a few seconds to a minute).")
    ]],
    "annotations": ["readOnlyHint": true]
]

let tool_set_visual: [String: Any] = [
    "name": "set_visual",
    "description": "Changes Visual Design settings. Only what you pass changes. The user does Visual Design themself for now: use this only when they ask.",
    "inputSchema": ["type": "object", "properties": [
        "sliders": ["type": "object", "description": "By name: Exposure, Saturation, Vibrance, Color, Tint, Highlights, Shadows (−100…100), Sharpen, Denoise (0…100). Example {\"Color\": 12, \"Tint\": -4}.",
                    "additionalProperties": ["type": "number"]],
        "bypassed": ["type": "array", "items": ["type": "string"], "description": "Slider names to switch off (shown red). Replaces the current list."],
        "blackPoint": prop("number", "Levels black point, 0–0.5."),
        "whitePoint": prop("number", "Levels white point, 0.5–1."),
        "cameraLUT": prop(["string", "null"], "A LUT file name from get_settings' lutLibrary, or null for none."),
        "creativeLUT": prop(["string", "null"], "A LUT file name, or null for none."),
        "stabilize": prop("boolean", "Turn stabilization on (analyzes the clip first if needed) or off."),
        "smoothness": prop("number", "Stabilization smoothness 0–100 (100 = locked off like a tripod)."),
        "maxCrop": prop("number", "Stabilization max crop, 2–20 %."),
        "fade": prop("boolean", "Fade to black at the end (+2 s of black)."),
        "colorBypass": prop("boolean", "Preview-only before/after switch for the Color section.")
    ]]
]

let tool_set_sound: [String: Any] = [
    "name": "set_sound",
    "description": "Changes Sound Design settings. Only what you pass changes. The user does Sound Design themself for now: use this only when they ask.",
    "inputSchema": ["type": "object", "properties": [
        "isolationAmount": prop("number", "Voice isolation wet mix, 0 (off)–100 %."),
        "isolationModel": prop(numberOrString, "\"HQV\" (High Quality Voice) or \"Voice\"."),
        "highPassHz": prop("number", "High-pass cutoff, 20–400 Hz; 0 = off."),
        "gateThreshold": prop("number", "Noise gate threshold, −80–0 dB."),
        "gateRange": prop("number", "Noise gate range, −40–0 dB (0 = off)."),
        "compThreshold": prop("number", "Compressor threshold, −40–0 dB."),
        "compRatio": prop("number", "Compressor ratio 1–10 (1 = off)."),
        "compMakeup": prop("number", "Compressor make-up gain, 0–24 dB."),
        "deEssFrequency": prop("number", "De-esser frequency, 4–10 kHz."),
        "deEssAmount": prop("number", "De-esser amount 0 (off)–100."),
        "limiterInput": prop("number", "Limiter input gain, 0–24 dB (ceiling is fixed at −0.1 dB)."),
        "bypassed": ["type": "array", "items": ["type": "string"], "description": "Sections to switch off: isolation, gate, compressor, deEsser, limiter. Replaces the current list."]
    ]]
]

let tool_set_trim: [String: Any] = [
    "name": "set_trim",
    "description": "Pipeline step 3. Sets where the usable recording starts and ends (seconds on the original clip), or reset: true for the whole clip. Answers with the first and last words inside the trim (when there's a transcript). Show the user the in/out with those words, then stop for approval.",
    "inputSchema": ["type": "object", "properties": [
        "start": prop("number", "Trim in, seconds on the original clip."),
        "end": prop("number", "Trim out, seconds on the original clip."),
        "reset": prop("boolean", "true = no trim (the whole clip).")
    ]]
]

let tool_create_transcript: [String: Any] = [
    "name": "create_transcript",
    "description": "Makes the edit transcript for the project's video: every word with its timing, plus pauses measured after voice isolation at 100 %. Needs a project. Runs in the app (the user sees a progress sheet) and can take a few minutes; if it isn't done within 45 s you get 'still running': call status with wait: 45 until it finishes, then read_transcript.",
    "inputSchema": ["type": "object", "properties": [:] as [String: Any]]
]

let tool_read_transcript: [String: Any] = [
    "name": "read_transcript",
    "description": "The project's edit transcript in the format the style guides expect (words[] {w,s,e}, silences[] {s,e}, segments[], trimStart/trimEnd = the project's trim right now). format: text gives the readable version. from/to limit it to part of the clip.",
    "inputSchema": ["type": "object", "properties": [
        "format": ["type": "string", "enum": ["json", "text"], "description": "json (default) or text."],
        "from": prop("number", "Only words/pauses after this time (seconds)."),
        "to": prop("number", "Only words/pauses before this time (seconds).")
    ]],
    "annotations": ["readOnlyHint": true]
]

let tool_apply_cuts: [String: Any] = [
    "name": "apply_cuts",
    "description": "Pipeline steps 4 and 5. Puts a cut list on the timeline (pieces removed from inside the trim). Step 4 (pauses, dead air): mode replace. Step 5 (false starts, retakes, stumbles): mode add, so the pause cuts stay. Follow the 'Default - Talking Head' style guide (read_style_guide). Answers with every cut, the words it removes, the new length and warnings (cuts under 1 s that aren't mistakes, edges inside a word). Show the user the summary (step 4) or each cut with its words (step 5), then stop for approval.",
    "inputSchema": ["type": "object", "properties": [
        "cuts": ["type": "array", "description": "Cuts: {start, end, reason (pause, false-start, retake, dead-air, other), note}. Seconds on the original clip.",
                 "items": ["type": "object", "properties": [
                    "start": ["type": "number"], "end": ["type": "number"],
                    "reason": ["type": "string"], "note": ["type": "string"]
                 ], "required": ["start", "end"]]],
        "cutList": prop(objectOrString, "Instead of cuts: the style guide's whole output object (styleGuide, clip, cuts, review, summary)."),
        "mode": ["type": "string", "enum": ["replace", "add", "clear"], "description": "replace (default), add to the cuts already there, or clear all cuts."],
        "styleGuide": prop("string", "Name of the style guide you followed.")
    ]]
]

let tool_apply_zooms: [String: Any] = [
    "name": "apply_zooms",
    "description": "Pipeline step 6. Replaces the punch-in zooms. Follow the 'Zooms - Talking Head' style guide (read_style_guide): instant zooms only, scales 1.00 / 1.28 / 1.40. Answers with each zoom and its words, plus warnings. Show the user each zoom with its words, then stop for approval.",
    "inputSchema": ["type": "object", "properties": [
        "zooms": ["type": "array", "description": "Zooms: {at, scale, type (punch-in, reset, cta), reason, words, anchorX, anchorY}.",
                  "items": ["type": "object", "properties": [
                    "at": ["type": "number"], "scale": ["type": "number"], "type": ["type": "string"],
                    "reason": ["type": "string"], "words": ["type": "string"],
                    "anchorX": ["type": "number"], "anchorY": ["type": "number"]
                  ], "required": ["at", "scale"]]],
        "zoomList": prop(objectOrString, "Instead of zooms: the style guide's whole output object."),
        "mode": ["type": "string", "enum": ["replace", "clear"], "description": "replace (default) or clear all zooms."]
    ]]
]

let tool_apply_broll: [String: Any] = [
    "name": "apply_broll",
    "description": "Pipeline step 7. Puts B-roll on V2 and downloads it into the project (Pixabay video by search, Unsplash photo by url). STOCK ONLY for now: shots with a file are refused. Follow the 'B-roll - Talking Head' style guide (read_style_guide). The user's own manually added clips stay. Downloads can take a while: if not done in 45 s, call status with wait: 45. Show the user the spots and what's on V2, then stop for approval.",
    "inputSchema": ["type": "object", "properties": [
        "broll": ["type": "array", "description": "Shots: {at, length, kind (video/photo), and exactly one of pixabayId (a clip the user picked from a candidate sheet; preferred), search (Pixabay's top match, unchecked) or url (an Unsplash photo with credit, or a Pixabay link the user pasted, which becomes that exact clip), reason, words}.",
                  "items": ["type": "object", "properties": [
                    "at": ["type": "number"], "length": ["type": "number"], "kind": ["type": "string"],
                    "pixabayId": ["type": "integer"], "search": ["type": "string"], "url": ["type": "string"], "credit": ["type": "string"],
                    "reason": ["type": "string"], "words": ["type": "string"]
                  ], "required": ["at"]]],
        "brollList": prop(objectOrString, "Instead of broll: the style guide's whole output object."),
        "mode": ["type": "string", "enum": ["replace", "clear"], "description": "replace (default) or clear (keeps the user's own clips)."],
        "download": prop("boolean", "Download the shots now (default true).")
    ]]
]

let tool_broll_candidates: [String: Any] = [
    "name": "broll_candidates",
    "description": "Step 7 helper: B-roll candidates from Pixabay as a numbered contact sheet of thumbnails (number, length and tags under each), returned as an image and saved in the project's B-roll Candidates folder. search: look at up to 40 results for a spot. Pixabay's API searches tags only and finds far fewer clips than pixabay.com, so a short sheet widens on its own (each word separately, then the also searches); add also with related scenes or objects for thin topics. ids: a sheet of just the clips you choose, in your order, e.g. your 10 favorites to show the user. The user picks a number; put that clip's pixabayId in apply_broll.",
    "inputSchema": ["type": "object", "properties": [
        "search": prop("string", "Words to look for, e.g. phone on tripod in backyard. Search for the scene or object, not a mood."),
        "count": prop("number", "How many results to show for a search, 1 to 40 (default 20)."),
        "also": ["type": "array", "items": ["type": "string"], "description": "More searches to fill the sheet when the main one comes up short, e.g. [\"camera outdoors\", \"photographer field\"]. Duplicates are dropped."],
        "ids": ["type": "array", "items": ["type": ["integer", "string"]], "description": "Pixabay video ids, or Pixabay links the user pasted (page or download links), to show instead of searching, numbered in this order."],
        "title": prop("string", "Sheet title and file name, e.g. 0-54 talk into your camera.")
    ]],
    "annotations": ["readOnlyHint": true]
]

let tool_save_to_broll_library: [String: Any] = [
    "name": "save_to_broll_library",
    "description": "Keeps Pixabay clips the user likes in the shared B-roll Library (~/Movies/1Shot/B-roll Library) without placing them in this edit, so any project can use them later. Use it when the user says to save or keep a clip (e.g. a runner-up). Clips placed with apply_broll are added automatically. Vertical clips are refused.",
    "inputSchema": ["type": "object", "properties": [
        "ids": ["type": "array", "items": ["type": ["integer", "string"]], "description": "Pixabay video ids, or Pixabay links the user pasted."],
        "words": prop("string", "What the clip shows or the line it was considered for, saved with it in library.json.")
    ], "required": ["ids"]]
]

let tool_seek: [String: Any] = [
    "name": "seek",
    "description": "Moves the playhead (and pauses), so the user can see a spot. play: true starts playback from there, for example to hear how a cut sounds.",
    "inputSchema": ["type": "object", "properties": [
        "to": prop(numberOrString, "Seconds on the original clip, or \"trimStart\" / \"trimEnd\"."),
        "play": prop("boolean", "Start playing from there.")
    ], "required": ["to"]]
]

let tool_graphics_templates: [String: Any] = [
    "name": "graphics_templates",
    "description": "Step 8 helper: the motion-graphics templates (full-screen plates and overlays on the talking head), the fields each takes with an example, the emphasis red, and the rules. Call before proposing plates.",
    "inputSchema": ["type": "object", "properties": [String: Any]()],
    "annotations": ["readOnlyHint": true]
]

let plateSchema: [String: Any] = [
    "type": "object",
    "properties": [
        "at": ["type": "number", "description": "Start, original-clip seconds."],
        "length": ["type": "number", "description": "Seconds on screen. Leave out for the reading-time minimum."],
        "template": ["type": "string"],
        "kicker": ["type": "string"], "title": ["type": "string"], "subtitle": ["type": "string"],
        "items": ["type": "array", "items": ["type": "string"]],
        "side": ["type": "string", "enum": ["left", "right"], "description": "Overlays: where the graphic goes. Leave out and the app picks the side away from the speaker's face."],
        "overFace": ["type": "boolean", "description": "true only for a deliberate comedic beat: lets the plate cover the speaker's face."],
        "style": ["type": "string", "enum": ["clean", "panel"]],
        "build": ["type": "boolean"],
        "builds": ["type": "array", "items": ["type": "number"], "description": "Clip seconds each item appears (the word where it's said)."],
        "current": ["type": "integer"],
        "scale": ["type": "number", "description": "Size tweak (1 = automatic)."],
        "dx": ["type": "number"], "dy": ["type": "number"],
        "words": ["type": "string"], "reason": ["type": "string"]
    ],
    "required": ["at", "template"]
]

let tool_graphics_preview: [String: Any] = [
    "name": "graphics_preview",
    "description": "Step 8: draws proposed plates over their frames as one numbered sheet (returned as an image, saved in the project's Graphics Previews folder). Places nothing. Mark the red word with *asterisks*. Optional red sets the emphasis color (hex, e.g. from the speaker's thumbnails).",
    "inputSchema": ["type": "object", "properties": [
        "graphics": ["type": "array", "items": plateSchema],
        "title": ["type": "string", "description": "Sheet title and file name."],
        "red": ["type": "string", "description": "Emphasis red as hex, e.g. #E3242B. Saved for every plate."]
    ], "required": ["graphics"]],
    "annotations": ["readOnlyHint": true]
]

let tool_apply_graphics: [String: Any] = [
    "name": "apply_graphics",
    "description": "Pipeline step 8, Motion Graphics: places the plates the user approved on V3 (replaces the current set; mode clear removes them all). They show in the preview and the export, above B-roll, never zoomed or graded. Show the user what's placed, then stop for approval.",
    "inputSchema": ["type": "object", "properties": [
        "graphics": ["type": "array", "items": plateSchema],
        "mode": ["type": "string", "enum": ["replace", "clear"]],
        "red": ["type": "string", "description": "Emphasis red as hex."]
    ]]
]

let tool_adjust_graphics: [String: Any] = [
    "name": "adjust_graphics",
    "description": "Step 8: resize or nudge plates already placed, instantly (no rebuild, no face search). n = the plate's number in time order (1 = first). scale 1 = automatic size (1.3 = 30% bigger). dx/dy nudge in px of a 1920×1080 frame (+dx right, +dy down). reset: true puts a plate back to automatic. Warns if a change makes a plate cover the speaker's face.",
    "inputSchema": ["type": "object", "properties": [
        "adjust": ["type": "array", "items": ["type": "object", "properties": [
            "n": ["type": "integer"], "at": ["type": "number"], "scale": ["type": "number"],
            "dx": ["type": "number"], "dy": ["type": "number"], "side": ["type": "string", "enum": ["left", "right"]],
            "length": ["type": "number"], "overFace": ["type": "boolean"], "reset": ["type": "boolean"]
        ]]]
    ], "required": ["adjust"]]
]

let tool_graphics_style: [String: Any] = [
    "name": "graphics_style",
    "description": "Reads or changes Graphics Style.json in the Style Guides folder: global plate sizes, the room kept around the speaker's face, the smallest a plate may shrink, animation timing, and the emphasis red. Changes show on the next frame, no rebuild. No arguments = read. reset: true = back to defaults.",
    "inputSchema": ["type": "object", "properties": [
        "overlayScale": ["type": "number", "description": "Every overlay's size (1 = as designed)."],
        "fullScreenScale": ["type": "number"],
        "faceSidePad": ["type": "number", "description": "Room beside his face, share of face width (each side)."],
        "faceTopPad": ["type": "number", "description": "Room above his face (hair), share of face height."],
        "faceChinPad": ["type": "number", "description": "Room below (chin), share of face height."],
        "minScale": ["type": "number", "description": "Smallest a plate may shrink to clear his face."],
        "edge": ["type": "number"], "gap": ["type": "number"],
        "popSeconds": ["type": "number"], "slamSeconds": ["type": "number"], "swipeSeconds": ["type": "number"],
        "drawSeconds": ["type": "number"], "slideSeconds": ["type": "number"], "fadeOutSeconds": ["type": "number"],
        "red": ["type": "string", "description": "Emphasis red as #RRGGBB."],
        "reset": ["type": "boolean"]
    ]]
]

let tool_read_style_guide: [String: Any] = [
    "name": "read_style_guide",
    "description": "The editing style guides from ~/Movies/1Shot/Style Guides (the ones the app uses). With no name: lists them. With a name: the full guide. Read the matching guide before steps 4–7 and follow its MUST/NEVER rules exactly.",
    "inputSchema": ["type": "object", "properties": [
        "name": prop("string", "e.g. \"Default - Talking Head\", \"Zooms - Talking Head\", \"B-roll - Talking Head\".")
    ]],
    "annotations": ["readOnlyHint": true]
]

let tools: [[String: Any]] = [
    tool_status,
    tool_open_project,
    tool_snapshot_frame,
    tool_get_settings,
    tool_set_visual,
    tool_set_sound,
    tool_set_trim,
    tool_create_transcript,
    tool_read_transcript,
    tool_apply_cuts,
    tool_apply_zooms,
    tool_broll_candidates,
    tool_save_to_broll_library,
    tool_apply_broll,
    tool_seek,
    tool_graphics_templates,
    tool_graphics_preview,
    tool_apply_graphics,
    tool_adjust_graphics,
    tool_graphics_style,
    tool_read_style_guide
]

let instructions = """
1Shot is a Mac app for preparing multi-take talking-head YouTube videos. You drive it with these tools. Several projects can be open at once, each in its own window: you work in the one your last open_project used (status shows its project and lists openProjects), so the user can switch windows without moving you.

Work the pipeline ONE STEP AT A TIME and STOP for the user's approval after every step. Never start the next step until they say so. Any step can be redone.
0 Open file: open_project. Show the project name, clip length and frame.
1 Visual Design: The user does this themself for now. Use get_settings and snapshot_frame to read their choices, explain what you think each is for, and say plainly which you can't explain. Use set_visual only if they ask.
2 Sound Design: The user does this themself for now. Use get_settings with measure: true and explain the same way, including how far the edit is from YouTube's −14 LUFS. You can't listen, so their ears are the final say. Use set_sound only if they ask.
3 Start and stop points: create_transcript, read_transcript, then set_trim. Show in/out with the first and last words.
4 Ums, ahs and long silences: apply_cuts (mode replace) per the "Default - Talking Head" style guide. Show the count, seconds removed and a few examples. Filler words are often missing from the transcript, so expect the user to check this step.
5 Repeated phrases and mistakes: apply_cuts (mode add) per the same guide. Show each cut with the words it removes.
6 Zooms: apply_zooms per "Zooms - Talking Head". Show each zoom with its words.
7 B-roll: per "B-roll - Talking Head", stock only (Pixabay video, Unsplash photos). First choose all the spots and show them as a list; the user approves the spots. Then go through the spots ONE AT A TIME: for the current spot only, run broll_candidates with a search (up to 40 results), pick your 10 favorites that truly match the words, and show the user a sheet of just those (broll_candidates with ids and a title naming the spot), with each clip's page link and which one you'd pick. Then STOP: The user picks the winner by number, or gives a different phrase to search; for a new phrase, search it and show a new top 10 for the same spot. Place the winner with apply_broll using pixabayId (apply_broll replaces the list, so send every clip picked so far), then move to the next spot. Never search ahead, never show two spots at once, never place a clip the user didn't pick. If a sheet is thin, widen it with also, or ask the user for the link to a clip they see on pixabay.com (a pasted link works in ids and in apply_broll's url). Every clip the user picks is approved: when it's placed, the app copies it into the shared B-roll Library (~/Movies/1Shot/B-roll Library, listed in library.json with credit, page and words) so every project can reuse it, and placing a clip that's already there copies it instead of downloading it again. When the user asks to keep a clip they didn't place (a runner-up), save it with save_to_broll_library. A shot can also be framed: zoom (1–3, 1 = fill) and panX/panY (−1…1) on the shot in apply_broll zoom into it and pick which part shows. A shot can also be picture-in-picture: pipScale (0.15–1, size of the frame) and pipX/pipY (its centre in the 1920×1080 frame, y down) put it in a rounded box over the speaker; the user can also drag it on the video in the B-roll tab. apply_broll replaces the list, so send each shot's pip fields back unchanged. Never use a vertical (portrait) video: horizontal only (the app leaves them off sheets and refuses to place one).
8 Motion Graphics (playful style: elements animate beside the speaker; full-screen only for the 1–2 biggest points; about one plate every 15–20 s): graphics_templates first. From the transcript, choose spots and propose plates (template, words, the red word marked with *asterisks*, side opposite the speaker for overlays, builds on the words for bullets). Show them with graphics_preview and list each with its time and words; stop for the user's picks and edits. Then apply_graphics with only what they approved, and stop for approval. For size or position tweaks after that, use adjust_graphics (one plate) or graphics_style (all plates); both are instant. Charts and numbers use the user's real numbers only: ask, never make them up. Keep plates off the speaker's face unless it's a deliberate comedic beat. The app does not check the face: plates go exactly where side, scale and dx/dy put them, so pick the side away from the speaker and check the preview sheet; the user fine-tunes size and position in the Graphics tab. Always include a name plate: a lowerThird with the user's channel handle as title and their tagline as subtitle, in the first 10–15 s of the edited video. Ask the user for the handle and tagline if you don't know them; never guess.
9 Export: not available in this version yet. The user exports with ⌘Y; its save sheet has a "Normalize loudness to −14 LUFS" checkbox (on by default).

Read the style guide with read_style_guide before steps 4 to 8. All times are seconds on the ORIGINAL clip, the same clock as the transcript. If a tool says a dialog is open in the app, ask the user to close it.
"""

// MARK: - MCP (JSON-RPC 2.0 over stdio)

final class Output {
    static let shared = Output()
    private let lock = NSLock()
    func send(_ message: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(message),
              var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else {
            logLine("couldn't encode a message")
            return
        }
        data.append(0x0A)
        lock.lock()
        FileHandle.standardOutput.write(data)
        lock.unlock()
    }
}

func reply(_ id: Any, result: [String: Any]) {
    Output.shared.send(["jsonrpc": "2.0", "id": id, "result": result])
}

func replyError(_ id: Any, code: Int, _ message: String) {
    Output.shared.send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message] as [String: Any]])
}

/// Turns the app's answer into MCP content: the JSON as text, and any frames as images.
func toolContent(_ name: String, _ value: Any) -> [[String: Any]] {
    var images: [[String: Any]] = []
    var rest = value
    if var dict = value as? [String: Any] {
        if name == "read_transcript" || name == "read_style_guide", let text = dict["text"] as? String {
            return [["type": "text", "text": text]]
        }
        func strip(_ image: [String: Any]) -> [String: Any] {
            var m = image
            m.removeValue(forKey: "data")
            m["attached"] = true
            return m
        }
        if let image = dict["image"] as? [String: Any] {
            images.append(image)
            dict["image"] = strip(image)
        }
        if let list = dict["images"] as? [[String: Any]] {
            images += list
            dict["images"] = list.map(strip)
        }
        rest = dict
    }
    var text = "\(rest)"
    if JSONSerialization.isValidJSONObject(rest),
       let data = try? JSONSerialization.data(withJSONObject: rest, options: [.sortedKeys, .withoutEscapingSlashes]),
       let s = String(data: data, encoding: .utf8) {
        text = s
    }
    var content: [[String: Any]] = [["type": "text", "text": text]]
    for image in images {
        if let data = image["data"] as? String {
            content.append(["type": "image", "data": data, "mimeType": image["mimeType"] as? String ?? "image/jpeg"])
        }
    }
    return content
}

func callTool(_ id: Any, _ params: [String: Any]) {
    let name = params["name"] as? String ?? ""
    let args = params["arguments"] as? [String: Any] ?? [:]
    guard tools.contains(where: { $0["name"] as? String == name }) else {
        replyError(id, code: -32602, "Unknown tool: \(name)")
        return
    }
    do {
        let value = name == "read_style_guide" ? try readStyleGuide(args) : try App.call(name, args)
        reply(id, result: ["content": toolContent(name, value), "isError": false])
    } catch {
        reply(id, result: ["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
    }
}

func handle(_ message: [String: Any]) {
    guard let method = message["method"] as? String else { return }   // a response or junk: nothing to do
    let id = message["id"]
    let params = message["params"] as? [String: Any] ?? [:]
    if method.hasPrefix("notifications/") { return }
    guard let id else { return }                                       // other notifications

    switch method {
    case "initialize":
        let supported = ["2025-06-18", "2025-03-26", "2024-11-05"]
        let asked = params["protocolVersion"] as? String ?? ""
        reply(id, result: [
            "protocolVersion": supported.contains(asked) ? asked : supported[0],
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "1shot", "title": "1Shot", "version": serverVersion],
            "instructions": instructions
        ])
    case "ping":
        reply(id, result: [:])
    case "tools/list":
        reply(id, result: ["tools": tools])
    case "tools/call":
        // Tool calls can take a while (transcripts, downloads), so they run off the reading thread.
        DispatchQueue.global(qos: .userInitiated).async { callTool(id, params) }
    default:
        replyError(id, code: -32601, "Method not found: \(method)")
    }
}

// MARK: - --install and --test

func install() {
    let fm = FileManager.default
    let helper = supportPath + "/1shot-mcp"
    let claudeFolder = NSHomeDirectory() + "/Library/Application Support/Claude"
    let config = claudeFolder + "/claude_desktop_config.json"
    guard fm.fileExists(atPath: claudeFolder) else {
        print("The Claude desktop app isn't installed (no \(claudeFolder)).")
        print("After installing it, run:  \"\(helper)\" --install")
        return
    }
    var settings: [String: Any] = [:]
    if let data = fm.contents(atPath: config), !data.isEmpty {
        guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            print("Couldn't read \(config) (it isn't valid JSON), so it was left alone.")
            print("Add this to it by hand:  \"1shot\": { \"command\": \"\(helper)\" }  inside \"mcpServers\".")
            return
        }
        settings = parsed
    }
    var servers = settings["mcpServers"] as? [String: Any] ?? [:]
    let entry: [String: Any] = ["command": helper]
    // Before 3.2 the app was "1Shot Pipeline" and its entry was "1shot-pipeline": replace that one.
    let hadOldEntry = servers.removeValue(forKey: "1shot-pipeline") != nil
    if !hadOldEntry, let existing = servers["1shot"] as? [String: Any], existing["command"] as? String == helper {
        print("Claude desktop is already set up for 1Shot.")
        return
    }
    if fm.fileExists(atPath: config) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try? fm.copyItem(atPath: config, toPath: config + ".backup-" + stamp)
    }
    servers["1shot"] = entry
    settings["mcpServers"] = servers
    do {
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: URL(fileURLWithPath: config), options: .atomic)
        print("Added 1Shot to the Claude desktop app. Quit Claude (⌘Q) and open it again to connect.")
    } catch {
        print("Couldn't update \(config): \(error.localizedDescription)")
    }
}

func test() {
    do {
        let status = try App.call("status", [:])
        let data = try JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print("1Shot answered:")
        print(String(data: data, encoding: .utf8) ?? "")
    } catch {
        print("Test failed: \(error.localizedDescription)")
        exit(1)
    }
}

// MARK: - Main

signal(SIGPIPE, SIG_IGN)
let arguments = CommandLine.arguments.dropFirst()
if arguments.contains("--install") { install(); exit(0) }
if arguments.contains("--test") { test(); exit(0) }
if arguments.contains("--version") { print("1shot-mcp \(serverVersion)"); exit(0) }

logLine("ready (version \(serverVersion))")
while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { continue }
    guard let data = trimmed.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: data) else {
        replyError(NSNull(), code: -32700, "Parse error")
        continue
    }
    if let message = parsed as? [String: Any] {
        handle(message)
    } else if let batch = parsed as? [[String: Any]] {
        batch.forEach(handle)
    }
}
// Claude closed the connection. Give any tool call that's still answering a moment, then exit.
Thread.sleep(forTimeInterval: 0.5)
exit(0)

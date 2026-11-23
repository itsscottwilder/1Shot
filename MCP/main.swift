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

let serverVersion = "2.13.0"
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
    "description": "A picture of the video at a moment, as the export will look (graded: stabilization, zoom, LUTs, color and B-roll), or as recorded (graded: false). Use it to see the shot, judge the user's Visual Design choices, check a zoom or a B-roll spot. Each image says which Visual Design group grades it (group; brollGroup too when a B-roll shot is on screen), so you can check a group's look landed on the right clip.",
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
    "description": "Every Visual Design setting and Sound Design setting. Visual Design is per group: every clip belongs to a Visual Design group (Default, B-roll and any the user made), and each group has its own look (sliders incl. white balance, bypassed, Levels, Camera/Creative LUT). With no group: visualDesign.groups lists every group with its clips and settings, plus activeGroup (shown in the panel) and defaultTarget (what set_visual changes when you pass no group). With group: just that group. Stabilize, smoothness, maxCrop, fade and colorBypass are project-wide (visualDesign.projectWide). Sound Design: (voice isolation, high pass, gate, compressor, de-esser, limiter) in raw and plain units, plus the live output meter. Also the live Loudness (LUFS) meters. measure: true also measures the original recording inside the trim (integrated LUFS, peak, noise floor, speech level) and the whole edit after Sound Design, exactly as it will export (target −14 LUFS; the export can normalize to it). Pipeline steps 3–4 are the user's for now: read their settings, explain what you think each choice is for, say which you can't explain, and stop for their approval.",
    "inputSchema": ["type": "object", "properties": [
        "group": prop("string", "A Visual Design group's name (e.g. \"Default\"): return only that group. Leave out for every group."),
        "measure": prop("boolean", "Also measure the loudness of the original recording and of the whole edit after Sound Design (pauses playback; a few seconds to a minute).")
    ]],
    "annotations": ["readOnlyHint": true]
]

let tool_set_visual: [String: Any] = [
    "name": "set_visual",
    "description": "Changes Visual Design settings. Only what you pass changes. Per-group settings (sliders, bypassed, blackPoint, whitePoint, cameraLUT, creativeLUT) go to ONE Visual Design group: the one you name in group, else the group of the clip selected in the app (or under the playhead). Project-wide settings (stabilize, smoothness, maxCrop, fade, colorBypass) apply to the whole video whatever group you name. It never changes the app's clip selection. The answer says which group changed. Use list_groups or get_settings to see the groups. The user does Visual Design themself for now: use this only when they ask.",
    "inputSchema": ["type": "object", "properties": [
        "group": prop("string", "The Visual Design group to change, by name (e.g. \"Default\", \"Show and tell\"). Leave out for the selected clip's group."),
        "sliders": ["type": "object", "description": "By name: Exposure, Saturation, Vibrance, Color, Tint, Highlights, Shadows (−100…100), Sharpen, Denoise (0…100). Example {\"Color\": 12, \"Tint\": -4}.",
                    "additionalProperties": ["type": "number"]],
        "bypassed": ["type": "array", "items": ["type": "string"], "description": "Slider names to switch off (shown red). Replaces the current list."],
        "blackPoint": prop("number", "Levels black point, 0–0.5."),
        "whitePoint": prop("number", "Levels white point, 0.5–1."),
        "cameraLUT": prop(["string", "null"], "A LUT file name from get_settings' lutLibrary, or null for none."),
        "creativeLUT": prop(["string", "null"], "A LUT file name, or null for none."),
        "stabilize": prop("boolean", "Project-wide: turn stabilization on (analyzes the clip first if needed) or off."),
        "smoothness": prop("number", "Project-wide: stabilization smoothness 0–100 (100 = locked off like a tripod)."),
        "maxCrop": prop("number", "Project-wide: stabilization max crop, 2–20 %."),
        "fade": prop("boolean", "Project-wide: fade to black at the end (+2 s of black)."),
        "colorBypass": prop("boolean", "Project-wide, preview only: before/after switch for the Color section.")
    ]]
]

let tool_list_groups: [String: Any] = [
    "name": "list_groups",
    "description": "The Visual Design groups: each group's name, colour, A-roll clips (index on V1 from 1, file, start/end in timeline seconds), B-roll shots, imported clips, and a one-line summary of its look. Also activeGroup (shown in the panel), defaultTarget (what set_visual changes with no group) and the project-wide settings. Use a group's name in set_visual and get_settings.",
    "inputSchema": ["type": "object", "properties": [String: Any]()],
    "annotations": ["readOnlyHint": true]
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

let tool_find_dead_air: [String: Any] = [
    "name": "find_dead_air",
    "description": "Pipeline step 1. Measures the silence at the start and end of every clip in the Assets tab (in Assets-list order, numbered from 1; rejected clips are skipped) and proposes each clip's in/out: lead seconds before the first sound, tail seconds after the last. Times are seconds in each clip's own file. Changes nothing. Show the user each clip's dead air and proposed in/out, then stop for approval.",
    "inputSchema": ["type": "object", "properties": [
        "clips": ["type": "array", "items": ["type": "integer"], "description": "Only these clips (numbers from 1, in Assets-list order). Default: all."],
        "lead": prop("number", "Seconds to keep before the first sound, 0–2. Default 0.3."),
        "tail": prop("number", "Seconds to keep after the last sound, 0–3. Default 0.5.")
    ]],
    "annotations": ["readOnlyHint": true]
]

let tool_set_clip_trims: [String: Any] = [
    "name": "set_clip_trims",
    "description": "Pipeline step 1. Sets the in/out of one or more Assets-tab clips (seconds in each clip's own file; clips you leave out keep theirs) and rebuilds the A-roll from them. If the A-roll already has cuts, zooms, B-roll or graphics, this refuses unless clearEdits: true, because the timeline shifts and they are cleared: ask the user first. Answers with every clip's in/out and the A-roll length. Use only the in/out points the user approved.",
    "inputSchema": ["type": "object", "properties": [
        "clips": ["type": "array", "description": "One entry per clip to change.", "items": ["type": "object", "properties": [
            "clip": prop("integer", "Clip number from find_dead_air (from 1, in Assets-list order)."),
            "in": prop("number", "In point, seconds in the clip's file."),
            "out": prop("number", "Out point, seconds in the clip's file.")
        ], "required": ["clip"]]],
        "clearEdits": prop("boolean", "true = OK to clear cuts, zooms, B-roll and graphics (only after the user agrees).")
    ], "required": ["clips"]]
]

let tool_set_clip_order: [String: Any] = [
    "name": "set_clip_order",
    "description": "Puts the Assets-tab clips in a new order: the order the A-roll plays them in (the user may record out of order). List the current clip numbers in their new order; clips you leave out follow, in their current order. If the A-roll is built it is rebuilt; if it already has cuts, zooms, B-roll or graphics this refuses unless clearEdits: true (ask the user first). Answers with the clips, renumbered in the new order. The user can also drag clips in the Assets list.",
    "inputSchema": ["type": "object", "properties": [
        "order": ["type": "array", "items": ["type": "integer"], "description": "Current clip numbers (from 1), in the order they should play."],
        "clearEdits": prop("boolean", "true = OK to clear cuts, zooms, B-roll and graphics (only after the user agrees).")
    ], "required": ["order"]]
]

let tool_compare_clips: [String: Any] = [
    "name": "compare_clips",
    "description": "Pipeline step 2. A contact sheet of every Assets-tab clip (in Assets-list order, numbered from 1): three frames each, at 10 %, 50 % and 90 % of its in/out, as recorded. Also each clip's current Visual Design group and a rough difference score for every pair (0 = identical, higher = more different). Changes nothing. Compare the looks, propose groups (clip 1's look is Default; every other look gets a new group named after what it looks like), then stop for approval.",
    "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
    "annotations": ["readOnlyHint": true]
]

let tool_set_clip_groups: [String: Any] = [
    "name": "set_clip_groups",
    "description": "Pipeline step 2. Puts Assets-tab clips into Visual Design groups. The group containing clip 1 is always Default (its name is ignored). Any other name is an existing group or makes a new one. Clips you leave out stay where they are. Answers with every group and every clip's group. Use only the grouping the user approved.",
    "inputSchema": ["type": "object", "properties": [
        "groups": ["type": "array", "description": "One entry per group.", "items": ["type": "object", "properties": [
            "name": prop("string", "Group name, describing the look (e.g. \"Close-up – lamp light\"). Ignored for the group with clip 1 (Default)."),
            "clips": ["type": "array", "items": ["type": "integer"], "description": "Clip numbers from compare_clips."]
        ], "required": ["clips"]]]
    ], "required": ["groups"]]
]

let tool_set_trim: [String: Any] = [
    "name": "set_trim",
    "description": "Pipeline step 5. Sets where the usable recording starts and ends (seconds on the original clip), or reset: true for the whole clip. Answers with the first and last words inside the trim (when there's a transcript). Show the user the in/out with those words, then stop for approval.",
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
    "description": "Pipeline steps 6 and 7. Puts a cut list on the timeline (pieces removed from inside the trim). Step 6 (pauses, dead air): mode replace. Step 7 (false starts, retakes, stumbles): mode add, so the pause cuts stay. Follow the 'Default - Talking Head' style guide (read_style_guide). Answers with every cut, the words it removes, the new length and warnings (cuts under 1 s that aren't mistakes, edges inside a word). Show the user the summary (step 6) or each cut with its words (step 7), then stop for approval.",
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
    "description": "Pipeline step 8. Replaces the punch-in zooms. Follow the 'Zooms - Talking Head' style guide (read_style_guide): instant zooms only, scales 1.00 / 1.28 / 1.40. Answers with each zoom and its words, plus warnings. Show the user each zoom with its words, then stop for approval.",
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
    "description": "Pipeline step 9. Puts B-roll on V2 and downloads it into the project (Pixabay video by pixabayId or search, Unsplash photo by url, generated clips by url or file). Stock or generated only: a file is refused unless the shot has generated: true (an AI service or Claude made it). Follow the 'B-roll - Talking Head' style guide (read_style_guide). The user's own manually added clips stay. Downloads can take a while: if not done in 45 s, call status with wait: 45. Place every approved shot in one call. Show the user the spots and what's on V2, then stop for approval.",
    "inputSchema": ["type": "object", "properties": [
        "broll": ["type": "array", "description": "Shots: {at, length, kind (video/photo), and exactly one of pixabayId (a clip the user picked from a candidate sheet; preferred), search (Pixabay's top match, unchecked), url (an Unsplash photo with credit, a Pixabay link the user pasted, which becomes that exact clip, or a generated clip's link) or file (a generated clip on this Mac), reason, words}. Generated shots add generated: true and prompt (what made it); kind video for a generated video link.",
                  "items": ["type": "object", "properties": [
                    "at": ["type": "number"], "length": ["type": "number"], "kind": ["type": "string"],
                    "pixabayId": ["type": "integer"], "search": ["type": "string"], "url": ["type": "string"], "credit": ["type": "string"],
                    "reason": ["type": "string"], "words": ["type": "string"],
                    "file": ["type": "string"], "generated": ["type": "boolean"], "prompt": ["type": "string"]
                  ], "required": ["at"]]],
        "brollList": prop(objectOrString, "Instead of broll: the style guide's whole output object."),
        "mode": ["type": "string", "enum": ["replace", "clear"], "description": "replace (default) or clear (keeps the user's own clips)."],
        "download": prop("boolean", "Download the shots now (default true).")
    ]]
]

let tool_broll_candidates: [String: Any] = [
    "name": "broll_candidates",
    "description": "Step 7 helper: B-roll candidates from Pixabay as a numbered contact sheet of thumbnails (number, length and tags under each), returned as an image and saved in the project's B-roll Candidates folder. search: look at up to 40 results for a spot. Pixabay's API searches tags only and finds far fewer clips than pixabay.com, so a short sheet widens on its own (each word separately, then the also searches); add also with related scenes or objects for thin topics. ids: a sheet of just the clips you choose, in your order. spots: the whole-video review sheet, a titled row per spot with your pick first (outlined, labelled 1A, 2A…) and alternates after it (1B, 1C); picks can be Pixabay ids or links, generated clips on this Mac (file paths) or links to them. The user names only the spots to change.",
    "inputSchema": ["type": "object", "properties": [
        "search": prop("string", "Words to look for, e.g. phone on tripod in backyard. Search for the scene or object, not a mood."),
        "count": prop("number", "How many results to show for a search, 1 to 40 (default 20)."),
        "also": ["type": "array", "items": ["type": "string"], "description": "More searches to fill the sheet when the main one comes up short, e.g. [\"camera outdoors\", \"photographer field\"]. Duplicates are dropped."],
        "ids": ["type": "array", "items": ["type": ["integer", "string"]], "description": "Pixabay video ids, or Pixabay links the user pasted (page or download links), to show instead of searching, numbered in this order."],
        "title": prop("string", "Sheet title and file name, e.g. 0-54 talk into your camera."),
        "spots": ["type": "array", "description": "Whole-video review sheet instead of search/ids: [{title (e.g. 0:54 talk into your camera), picks: [your pick, then up to 2 alternates]}]. A pick is a Pixabay id or link, a file path to a generated clip or still, or a link to one.",
                  "items": ["type": "object", "properties": [
                    "title": ["type": "string"], "at": ["type": "number"], "words": ["type": "string"],
                    "picks": ["type": "array", "items": ["type": ["integer", "string"]]]
                  ], "required": ["picks"]]]
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
    "description": "Pipeline step 10, Motion Graphics: places the plates the user approved on V3 (replaces the current set; mode clear removes them all). They show in the preview and the export, above B-roll, never zoomed or graded. Show the user what's placed, then stop for approval.",
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
    "description": "The editing style guides from ~/Movies/1Shot/Style Guides (the ones the app uses). With no name: lists them. With a name: the full guide. Read the matching guide before steps 6–9 and follow its MUST/NEVER rules exactly.",
    "inputSchema": ["type": "object", "properties": [
        "name": prop("string", "e.g. \"Default - Talking Head\", \"Zooms - Talking Head\", \"B-roll - Talking Head\".")
    ]],
    "annotations": ["readOnlyHint": true]
]

let tool_read_workflow: [String: Any] = [
    "name": "read_workflow",
    "description": "The workflow you follow: the user's own (~/Movies/1Shot/Workflow.md) if they made one, else the built-in one. builtIn: true = the built-in one, e.g. as a starting point for the user's own.",
    "inputSchema": ["type": "object", "properties": [
        "builtIn": prop("boolean", "Show the built-in workflow even if the user has their own.")
    ]],
    "annotations": ["readOnlyHint": true]
]

let tool_save_workflow: [String: Any] = [
    "name": "save_workflow",
    "description": "Saves the user's own workflow to ~/Movies/1Shot/Workflow.md; it replaces the built-in workflow completely, in every new conversation. Only when the user asks to change how you work. Write the WHOLE workflow (start from read_workflow), show it to the user and get their OK before saving. The old file is kept as a backup. reset: true = back to the built-in workflow.",
    "inputSchema": ["type": "object", "properties": [
        "text": prop("string", "The whole workflow, as plain text or Markdown."),
        "reset": prop("boolean", "Remove the user's workflow (kept as a backup) and use the built-in one.")
    ]]
]

let tools: [[String: Any]] = [
    tool_status,
    tool_open_project,
    tool_snapshot_frame,
    tool_get_settings,
    tool_set_visual,
    tool_list_groups,
    tool_find_dead_air,
    tool_set_clip_trims,
    tool_set_clip_order,
    tool_compare_clips,
    tool_set_clip_groups,
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
    tool_read_style_guide,
    tool_read_workflow,
    tool_save_workflow
]

// What every AI is told, whatever workflow the user follows.
let instructionsHeader = """
1Shot is a Mac app for preparing multi-take talking-head YouTube videos. You drive it with these tools. Several projects can be open at once, each in its own window: you work in the one your last open_project used (status shows its project and lists openProjects), so the user can switch windows without moving you.

All times are seconds on the ORIGINAL clip, the same clock as the transcript. If a tool says a dialog is open in the app, ask the user to close it.

The user can define their own workflow. Below is the workflow to follow. If it differs from the "Pipeline step" numbers or the "stop for approval" notes in the tool descriptions, the workflow below wins. If the user asks to change how you work (order of steps, when to stop, steps to skip or add), offer to save it with save_workflow so it's used every time; read_workflow shows the current one.
"""

// The built-in workflow. A user's own ~/Movies/1Shot/Workflow.md replaces it completely.
let defaultWorkflow = """
Work the pipeline ONE STEP AT A TIME. Before each step, say which step is next and what you'll do, then wait for the user's go-ahead. After the step, show the result, ask for feedback and corrections, and wait. Never start the next step until they say so. Any step can be redone.
0 Open file: open_project. Show the project name, clip length and frame.
1 Clip in/out points: the first thing after the clips are in the Assets tab. find_dead_air measures the silence at the start and end of each clip and proposes an in/out for each. Show every clip with its dead air at start and end and the proposed in/out, flag anything odd (no voice found, a noise that may have been counted as sound), then STOP. The user approves or changes them; set_clip_trims applies the approved ones and rebuilds the A-roll. Clips play in the Assets-list order, top to bottom: if the user recorded out of order, they drag clips there, or say the order and you use set_clip_order. If the project has no Assets-tab clips (one video), skip this step.
2 Visual Design groups: compare_clips shows every clip (three frames each, as recorded) and a rough difference score per pair. Clip 1 defines the Default group: clips that look like it (same camera angle, framing, lighting, background, colour) stay in Default; each different look gets its own new group, named after what it looks like (e.g. "Close-up – lamp light"). Show the proposed groups with the reason for each, then STOP. After approval, set_clip_groups applies them. Skip this step if the project has one clip.
3 Visual Design: The user does this themself for now. Each clip belongs to a Visual Design group with its own look; list_groups shows them. Use get_settings and snapshot_frame to read their choices group by group, explain what you think each is for, and say plainly which you can't explain. Use set_visual only if they ask.
4 Sound Design: The user does this themself for now. Use get_settings with measure: true and explain the same way, including how far the edit is from YouTube's −14 LUFS. You can't listen, so their ears are the final say. Use set_sound only if they ask.
5 Start and stop points: create_transcript, read_transcript, then set_trim. Show in/out with the first and last words.
6 Ums, ahs and long silences: apply_cuts (mode replace) per the "Default - Talking Head" style guide. Show the count, seconds removed and a few examples. Filler words are often missing from the transcript, so expect the user to check this step.
7 Repeated phrases and mistakes: apply_cuts (mode add) per the same guide. Show each cut with the words it removes.
8 Zooms: apply_zooms per "Zooms - Talking Head". Show each zoom with its words.
9 B-roll: per "B-roll - Talking Head", stock or generated (Pixabay video, Unsplash photos, AI clips from vidIQ). ONE REVIEW SHEET FOR THE WHOLE VIDEO, not one spot at a time. (a) Choose all the spots and list them (time, words, length) with the source you plan for each: the shared B-roll Library first (~/Movies/1Shot/B-roll Library/library.json) when the user already approved a clip for the same idea; Pixabay for common scenes and actions; generated video (vidiq_generate_video, minimax-h3, 768p, 16:9) for a feeling on a person's face, people like the viewer that stock lacks, or a scene stock lacks; generated still (vidiq_image_generate) for a scene that needn't move. Never generate real events, products, brands, named people or readable text. STOP: the user approves the spots and sources. (b) Before generating, tell the user the total credits and their vidiq_balance and wait for an OK (one OK per batch; no paid retries without asking). Then do every spot without stopping: Pixabay spots get a broll_candidates search (up to 40) and your 3 best; generated spots all start at once and you poll vidiq_job_poll until done. Prompts follow the guide's generated look so every shot looks like one shoot. (c) Show ONE sheet: broll_candidates with spots (a row per spot, your pick first, up to 2 alternates), with every pick's link, which are generated, and one line per spot on why. STOP: the user names only the spots to change (e.g. 3B, skip 5, a pasted pixabay.com link, a new search, generate 4 instead); everything else is approved as A. Redo only those, then place everything in ONE apply_broll call (pixabayId for Pixabay; url or file plus generated: true and prompt for generated clips). Never place a clip the user hasn't seen on a sheet. Every placed clip goes into the shared B-roll Library automatically (generated ones too); placing one that's already there copies it instead of downloading. When the user asks to keep a clip they didn't place (a runner-up), save it with save_to_broll_library. A shot can also be framed: zoom (1–3, 1 = fill) and panX/panY (−1…1) on the shot in apply_broll zoom into it and pick which part shows. A shot can also be picture-in-picture: pipScale (0.15–1, size of the frame) and pipX/pipY (its centre in the 1920×1080 frame, y down) put it in a rounded box over the speaker; the user can also drag it on the video in the B-roll tab. Photos are still by default; push: true on a photo gives it a slow 100→108% push-in. Photos show whole at their own shape, uncropped, over the speaker (who shows around them and through a PNG's transparency); fit: false crops a photo to fill the frame, fit: true does the same whole-picture look for a video. For a whole-picture shot, pipScale is its size (1 = as big as fits the frame, up to 4), pipX/pipY its centre and rotation its turn in degrees clockwise; no box or shadow is added. apply_broll replaces the list, so send each shot's pip, rotation, push and fit fields back unchanged. Never use a vertical (portrait) video: horizontal only (the app leaves them off sheets and refuses to place one).
10 Motion Graphics (playful style: elements animate beside the speaker; full-screen only for the 1–2 biggest points; about one plate every 15–20 s): graphics_templates first. From the transcript, choose spots and propose plates (template, words, the red word marked with *asterisks*, side opposite the speaker for overlays, builds on the words for bullets). Show them with graphics_preview and list each with its time and words; stop for the user's picks and edits. Then apply_graphics with only what they approved, and stop for approval. For size or position tweaks after that, use adjust_graphics (one plate) or graphics_style (all plates); both are instant. Charts and numbers use the user's real numbers only: ask, never make them up. Keep plates off the speaker's face unless it's a deliberate comedic beat. The app does not check the face: plates go exactly where side, scale and dx/dy put them, so pick the side away from the speaker and check the preview sheet; the user fine-tunes size and position in the Graphics tab. Always include a name plate: a lowerThird with the user's channel handle as title and their tagline as subtitle, in the first 10–15 s of the edited video. Ask the user for the handle and tagline if you don't know them; never guess.
11 Export: not available in this version yet. The user exports with ⌘Y; its save sheet has a "Normalize loudness to −14 LUFS" checkbox (on by default).

Read the style guide with read_style_guide before steps 6 to 10.
"""

// MARK: - Workflow (the user's own, or the built-in one)

let workflowPath = NSHomeDirectory() + "/Movies/1Shot/Workflow.md"

/// The user's workflow if they have one (a non-empty Workflow.md), else nil.
func customWorkflow() -> String? {
    guard let text = try? String(contentsOfFile: workflowPath, encoding: .utf8) else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// Read when Claude connects, so a changed Workflow.md applies from the next conversation.
func instructions() -> String {
    if let custom = customWorkflow() {
        return instructionsHeader + "\nWORKFLOW (the user's own, from \(workflowPath)):\n" + custom
    }
    return instructionsHeader + "\nWORKFLOW (built-in):\n" + defaultWorkflow
}

func readWorkflow(_ args: [String: Any]) throws -> Any {
    if args["builtIn"] as? Bool == true {
        return ["source": "built-in", "text": defaultWorkflow] as [String: Any]
    }
    if let custom = customWorkflow() {
        return ["source": "custom", "file": workflowPath, "text": custom] as [String: Any]
    }
    return ["source": "built-in", "file": workflowPath, "note": "No Workflow.md yet, so the built-in workflow is used.", "text": defaultWorkflow] as [String: Any]
}

/// Keeps the previous Workflow.md as a dated backup before replacing or removing it.
func backUpWorkflow() throws -> String? {
    let fm = FileManager.default
    guard fm.fileExists(atPath: workflowPath) else { return nil }
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let backup = NSHomeDirectory() + "/Movies/1Shot/Workflow (backup \(stamp)).md.bak"
    try fm.moveItem(atPath: workflowPath, toPath: backup)
    return backup
}

func saveWorkflow(_ args: [String: Any]) throws -> Any {
    if args["reset"] as? Bool == true {
        let backup = try backUpWorkflow()
        var answer: [String: Any] = ["source": "built-in", "note": "Back to the built-in workflow from the next conversation."]
        if let backup { answer["backup"] = backup }
        return answer
    }
    guard let text = args["text"] as? String,
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw HelperError("Give the whole workflow as text, or reset: true to go back to the built-in one.")
    }
    try FileManager.default.createDirectory(atPath: (workflowPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let backup = try backUpWorkflow()
    try text.write(toFile: workflowPath, atomically: true, encoding: .utf8)
    var answer: [String: Any] = ["source": "custom", "file": workflowPath,
                                 "note": "Saved. Follow it from now on in this conversation; new conversations get it automatically."]
    if let backup { answer["backup"] = backup }
    return answer
}

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
        let value: Any
        switch name {
        case "read_style_guide": value = try readStyleGuide(args)
        case "read_workflow": value = try readWorkflow(args)
        case "save_workflow": value = try saveWorkflow(args)
        default: value = try App.call(name, args)
        }
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
            "instructions": instructions()
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

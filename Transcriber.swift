// Transcriber — makes the "edit transcript" for a clip: every word with its start/end time
// (Apple's on-device SpeechTranscriber, macOS 26+) plus every pause, measured from the audio level.
// Saved in the project's Transcripts folder as:
//   <clip>.json  — for Claude / tools: words, phrases, silences, in seconds on the original clip
//   <clip>.txt   — readable: phrases with minutes:seconds:frames times and the pauses between them

import Cocoa
import AVFoundation
#if compiler(>=6.2)
import Speech
#endif

struct EditTranscript: Codable {
    struct Word: Codable { var w: String; var s: Double; var e: Double }
    struct Segment: Codable { var s: Double; var e: Double; var text: String }
    struct Silence: Codable { var s: Double; var e: Double }

    var version = 1
    var clip: String                 // file name of the video
    var created: String              // ISO 8601
    var locale: String
    var duration: Double             // seconds
    var fps: Double
    var trimStart: Double?           // the project's trim when this was made (original-clip seconds)
    var trimEnd: Double?
    var pauseSource: String?         // what the pause detector listened to ("after voice isolation at 100%" / "on the raw audio")
    var silenceThresholdDB: Double   // audio below this level counts as silence
    var minSilence: Double           // seconds
    var segments: [Segment]          // phrases/sentences as the transcriber returned them
    var words: [Word]                // every word with its own timing
    var silences: [Silence]          // pauses at least `minSilence` long
    /// Set for an assembled A-roll (3.1.1): the exact build it was made from (which clips, each
    /// clip's in/out). Times are on that build's timeline, so after a rebuild that changes the
    /// recipe this transcript no longer lines up and the app treats it as missing. nil = one file.
    var source: String? = nil
}

enum TranscriptMaker {
    enum TranscriptError: LocalizedError {
        case needsMacOS26, noAudio, unsupportedLanguage, readFailed(String)
        var errorDescription: String? {
            switch self {
            case .needsMacOS26: return "Transcription uses Apple's SpeechTranscriber, which needs macOS 26 (Tahoe) and its developer tools."
            case .noAudio: return "This video has no audio track."
            case .unsupportedLanguage: return "Apple's on-device transcription doesn't support your Mac's language setting."
            case .readFailed(let m): return "Couldn't read the audio: \(m)"
            }
        }
    }

    static let minSilence = 0.4        // seconds
    private static let window = 0.01   // 10 ms level measurements

    static var isAvailable: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }

    /// The whole job. `status` is called on the main thread with a message and a 0…1 fraction (nil = unknown).
    /// `isolatedLevels`: loudness measured right after the voice isolator (10 ms steps), or nil
    /// to measure the raw audio.
    /// `asset` is the open clip — one file, or the assembled A-roll (an AVComposition). `name` is what
    /// the transcript calls it (and its file name); `source` is the A-roll's build recipe, nil for a file.
    static func make(asset: AVAsset, name: String, source: String?, fps: Double, trim: (start: Double, end: Double)?,
                     isolatedLevels: [Float]?,
                     status: @escaping (String, Double?) -> Void) async throws -> EditTranscript {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let report: (String, Double?) -> Void = { msg, f in DispatchQueue.main.async { status(msg, f) } }

            // 1. Audio → a temporary mono file for the transcriber, measuring loudness along the way.
            report("Reading audio…", 0)
            let audio = try await Task.detached(priority: .userInitiated) {
                try await extractAudio(from: asset) { f in report("Reading audio…", f) }
            }.value
            defer { try? FileManager.default.removeItem(at: audio.file) }
            let (threshold, levelSilences) = findSilences(levels: isolatedLevels ?? audio.levels)

            // 2. Words with timing.
            report("Preparing Apple's speech model…", nil)
            let (locale, segments, words) = try await transcribe(audio.file, duration: audio.duration) { f in
                report("Transcribing…", f)
            }

            // Backup: gaps between words the transcriber timed (catches pauses the level missed).
            var gaps: [EditTranscript.Silence] = []
            for (a, b) in zip(words, words.dropFirst()) where b.s - a.e >= minSilence {
                gaps.append(.init(s: a.e, e: b.s))
            }
            let silences = merge(levelSilences + gaps)

            let iso = ISO8601DateFormatter()
            return EditTranscript(clip: name, created: iso.string(from: Date()),
                                  locale: locale, duration: audio.duration, fps: fps,
                                  trimStart: trim?.start, trimEnd: trim?.end,
                                  pauseSource: isolatedLevels == nil ? "on the raw audio" : "after voice isolation at 100%",
                                  silenceThresholdDB: (threshold * 10).rounded() / 10, minSilence: minSilence,
                                  segments: segments, words: words, silences: silences, source: source)
        }
        #endif
        throw TranscriptError.needsMacOS26
    }

    // MARK: Audio

    private struct Audio { let file: URL; let duration: Double; let levels: [Float] }

    /// Decodes the clip's audio to 16 kHz mono (all speech needs), writes it to a temp file,
    /// and records the loudness (dBFS) of every 10 ms.
    private static func extractAudio(from asset: AVAsset, progress: (Double) -> Void) async throws -> Audio {
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { throw TranscriptError.noAudio }
        let duration = (try? await asset.load(.duration))?.seconds ?? 0

        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) else {
            throw TranscriptError.readFailed("audio format")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: AudioFeeder.readerSettings(for: format))
        guard reader.canAdd(output) else { throw TranscriptError.readFailed("can't add audio output") }
        reader.add(output)
        guard reader.startReading() else {
            throw TranscriptError.readFailed(reader.error?.localizedDescription ?? "unknown error")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("1Shot-transcribe-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)

        let windowSize = Int(format.sampleRate * window)
        var levels: [Float] = []
        var sum: Float = 0
        var count = 0
        var written = 0.0
        while let sample = output.copyNextSampleBuffer() {
            guard let pcm = AudioFeeder.pcmBuffer(from: sample, format: format),
                  let data = pcm.floatChannelData?[0] else { continue }
            try file.write(from: pcm)
            for i in 0..<Int(pcm.frameLength) {
                let v = data[i]
                sum += v * v
                count += 1
                if count == windowSize {
                    levels.append(10 * log10(max(sum / Float(count), 1e-12)))
                    sum = 0
                    count = 0
                }
            }
            written += Double(pcm.frameLength) / format.sampleRate
            if duration > 0 { progress(min(1, written / duration)) }
        }
        if reader.status == .failed {
            throw TranscriptError.readFailed(reader.error?.localizedDescription ?? "unknown error")
        }
        return Audio(file: url, duration: duration > 0 ? duration : written, levels: levels)
    }

    /// Pauses = stretches quieter than a threshold set from this clip's own noise floor and voice level.
    private static func findSilences(levels: [Float]) -> (Double, [EditTranscript.Silence]) {
        guard levels.count > 10 else { return (-50, []) }
        let sorted = levels.sorted()
        let floor = Double(sorted[Int(Double(sorted.count) * 0.10)])     // background noise
        let voice = Double(sorted[Int(Double(sorted.count) * 0.90)])     // talking
        let threshold = floor + max(6, (voice - floor) * 0.3)
        var result: [EditTranscript.Silence] = []
        var start: Int?
        for (i, level) in levels.enumerated() {
            if Double(level) < threshold {
                if start == nil { start = i }
            } else if let s = start {
                appendSilence(from: s, to: i, into: &result)
                start = nil
            }
        }
        if let s = start { appendSilence(from: s, to: levels.count, into: &result) }
        return (threshold, result)
    }

    private static func appendSilence(from a: Int, to b: Int, into result: inout [EditTranscript.Silence]) {
        let s = Double(a) * window, e = Double(b) * window
        if e - s >= minSilence { result.append(.init(s: round3(s), e: round3(e))) }
    }

    static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

    /// Sorts and joins overlapping or touching pauses.
    private static func merge(_ list: [EditTranscript.Silence]) -> [EditTranscript.Silence] {
        var out: [EditTranscript.Silence] = []
        for p in list.sorted(by: { $0.s < $1.s }) {
            if let last = out.last, p.s <= last.e + 0.02 {
                out[out.count - 1].e = max(last.e, p.e)
            } else {
                out.append(p)
            }
        }
        return out
    }

    // MARK: Loudness after the voice isolator

    /// Runs the clip's audio through its own copy of Apple's voice isolator — always at 100%,
    /// High Quality Voice, whatever the Audio drawer is set to — offline and faster than real time,
    /// and measures loudness every 10 ms. Isolated speech has near-total silence between words,
    /// so pauses stand out even in a noisy car. Returns nil if the isolator isn't available.
    @MainActor
    static func isolatedLevels(asset: AVAsset, progress: @escaping (Double) -> Void) async throws -> [Float]? {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw TranscriptError.noAudio }
        let duration = try await asset.load(.duration).seconds

        let desc = AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                             componentSubType: kAudioUnitSubType_AUSoundIsolation,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        let isolator: AVAudioUnit? = await withCheckedContinuation { cont in
            AVAudioUnit.instantiate(with: desc, options: []) { unit, _ in cont.resume(returning: unit) }
        }
        guard let isolator, let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else {
            return nil
        }
        if let tree = isolator.auAudioUnit.parameterTree {
            tree.parameter(withAddress: AUParameterAddress(kAUSoundIsolationParam_WetDryMixPercent))?.value = 100
            let soundType: Int
            if #available(macOS 15.0, *) { soundType = kAUSoundIsolationSoundType_HighQualityVoice }
            else { soundType = kAUSoundIsolationSoundType_Voice }
            tree.parameter(withAddress: AUParameterAddress(kAUSoundIsolationParam_SoundToIsolate))?.value = AUValue(soundType)
        }

        // A private engine, separate from the player's audio, rendering offline.
        let chunk: AVAudioFrameCount = 4096
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.attach(isolator)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: chunk)
        engine.connect(player, to: isolator, format: format)
        engine.connect(isolator, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        player.play()
        defer { player.stop(); engine.stop() }
        let latency = Int64((isolator.auAudioUnit.latency * format.sampleRate).rounded())

        return try await Task.detached(priority: .userInitiated) { () throws -> [Float] in
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: AudioFeeder.readerSettings(for: format))
            guard reader.canAdd(output) else { throw TranscriptError.readFailed("can't add audio output") }
            reader.add(output)
            guard reader.startReading(),
                  let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: chunk) else {
                throw TranscriptError.readFailed(reader.error?.localizedDescription ?? "unknown error")
            }
            let total = Int64(duration * format.sampleRate)
            let channels = Int(buffer.format.channelCount)
            let windowSize = Int(format.sampleRate * window)
            var levels: [Float] = []
            var sum: Float = 0
            var count = 0
            var scheduled: Int64 = 0, rendered: Int64 = 0, written: Int64 = 0
            var sourceEnded = false
            var stalls = 0
            while written < total {
                while !sourceEnded && scheduled < rendered + Int64(chunk) * 4 {
                    if let sample = output.copyNextSampleBuffer() {
                        if let pcm = AudioFeeder.pcmBuffer(from: sample, format: format) {
                            player.scheduleBuffer(pcm, completionHandler: nil)
                            scheduled += Int64(pcm.frameLength)
                        }
                    } else {
                        sourceEnded = true
                    }
                }
                let status = try engine.renderOffline(chunk, to: buffer)
                if status == .cannotDoInCurrentContext {
                    stalls += 1
                    if stalls > 1000 { break }
                    continue
                }
                guard status == .success, let data = buffer.floatChannelData else {
                    throw TranscriptError.readFailed("voice isolation render failed (\(status.rawValue))")
                }
                let got = Int64(buffer.frameLength)
                if got == 0 { break }
                let skip = max(0, min(got, latency - rendered))     // the isolator's processing delay
                rendered += got
                let usable = min(got - skip, total - written)
                guard usable > 0 else { continue }
                for i in Int(skip)..<Int(skip + usable) {
                    var v: Float = 0
                    for c in 0..<channels { v += data[c][i] * data[c][i] }
                    sum += v / Float(channels)
                    count += 1
                    if count == windowSize {
                        levels.append(10 * log10(max(sum / Float(count), 1e-12)))
                        sum = 0
                        count = 0
                    }
                }
                written += usable
                if levels.count % 500 == 0 { progress(Double(written) / Double(max(total, 1))) }
            }
            return levels
        }.value
    }

    // MARK: Speech

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    private static func transcribe(_ url: URL, duration: Double, progress: @escaping (Double) -> Void)
        async throws -> (String, [EditTranscript.Segment], [EditTranscript.Word]) {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw TranscriptError.unsupportedLanguage
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        // First use of a language downloads Apple's model (once).
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Start reading results before feeding audio.
        let collector = Task { () async throws -> ([EditTranscript.Segment], [EditTranscript.Word]) in
            var segments: [EditTranscript.Segment] = []
            var words: [EditTranscript.Word] = []
            for try await result in transcriber.results {
                guard result.isFinal else { continue }
                let text = result.text
                var phrase = ""
                for run in text.runs {
                    let piece = String(text[run.range].characters)
                    phrase += piece
                    let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    if let range = run.audioTimeRange {
                        // Usually one word per run; if a run holds several, share its time evenly.
                        let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
                        let s = range.start.seconds, e = range.end.seconds
                        let step = (e - s) / Double(max(tokens.count, 1))
                        for (k, token) in tokens.enumerated() {
                            words.append(.init(w: token, s: round3(s + step * Double(k)),
                                               e: round3(s + step * Double(k + 1))))
                        }
                    } else if !words.isEmpty {
                        words[words.count - 1].w += trimmed     // punctuation without its own timing
                    }
                }
                let s = result.range.start.seconds, e = result.range.end.seconds
                segments.append(.init(s: round3(s), e: round3(e),
                                      text: phrase.trimmingCharacters(in: .whitespacesAndNewlines)))
                if duration > 0 { progress(min(1, e / duration)) }
            }
            return (segments, words)
        }

        let file = try AVAudioFile(forReading: url)
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let (segments, words) = try await collector.value
        return (locale.identifier, segments, words)
    }
    #endif

    // MARK: Files

    /// Writes <clip>.json and <clip>.txt into `folder`; returns the JSON file.
    static func write(_ t: EditTranscript, to folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A file name loses its extension; an A-roll name ("My Video (A-roll)") has none to lose.
        let base = t.source == nil ? (t.clip as NSString).deletingPathExtension : t.clip
        let json = folder.appendingPathComponent(base + ".json")
        let txt = folder.appendingPathComponent(base + ".txt")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(t).write(to: json, options: .atomic)
        try readable(t).write(to: txt, atomically: true, encoding: .utf8)
        return json
    }

    /// Phrases with times, and the pauses between them, for reading (or pasting to Claude).
    static func readable(_ t: EditTranscript) -> String {
        let tc = TrimBar.format
        var lines = ["1Shot edit transcript — \(t.clip)",
                     "Length \(tc(t.duration)) at \(Int(t.fps.rounded())) fps · times are minutes:seconds:frames on the original clip"]
        if let s = t.trimStart, let e = t.trimEnd { lines.append("Trim when made: \(tc(s)) – \(tc(e))") }
        lines.append("Pauses of \(String(format: "%.1f", t.minSilence)) s or more are marked (silence below \(Int(t.silenceThresholdDB)) dBFS, measured \(t.pauseSource ?? "on the raw audio"); gaps between words count too).")
        lines.append("")
        var silences = t.silences[...]
        for seg in t.segments {
            while let p = silences.first, p.s < seg.s {
                lines.append("        · pause \(String(format: "%.1f", p.e - p.s)) s  (\(tc(p.s)) → \(tc(p.e)))")
                silences = silences.dropFirst()
            }
            lines.append("[\(tc(seg.s)) → \(tc(seg.e))]  \(seg.text)")
            // Pauses inside this phrase.
            while let p = silences.first, p.s < seg.e {
                lines.append("        · pause \(String(format: "%.1f", p.e - p.s)) s  (\(tc(p.s)) → \(tc(p.e)))")
                silences = silences.dropFirst()
            }
        }
        for p in silences {
            lines.append("        · pause \(String(format: "%.1f", p.e - p.s)) s  (\(tc(p.s)) → \(tc(p.e)))")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Progress sheet with a message and a bar (spinning when the amount is unknown).
final class TaskProgressSheet: NSObject {
    let window: NSWindow
    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()

    init(title: String) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 110),
                          styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: 13)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        let stack = NSStackView(views: [heading, label, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        bar.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = stack
        bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
    }

    func update(_ message: String, _ fraction: Double?) {
        label.stringValue = message
        if let fraction {
            if bar.isIndeterminate { bar.stopAnimation(nil); bar.isIndeterminate = false }
            bar.doubleValue = fraction
        } else if !bar.isIndeterminate {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        }
    }
}

// DavinciExport — File › Export Timeline for DaVinci: writes the trimmed, cut edit as an
// FCPXML timeline that points at the original video. DaVinci Resolve (free or Studio) opens it
// with File › Import › Timeline, and every cut becomes a real edit point you can still adjust.
// Only the edit travels: color, LUTs and the Sound Design chain stay in 1Shot.

import AVFoundation
import Foundation

enum DavinciExport {
    enum ExportError: LocalizedError {
        case noVideo, nothingKept
        var errorDescription: String? {
            switch self {
            case .noVideo: return "This file has no video track."
            case .nothingKept: return "The cuts and trim leave nothing to export."
            }
        }
    }

    /// Builds the FCPXML text for `video` with everything outside `trim` and inside `cuts` removed.
    static func fcpxml(video url: URL, fps: Double, trim: (start: Double, end: Double), cuts: [Cut],
                       timelineName: String) async throws -> String {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideo }
        let duration = try await asset.load(.duration).seconds
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let size = natural.applying(transform)
        let width = Int(abs(size.width).rounded()), height = Int(abs(size.height).rounded())

        // Audio layout, if there is audio.
        var channels = 0, sampleRate = 48000
        if let audio = try await asset.loadTracks(withMediaType: .audio).first,
           let desc = try await audio.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
            channels = Int(asbd.mChannelsPerFrame)
            sampleRate = Int(asbd.mSampleRate)
        }

        // Timeline rate as an exact fraction (29.97 = 1001/30000 s per frame, and so on).
        let (num, den) = frameDuration(fps: fps)
        let rate = Double(den) / Double(num)
        func frames(_ seconds: Double) -> Int { Int((seconds * rate).rounded()) }
        func time(_ frames: Int) -> String { frames == 0 ? "0s" : "\(frames * num)/\(den)s" }

        // Clips from cameras/apps that write source timecode: Resolve matches on it, so offset by it.
        let tcStart = await startTimecodeSeconds(of: asset) ?? 0
        let assetStart = frames(tcStart)
        let assetDuration = frames(duration)

        var clips: [(start: Int, length: Int)] = []
        for (s, e) in CutList.keptSegments(start: trim.start, end: trim.end, cuts: cuts) {
            let a = frames(s), b = frames(e)
            if b > a { clips.append((a, b - a)) }
        }
        guard !clips.isEmpty else { throw ExportError.nothingKept }
        let total = clips.reduce(0) { $0 + $1.length }

        let clipName = escape(url.deletingPathExtension().lastPathComponent)
        let audioAttrs = channels > 0
            ? " hasAudio=\"1\" audioSources=\"1\" audioChannels=\"\(channels)\" audioRate=\"\(sampleRate)\""
            : ""
        let audioLayout = channels == 1 ? "mono" : "stereo"
        let audioRate = sampleRate == 44100 ? "44.1k" : (sampleRate == 96000 ? "96k" : "48k")

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.9">
            <resources>
                <format id="r1" frameDuration="\(num)/\(den)s" width="\(width)" height="\(height)"/>
                <asset id="r2" name="\(clipName)" start="\(time(assetStart))" duration="\(time(assetDuration))" hasVideo="1" format="r1"\(audioAttrs)>
                    <media-rep kind="original-media" src="\(escape(url.absoluteString))"/>
                </asset>
            </resources>
            <library>
                <event name="1Shot">
                    <project name="\(escape(timelineName))">
                        <sequence format="r1" duration="\(time(total))" tcStart="0s" tcFormat="NDF" audioLayout="\(audioLayout)" audioRate="\(audioRate)">
                            <spine>

        """
        var offset = 0
        for c in clips {
            xml += "                        <asset-clip ref=\"r2\" name=\"\(clipName)\" offset=\"\(time(offset))\" "
                + "start=\"\(time(assetStart + c.start))\" duration=\"\(time(c.length))\" format=\"r1\" tcFormat=\"NDF\"/>\n"
            offset += c.length
        }
        xml += """
                            </spine>
                        </sequence>
                    </project>
                </event>
            </library>
        </fcpxml>

        """
        return xml
    }

    static func frameDuration(fps: Double) -> (Int, Int) {
        for (r, n, d) in [(23.976, 1001, 24000), (29.97, 1001, 30000), (59.94, 1001, 60000)] where abs(fps - r) < 0.02 {
            return (n, d)
        }
        let whole = max(1, Int(fps.rounded()))
        return (100, whole * 100)
    }

    /// The first timecode in the file's timecode track, in seconds (nil if it has none).
    private static func startTimecodeSeconds(of asset: AVAsset) async -> Double? {
        guard let track = try? await asset.loadTracks(withMediaType: .timecode).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading(), let sample = output.copyNextSampleBuffer(),
              let block = CMSampleBufferGetDataBuffer(sample),
              let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
        defer { reader.cancelReading() }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer else { return nil }
        let raw = UnsafeRawPointer(pointer)
        let frameNumber: Int
        if CMFormatDescriptionGetMediaSubType(format) == kCMTimeCodeFormatType_TimeCode64, length >= 8 {
            frameNumber = Int(Int64(bigEndian: raw.loadUnaligned(as: Int64.self)))
        } else if length >= 4 {
            frameNumber = Int(Int32(bigEndian: raw.loadUnaligned(as: Int32.self)))
        } else {
            return nil
        }
        let frame = CMTimeCodeFormatDescriptionGetFrameDuration(format)
        guard frame.seconds > 0 else { return nil }
        return Double(frameNumber) * frame.seconds
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

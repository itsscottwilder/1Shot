// ClipInfo — the file details shown under a clip in the Assets list (3.5): resolution, aspect
// ratio, frame rate, codec, colour, bitrates, audio, camera, file size. Read once per file and kept.

import Cocoa
import AVFoundation
import UniformTypeIdentifiers

struct ClipInfo {
    /// Label/value pairs, in the order they're shown.
    var lines: [(label: String, value: String)]

    /// Every file read so far, by path. Details don't change while the app is open.
    @MainActor private static var cache: [String: ClipInfo] = [:]

    @MainActor static func cached(_ url: URL) -> ClipInfo? { cache[url.path] }

    @MainActor static func load(_ url: URL) async -> ClipInfo {
        if let hit = cache[url.path] { return hit }
        let info = await read(url)
        cache[url.path] = info
        return info
    }

    private static func read(_ url: URL) async -> ClipInfo {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ClipInfo(lines: [("File", "Not found")])
        }
        var lines: [(String, String)] = []
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0

        if let video = try? await asset.loadTracks(withMediaType: .video).first {
            let natural = (try? await video.load(.naturalSize)) ?? .zero
            let transform = (try? await video.load(.preferredTransform)) ?? .identity
            let shown = natural.applying(transform)
            let w = Int(abs(shown.width).rounded()), h = Int(abs(shown.height).rounded())
            if w > 0, h > 0 {
                var res = "\(w) × \(h)"
                if let name = resolutionName(w, h) { res += "  (\(name))" }
                let degrees = Int((atan2(transform.b, transform.a) * 180 / .pi).rounded())
                if degrees != 0 { res += ", rotated \(degrees)°" }
                lines.append(("Resolution", res))
                lines.append(("Aspect ratio", aspectName(w, h)))
            }
            let fps = (try? await video.load(.nominalFrameRate)) ?? 0
            if fps > 0 { lines.append(("Frame rate", fpsText(Double(fps)))) }

            let formats = (try? await video.load(.formatDescriptions)) ?? []
            if let format = formats.first {
                var codec = videoCodecName(CMFormatDescriptionGetMediaSubType(format))
                if let bits = bitDepth(format) { codec += ", \(bits)-bit" }
                lines.append(("Video codec", codec))
                if let color = colorText(format) { lines.append(("Colour", color)) }
            }
            let rate = (try? await video.load(.estimatedDataRate)) ?? 0
            if rate > 0 { lines.append(("Video bitrate", bitrateText(Double(rate)))) }
        }

        if let audio = try? await asset.loadTracks(withMediaType: .audio).first {
            let formats = (try? await audio.load(.formatDescriptions)) ?? []
            var parts: [String] = []
            if let format = formats.first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                parts.append(audioCodecName(asbd.mFormatID))
                if asbd.mSampleRate > 0 {
                    let khz = asbd.mSampleRate / 1000
                    parts.append(khz == khz.rounded() ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz))
                }
                if asbd.mBitsPerChannel > 0 { parts.append("\(asbd.mBitsPerChannel)-bit") }
                switch asbd.mChannelsPerFrame {
                case 0: break
                case 1: parts.append("mono")
                case 2: parts.append("stereo")
                default: parts.append("\(asbd.mChannelsPerFrame) channels")
                }
            }
            if !parts.isEmpty { lines.append(("Audio", parts.joined(separator: ", "))) }
            // Its own line, like the video's: one line is too narrow for codec, rate, channels and bitrate.
            let rate = (try? await audio.load(.estimatedDataRate)) ?? 0
            if rate > 0 { lines.append(("Audio bitrate", bitrateText(Double(rate)))) }
        } else {
            lines.append(("Audio", "None"))
        }

        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .creationDateKey])
        let container = (values?.contentType ?? UTType(filenameExtension: url.pathExtension))?.localizedDescription
        if let size = values?.fileSize {
            var text = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            if duration.isFinite, duration > 0 { text += ", \(bitrateText(Double(size) * 8 / duration)) overall" }
            lines.append(("File", text))
        }
        if let container { lines.append(("Container", container)) }

        let metadata = (try? await asset.load(.metadata)) ?? []
        if let camera = await cameraName(metadata) { lines.append(("Camera", camera)) }
        var recorded: Date?
        if let item = try? await asset.load(.creationDate) { recorded = try? await item.load(.dateValue) }
        if recorded == nil { recorded = values?.creationDate }
        if let recorded {
            lines.append(("Recorded", recorded.formatted(date: .abbreviated, time: .shortened)))
        }
        return ClipInfo(lines: lines)
    }

    // MARK: - Names

    private static func resolutionName(_ w: Int, _ h: Int) -> String? {
        let long = max(w, h), short = min(w, h)
        switch (long, short) {
        case (7680, 4320): return "8K UHD"
        case (5760...6200, 3240...3456): return "6K"
        case (5120, 2880): return "5K"
        case (4096, _): return "DCI 4K"
        case (3840, 2160): return "4K UHD"
        case (2560, 1440): return "1440p"
        case (1920, 1080): return "1080p"
        case (1280, 720): return "720p"
        default: return nil
        }
    }

    private static func aspectName(_ w: Int, _ h: Int) -> String {
        let ratio = Double(w) / Double(h)
        let known: [(String, Double)] = [("16:9", 16.0 / 9), ("9:16", 9.0 / 16), ("4:3", 4.0 / 3), ("3:4", 3.0 / 4),
                                         ("1:1", 1), ("21:9", 21.0 / 9), ("3:2", 1.5), ("2:3", 2.0 / 3), ("4:5", 0.8)]
        let orientation = w > h ? "landscape" : w < h ? "portrait" : "square"
        if let match = known.first(where: { abs($0.1 - ratio) < 0.01 }) {
            return "\(match.0)  (\(orientation))"
        }
        return String(format: "%.2f:1  (%@)", ratio, orientation)
    }

    private static func fpsText(_ fps: Double) -> String {
        for standard in [23.976, 29.97, 59.94, 119.88] where abs(fps - standard) < 0.01 {
            return String(format: "%.3g fps", standard)
        }
        return fps == fps.rounded() ? "\(Int(fps)) fps" : String(format: "%.2f fps", fps)
    }

    private static func bitrateText(_ bitsPerSecond: Double) -> String {
        bitsPerSecond >= 1_000_000
            ? String(format: "%.1f Mb/s", bitsPerSecond / 1_000_000)
            : String(format: "%.0f kb/s", bitsPerSecond / 1_000)
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((code >> $0) & 0xFF))) }
        return String(chars).trimmingCharacters(in: .whitespaces)
    }

    private static func videoCodecName(_ code: FourCharCode) -> String {
        switch fourCC(code) {
        case "avc1", "avc3": return "H.264"
        case "hvc1", "hev1": return "HEVC (H.265)"
        case "apch": return "Apple ProRes 422 HQ"
        case "apcn": return "Apple ProRes 422"
        case "apcs": return "Apple ProRes 422 LT"
        case "apco": return "Apple ProRes 422 Proxy"
        case "ap4h": return "Apple ProRes 4444"
        case "ap4x": return "Apple ProRes 4444 XQ"
        case "aprn": return "Apple ProRes RAW"
        case "aprh": return "Apple ProRes RAW HQ"
        case "av01": return "AV1"
        case "vp09": return "VP9"
        case "jpeg", "mjpa", "mjpb": return "Motion JPEG"
        case "dvh1", "dvhe": return "Dolby Vision (HEVC)"
        case let other: return other
        }
    }

    private static func audioCodecName(_ id: AudioFormatID) -> String {
        switch id {
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: return "AAC"
        case kAudioFormatLinearPCM: return "PCM (uncompressed)"
        case kAudioFormatAppleLossless: return "Apple Lossless"
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatAC3: return "Dolby Digital"
        case kAudioFormatEnhancedAC3: return "Dolby Digital Plus"
        case kAudioFormatOpus: return "Opus"
        case kAudioFormatFLAC: return "FLAC"
        default: return fourCC(id)
        }
    }

    private static func bitDepth(_ format: CMFormatDescription) -> Int? {
        if let bits = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? Int {
            return bits
        }
        // 10-bit HEVC (iPhone HDR, most mirrorless log) often only says so in its profile; HLG/PQ imply it.
        if let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String,
           transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
            || transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) {
            return 10
        }
        return nil
    }

    private static func colorText(_ format: CMFormatDescription) -> String? {
        func ext(_ key: CFString) -> String? { CMFormatDescriptionGetExtension(format, extensionKey: key) as? String }
        func same(_ value: String?, _ constant: CFString) -> Bool { value == (constant as String) }
        let transfer = ext(kCMFormatDescriptionExtension_TransferFunction)
        let primaries = ext(kCMFormatDescriptionExtension_ColorPrimaries)
        var range: String?
        if same(transfer, kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG) { range = "HDR (HLG)" }
        else if same(transfer, kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ) { range = "HDR (PQ / HDR10)" }
        else if transfer != nil { range = "SDR" }
        var gamut: String?
        if same(primaries, kCMFormatDescriptionColorPrimaries_ITU_R_2020) { gamut = "Rec. 2020" }
        else if same(primaries, kCMFormatDescriptionColorPrimaries_P3_D65) { gamut = "Display P3" }
        else if same(primaries, kCMFormatDescriptionColorPrimaries_DCI_P3) { gamut = "DCI-P3" }
        else if same(primaries, kCMFormatDescriptionColorPrimaries_ITU_R_709_2) { gamut = "Rec. 709" }
        let parts = [range, gamut].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func cameraName(_ metadata: [AVMetadataItem]) async -> String? {
        func value(_ id: AVMetadataIdentifier) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: id).first else { return nil }
            return try? await item.load(.stringValue)
        }
        var make = await value(.quickTimeMetadataMake)
        if make == nil { make = await value(.commonIdentifierMake) }
        var model = await value(.quickTimeMetadataModel)
        if model == nil { model = await value(.commonIdentifierModel) }
        guard let model, !model.isEmpty else { return make }
        if let make, !make.isEmpty, !model.lowercased().hasPrefix(make.lowercased()) { return "\(make) \(model)" }
        return model
    }
}

// Exporter — writes a new .mov: the original video copied untouched (no re-encode)
// plus the audio rendered through the current plugin chain, faster than real time.

import Cocoa
import AVFoundation
import VideoToolbox

final class VideoExporter {
    enum ExportError: LocalizedError {
        case cancelled
        case message(String)
        var errorDescription: String? {
            switch self {
            case .cancelled: return "Export cancelled."
            case .message(let m): return m
            }
        }
    }

    struct Source {
        let asset: AVAsset
        let audioTrack: AVAssetTrack
        let videoTrack: AVAssetTrack?
        let videoTransform: CGAffineTransform
        let videoSize: CGSize          // as stored (before rotation)
        let frameRate: Double
        let videoComposition: AVVideoComposition?   // color grade (already applies rotation)
        let start: Double      // trim in-point (seconds)
        let end: Double        // trim out-point (seconds)
        var tailBlack: Double = 0   // seconds of black picture + silence added after the end
        var cuts: [Cut] = []        // pieces removed from inside start…end (original-clip seconds)
        var fadeEnd: Double? = nil  // fade the sound to silence over the 0.5 s before this (original-clip seconds)
        var outputGain: Float = 1   // after Sound Design (normalizing with the limiter off); 1 = unchanged
        var recipe: ExportRecipe? = nil   // 3.2: container/codec/size/bitrate/audio; nil = YouTube at source size
    }

    /// LUFS of the audio that went into the file (set when the export finishes).
    private(set) var finalLoudness: LUFSMeter.Reading?

    var onProgress: ((Double) -> Void)?     // called on the main thread, 0…1

    private let rack: AudioRack
    private let source: Source
    private let outputURL: URL
    private let chunk: AVAudioFrameCount = 4096
    private let lock = NSLock()
    private var _cancelled = false
    private var _failure: Error?

    init(rack: AudioRack, source: Source, outputURL: URL) {
        self.rack = rack
        self.source = source
        self.outputURL = outputURL
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    private var failure: Error? { lock.lock(); defer { lock.unlock() }; return _failure }
    private func fail(_ error: Error) {
        lock.lock(); if _failure == nil { _failure = error }; lock.unlock()
    }

    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }

    /// Call on the main thread. `completion` runs on the main thread (nil error = success).
    func start(completion: @escaping (Error?) -> Void) {
        let format: AVAudioFormat
        do {
            format = try rack.beginOfflineRender(maxFrames: chunk)
        } catch {
            rack.endOfflineRender()
            completion(error)
            return
        }
        let latencyFrames = AVAudioFramePosition((rack.totalLatency * format.sampleRate).rounded())
        NSLog("1Shot: exporting to \(outputURL.path) (plugin latency \(latencyFrames) frames)")

        DispatchQueue.global(qos: .userInitiated).async {
            self.write(format: format, latencyFrames: latencyFrames) { error in
                DispatchQueue.main.async {
                    self.rack.endOfflineRender()
                    let result: Error? = self.isCancelled ? ExportError.cancelled : error
                    if result != nil { try? FileManager.default.removeItem(at: self.outputURL) }
                    completion(result)
                }
            }
        }
    }

    // MARK: - Background work

    private func write(format: AVAudioFormat, latencyFrames: AVAudioFramePosition,
                       done: @escaping (Error?) -> Void) {
        do {
            try? FileManager.default.removeItem(at: outputURL)
            // YouTube's recommended upload settings: MP4, fast start (moov atom first), no edit lists.
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: source.recipe?.fileType ?? .mp4)
            writer.shouldOptimizeForNetworkUse = true

            // Audio source (decoded to float PCM, fed into the plugin chain)
            let audioReader = try AVAssetReader(asset: source.asset)
            let audioOut = AVAssetReaderTrackOutput(track: source.audioTrack,
                                                    outputSettings: AudioFeeder.readerSettings(for: format))
            audioOut.alwaysCopiesSampleData = false
            guard audioReader.canAdd(audioOut) else { throw ExportError.message("Can't read the audio track.") }
            audioReader.add(audioOut)

            // Trim points, on the audio sample clock so audio lines up exactly.
            // The new file's timeline starts at zero (no edit lists).
            let rate = CMTimeScale(format.sampleRate)
            let startTime = CMTime(value: CMTimeValue((source.start * format.sampleRate).rounded()), timescale: rate)
            // Kept parts of the trimmed clip (everything, if there are no cuts).
            let cuts = CutList.normalized(source.cuts, trim: (source.start, source.end))
            let segments = CutList.keptSegments(start: source.start, end: source.end, cuts: cuts)
            let keptSeconds = segments.reduce(0) { $0 + ($1.1 - $1.0) }
            let contentFrames = AVAudioFramePosition((keptSeconds * format.sampleRate).rounded())
            let contentDuration = CMTime(value: contentFrames, timescale: rate)
            // Plus any black/silent tail (fade to black adds 2 s after the end).
            let totalFrames = contentFrames + AVAudioFramePosition((max(0, source.tailBlack) * format.sampleRate).rounded())
            let outputDuration = CMTime(value: totalFrames, timescale: rate)
            audioReader.timeRange = CMTimeRange(start: startTime, duration: .positiveInfinity)

            // Video: decoded and re-encoded as H.264 High profile, CABAC, keyframe every
            // half second, at YouTube's recommended bitrate for the resolution/frame rate.
            let video: (reader: AVAssetReader, output: AVAssetReaderOutput,
                        input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor,
                        width: Int, height: Int, fps: Double)?
            if let track = source.videoTrack {
                let r = try AVAssetReader(asset: source.asset)
                let o: AVAssetReaderOutput
                var width = Self.even(source.videoSize.width)
                var height = Self.even(source.videoSize.height)
                var transform = source.videoTransform
                if let comp = source.videoComposition {
                    // Frames come out color-graded and already rotated upright.
                    let compOut = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                    ])
                    compOut.videoComposition = comp
                    o = compOut
                    width = Self.even(comp.renderSize.width)
                    height = Self.even(comp.renderSize.height)
                    transform = .identity
                } else {
                    o = AVAssetReaderTrackOutput(track: track, outputSettings: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                        AVVideoColorPropertiesKey: Self.rec709        // HDR iPhone footage → standard (SDR) color
                    ])
                }
                o.alwaysCopiesSampleData = false
                guard r.canAdd(o) else { throw ExportError.message("Can't read the video track.") }
                r.add(o)
                r.timeRange = CMTimeRange(start: CMTime(seconds: source.start, preferredTimescale: 600),
                                          end: CMTime(seconds: source.end, preferredTimescale: 600))

                let fps = source.frameRate > 1 ? source.frameRate : 30
                // The recipe (3.2) picks codec, output size and bitrate; frames are scaled by the
                // encoder when the size differs from the source (aspect kept).
                let recipe = source.recipe
                let codec = recipe?.codec ?? .h264
                let (outW, outH) = recipe?.outputSize(sourceWidth: width, sourceHeight: height) ?? (width, height)
                var settings: [String: Any] = [
                    AVVideoCodecKey: codec,
                    AVVideoWidthKey: outW,
                    AVVideoHeightKey: outH,
                    AVVideoColorPropertiesKey: Self.rec709
                ]
                if outW != width || outH != height { settings[AVVideoScalingModeKey] = AVVideoScalingModeResizeAspect }
                if recipe?.isProRes != true {
                    var props: [String: Any] = [
                        AVVideoAverageBitRateKey: recipe?.bitrate(fps: fps) ?? Self.youTubeBitrate(width: outW, height: outH, fps: fps),
                        AVVideoMaxKeyFrameIntervalKey: max(1, Int((fps / 2).rounded())),
                        AVVideoAllowFrameReorderingKey: true,
                        AVVideoExpectedSourceFrameRateKey: Int(fps.rounded())
                    ]
                    if codec == .hevc {
                        props[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
                    } else {
                        props[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
                        props[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
                    }
                    settings[AVVideoCompressionPropertiesKey] = props
                }
                let i = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
                i.transform = transform          // keeps iPhone rotation correct
                i.expectsMediaDataInRealTime = false
                guard writer.canAdd(i) else {
                    throw ExportError.message("This Mac can't set up the \(recipe?.name ?? "H.264") encoder at \(outW)×\(outH).")
                }
                writer.add(i)
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: i, sourcePixelBufferAttributes: nil)
                video = (r, o, i, adaptor, width, height, fps)
            } else {
                video = nil
            }

            // Processed audio → AAC-LC, 48 kHz stereo. YouTube suggests 384 kbps, but Apple's AAC
            // encoder tops out at 320 kbps for stereo — asking for more fails with "Cannot Encode Media".
            let audioSettings: [String: Any]
            if let recipe = source.recipe, recipe.audioKbps == nil {
                // Masters: uncompressed 24-bit PCM.
                audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                                 AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false,
                                 AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
            } else {
                audioSettings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                                 AVEncoderBitRateKey: min(320, source.recipe?.audioKbps ?? 320) * 1000]
            }
            let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioIn.expectsMediaDataInRealTime = false
            guard writer.canAdd(audioIn) else { throw ExportError.message("Can't add the audio track.") }
            writer.add(audioIn)

            guard audioReader.startReading() else {
                throw audioReader.error ?? ExportError.message("Couldn't start reading the audio.")
            }
            if let video, !video.reader.startReading() {
                throw video.reader.error ?? ExportError.message("Couldn't start reading the video.")
            }
            guard writer.startWriting() else {
                throw Self.describe(writer.error, stage: "starting the file")
            }
            writer.startSession(atSourceTime: .zero)

            guard let renderBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
                  let interleaved = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                                  channels: 2, interleaved: true) else {
                throw ExportError.message("Couldn't set up audio buffers.")
            }
            var formatDesc: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: interleaved.streamDescription,
                                           layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                           extensions: nil, formatDescriptionOut: &formatDesc)
            guard let formatDesc else { throw ExportError.message("Couldn't describe the audio format.") }

            let group = DispatchGroup()
            let state = PumpState()
            let loudness = LUFSMeter(sampleRate: format.sampleRate)
            let hasVideo = video != nil
            let report = {
                let progress = hasVideo ? min(state.audioProgress, state.videoProgress) : state.audioProgress
                DispatchQueue.main.async { self.onProgress?(progress) }
            }

            // ---- Video pump
            if let video {
                let videoIn = video.input
                let videoOut = video.output
                let adaptor = video.adaptor
                let totalSeconds = max(outputDuration.seconds, 0.001)
                group.enter()
                // After the real frames: black frames to fill the tail (if any).
                state.blackTime = contentDuration
                let frameStep = CMTime(seconds: 1 / video.fps, preferredTimescale: 60_000)
                let black = source.tailBlack > 0 ? Self.blackFrame(width: video.width, height: video.height) : nil
                let finishVideo = {
                    state.videoFinished = true
                    state.videoProgress = 1
                    videoIn.markAsFinished()
                    group.leave()
                }
                videoIn.requestMediaDataWhenReady(on: DispatchQueue(label: "1Shot.export.video")) {
                    guard !state.videoFinished else { return }
                    while videoIn.isReadyForMoreMediaData {
                        if self.isCancelled || self.failure != nil { finishVideo(); return }
                        if state.contentDone {
                            guard let black, state.blackTime < outputDuration else { finishVideo(); return }
                            if !adaptor.append(black, withPresentationTime: state.blackTime) {
                                self.fail(Self.describe(writer.error, stage: "adding the black ending"))
                                finishVideo(); return
                            }
                            state.blackTime = CMTimeAdd(state.blackTime, frameStep)
                            continue
                        }
                        guard let sample = videoOut.copyNextSampleBuffer() else { state.contentDone = true; continue }
                        guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
                        // Shift onto the new timeline that starts at zero, closing up any cuts.
                        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                        var time = CMTimeSubtract(pts, startTime)
                        if !cuts.isEmpty {
                            let t = pts.seconds
                            if CutList.cut(containing: t, in: cuts) != nil { continue }     // frame is cut out
                            let removed = CutList.removed(before: t, cuts: cuts)
                            time = CMTimeSubtract(time, CMTime(value: CMTimeValue((removed * format.sampleRate).rounded()),
                                                               timescale: rate))
                        }
                        if time < .zero {
                            // The frame showing at the trim point starts a hair earlier — pin it to zero.
                            if state.videoAppended { continue }
                            time = .zero
                        }
                        if time >= contentDuration { state.contentDone = true; continue }
                        if !adaptor.append(pixels, withPresentationTime: time) {
                            self.fail(Self.describe(writer.error, stage: "encoding the video"))
                            finishVideo(); return
                        }
                        state.videoAppended = true
                        state.videoFrames += 1
                        if state.videoFrames % 15 == 0 {
                            state.videoProgress = min(1, time.seconds / totalSeconds)
                            report()
                        }
                    }
                }
            }

            // ---- Audio pump: decode → plugin chain → AAC

            group.enter()
            let finishAudio = {
                state.audioFinished = true
                audioIn.markAsFinished()
                group.leave()
            }
            audioIn.requestMediaDataWhenReady(on: DispatchQueue(label: "1Shot.export.audio")) {
                guard !state.audioFinished else { return }
                while audioIn.isReadyForMoreMediaData {
                    if self.isCancelled || self.failure != nil || state.written >= totalFrames { finishAudio(); return }

                    // Keep a little decoded audio queued ahead of the renderer.
                    while !state.sourceEnded && state.scheduled < state.renderedRaw + AVAudioFramePosition(self.chunk) * 4 {
                        if let sample = audioOut.copyNextSampleBuffer() {
                            if var pcm = AudioFeeder.pcmBuffer(from: sample, format: format) {
                                let t0 = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                                if let fadeEnd = self.source.fadeEnd {
                                    AudioFeeder.applyFadeOut(to: pcm, startingAt: t0, fadeEnd: fadeEnd)
                                }
                                if !cuts.isEmpty {
                                    // Drop the cut-out audio, with tiny fades so the joins don't click.
                                    guard let kept = AudioFeeder.keepOnly(pcm, startingAt: t0, segments: segments) else { continue }
                                    pcm = kept
                                }
                                self.rack.scheduleForExport(pcm)
                                state.scheduled += AVAudioFramePosition(pcm.frameLength)
                            }
                        } else {
                            state.sourceEnded = true
                        }
                    }

                    let remaining = totalFrames + latencyFrames - state.renderedRaw
                    guard remaining > 0 else { finishAudio(); return }
                    let want = AVAudioFrameCount(min(AVAudioFramePosition(self.chunk), remaining))

                    let status: AVAudioEngineManualRenderingStatus
                    do {
                        status = try self.rack.renderForExport(want, into: renderBuffer)
                    } catch {
                        self.fail(error); finishAudio(); return
                    }
                    if status == .cannotDoInCurrentContext { continue }
                    guard status == .success else {
                        self.fail(ExportError.message("The plugins couldn't render audio (status \(status.rawValue)).")); finishAudio(); return
                    }

                    let got = AVAudioFramePosition(renderBuffer.frameLength)
                    if got == 0 { finishAudio(); return }
                    // Skip the plugins' processing delay so audio lines up with the picture.
                    let skip = max(0, min(got, latencyFrames - state.renderedRaw))
                    state.renderedRaw += got
                    let usable = min(got - skip, totalFrames - state.written)
                    guard usable > 0 else { continue }
                    if self.source.outputGain != 1, let channels = renderBuffer.floatChannelData {
                        let g = self.source.outputGain
                        for c in 0..<Int(renderBuffer.format.channelCount) {
                            let p = channels[c]
                            for i in Int(skip)..<Int(skip + usable) { p[i] *= g }
                        }
                    }
                    loudness.process(renderBuffer, from: Int(skip), count: Int(usable))

                    guard let sample = Self.makeSampleBuffer(from: renderBuffer, start: Int(skip), count: Int(usable),
                                                             at: state.written, offset: .zero,
                                                             format: interleaved, desc: formatDesc) else {
                        self.fail(ExportError.message("Couldn't package the processed audio.")); finishAudio(); return
                    }
                    if !audioIn.append(sample) {
                        self.fail(Self.describe(writer.error, stage: "encoding the audio")); finishAudio(); return
                    }
                    state.written += usable

                    if state.written - state.lastReported > AVAudioFramePosition(format.sampleRate / 2) || state.written >= totalFrames {
                        state.lastReported = state.written
                        state.audioProgress = Double(state.written) / Double(max(totalFrames, 1))
                        report()
                    }
                }
            }

            group.notify(queue: .global(qos: .userInitiated)) {
                if self.isCancelled || self.failure != nil {
                    writer.cancelWriting()
                    audioReader.cancelReading()
                    video?.reader.cancelReading()
                    done(self.failure ?? ExportError.cancelled)
                } else {
                    self.finalLoudness = loudness.reading()
                    writer.endSession(atSourceTime: outputDuration)
                    writer.finishWriting {
                        done(writer.status == .completed ? nil
                             : Self.describe(writer.error, stage: "finishing the file"))
                    }
                }
            }
        } catch {
            done(error)
        }
    }

    /// Turns AVFoundation's terse errors into something that says which part failed and why.
    private static func describe(_ error: Error?, stage: String) -> Error {
        guard let ns = error as NSError? else { return ExportError.message("Failed while \(stage).") }
        var text = "Failed while \(stage): \(ns.localizedDescription)"
        if let reason = ns.localizedFailureReason { text += " — \(reason)" }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " (\(underlying.domain) \(underlying.code))"
        } else {
            text += " (\(ns.domain) \(ns.code))"
        }
        NSLog("1Shot: export error: \(ns)")
        return ExportError.message(text)
    }

    private static let rec709: [String: Any] = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
    ]

    /// A solid black video frame (video-range 4:2:0: Y = 16, Cb = Cr = 128).
    private static func blackFrame(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                  attrs as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        for (plane, value) in [(0, UInt8(16)), (1, UInt8(128))] {
            if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) {
                memset(base, Int32(value), CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private static func even(_ value: CGFloat) -> Int {
        max(2, Int(value.rounded()) / 2 * 2)
    }

    /// YouTube's recommended SDR upload bitrates, by resolution (short side) and frame rate.
    static func youTubeBitrate(width: Int, height: Int, fps: Double) -> Int {
        let shortSide = min(width, height)
        let highFrameRate = fps > 31
        let mbps: Double
        switch shortSide {
        case ..<540:  mbps = highFrameRate ? 4 : 2.5      // 480p
        case ..<800:  mbps = highFrameRate ? 7.5 : 5      // 720p
        case ..<1200: mbps = highFrameRate ? 12 : 8       // 1080p
        case ..<1800: mbps = highFrameRate ? 24 : 16      // 1440p
        default:      mbps = highFrameRate ? 68 : 45      // 4K
        }
        return Int(mbps * 1_000_000)
    }

    /// Engine output (split channels) → interleaved CMSampleBuffer for the writer.
    private static func makeSampleBuffer(from src: AVAudioPCMBuffer, start: Int, count: Int,
                                         at position: AVAudioFramePosition, offset: CMTime,
                                         format: AVAudioFormat,
                                         desc: CMAudioFormatDescription) -> CMSampleBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let dst = out.floatChannelData?[0],
              let channelsIn = src.floatChannelData else { return nil }
        out.frameLength = AVAudioFrameCount(count)
        let channels = Int(format.channelCount)
        let srcChannels = Int(src.format.channelCount)
        for f in 0..<count {
            for c in 0..<channels {
                dst[f * channels + c] = channelsIn[min(c, srcChannels - 1)][start + f]
            }
        }

        let rate = CMTimeScale(format.sampleRate)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: rate),
                                        presentationTimeStamp: CMTimeAdd(offset, CMTime(value: position, timescale: rate)),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                                   makeDataReadyCallback: nil, refcon: nil, formatDescription: desc,
                                   sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                   sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                   sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault,
                                                             blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                             flags: 0, bufferList: out.audioBufferList) == noErr
        else { return nil }
        return sample
    }
}

/// Mutable bookkeeping shared by the writer callbacks (each field is only touched on one queue).
private final class PumpState {
    var scheduled: AVAudioFramePosition = 0
    var renderedRaw: AVAudioFramePosition = 0
    var written: AVAudioFramePosition = 0
    var lastReported: AVAudioFramePosition = 0
    var sourceEnded = false
    var audioFinished = false
    var videoFinished = false
    var videoAppended = false
    var contentDone = false          // real frames all written; now the black tail
    var blackTime: CMTime = .zero
    var videoFrames = 0
    var audioProgress: Double = 0
    var videoProgress: Double = 0
}

// MARK: - Progress sheet

final class ExportProgressSheet: NSObject {
    let window: NSWindow
    var onCancel: (() -> Void)?
    private let bar = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")

    init(fileName: String) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 130),
                          styleMask: [.titled], backing: .buffered, defer: false)
        super.init()

        label.stringValue = "Exporting “\(fileName)”…"
        label.lineBreakMode = .byTruncatingMiddle
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"   // Esc

        let stack = NSStackView(views: [label, bar, cancel])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        label.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalToConstant: 380),
            bar.widthAnchor.constraint(equalToConstant: 380)
        ])
        window.contentView = stack
    }

    func setProgress(_ value: Double) { bar.doubleValue = value }
    func setMessage(_ text: String) { label.stringValue = text }

    @objc private func cancelClicked() {
        onCancel?()
    }
}

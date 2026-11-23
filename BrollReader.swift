// BrollReader — 3.5.2: plays a B-roll video front to back for the color pipeline.
//
// Before this, every B-roll frame came from AVAssetImageGenerator.copyCGImage: a separate
// "find the picture at this exact time" request per frame, decoded from the nearest keyframe,
// blocking that frame of the edit, and copied out through a CPU-side CGImage. Stock clips
// (long-GOP H.264) made that slow enough to stutter playback whenever B-roll was on screen.
//
// This keeps one AVAssetReader per clip and reads it in order, the way a player does, so each
// new frame costs one decode and stays in a GPU-friendly pixel buffer. It only takes over when
// requests move forward a frame or so at a time (playing, exporting). Anything else — the first
// frame after a pause, scrubbing, jumping, playing backwards — returns nil and the caller falls
// back to the image generator for that frame, exactly as before.

import AVFoundation
import CoreImage

final class BrollReader {
    let url: URL
    private let lock = NSLock()
    private let asset: AVURLAsset
    private var track: AVAssetTrack?
    private var orient: CGAffineTransform = .identity   // preferredTransform, in Core Image terms
    private var loaded = false

    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    /// Frames already decoded, oldest first: the ones handed out lately plus at most one ahead.
    private var frames: [(time: Double, buffer: CVPixelBuffer)] = []
    private var ahead: (time: Double, buffer: CVPixelBuffer)?
    private var lastAsked: Double = -.infinity

    /// How far forward a request can be from the last one and still count as "playing on".
    private static let maxStep = 0.25
    /// How many decoded frames to keep for requests that arrive a little out of order.
    private static let keep = 6

    /// Largest frame worth decoding to (the old generator's maximumSize). A clip much bigger
    /// than this is shrunk by the decoder, like the generator did, so the picture matches it.
    let maxSize: CGSize

    init(url: URL, maxSize: CGSize) {
        self.url = url
        self.maxSize = maxSize
        asset = AVURLAsset(url: url)
    }

    /// The frame showing at `seconds` of this clip, or nil when the caller should use its
    /// one-off image generator instead (not playing forward, or the file can't be read).
    func frame(at seconds: Double) -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        let previous = lastAsked
        lastAsked = seconds
        guard prepare() else { return nil }

        // A little behind (requests can arrive slightly out of order): use a frame we kept.
        if let newest = frames.last, seconds < newest.time - 0.0005 {
            return frames.last(where: { $0.time <= seconds + 0.0005 }).map { image($0.buffer) }
        }
        let stepping = seconds - previous
        let flowing = reader != nil && reader?.status == .reading && !frames.isEmpty
            && seconds - (frames.last?.time ?? seconds) <= Self.maxStep
        if !flowing {
            // Only start reading once requests are clearly moving forward in small steps;
            // a lone request (scrub, pause) is cheaper through the image generator.
            guard stepping > 0, stepping <= Self.maxStep else { return nil }
            guard start(at: seconds) else { return nil }
        }
        return advance(to: seconds).map(image)
    }

    // MARK: Reading

    private func prepare() -> Bool {
        if loaded { return track != nil }
        loaded = true
        guard let t = asset.tracks(withMediaType: .video).first else { return false }
        track = t
        // AVFoundation's transform is y-down; Core Image is y-up. Flip, apply, flip back.
        let p = t.preferredTransform
        if !p.isIdentity {
            let flip = CGAffineTransform(scaleX: 1, y: -1)
            orient = flip.concatenating(p).concatenating(flip)
        }
        return true
    }

    private func start(at seconds: Double) -> Bool {
        reader?.cancelReading()
        reader = nil; output = nil; frames = []; ahead = nil
        guard let track, let r = try? AVAssetReader(asset: asset) else { return false }
        var settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let size = track.naturalSize
        let k = min(1, maxSize.width / max(1, size.width), maxSize.height / max(1, size.height))
        if k < 0.999 {
            settings[kCVPixelBufferWidthKey as String] = Int((size.width * k).rounded(.down)) & ~1
            settings[kCVPixelBufferHeightKey as String] = Int((size.height * k).rounded(.down)) & ~1
        }
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        o.alwaysCopiesSampleData = false
        guard r.canAdd(o) else { return false }
        r.add(o)
        // Start a frame early so the frame covering `seconds` is the first one we get.
        let from = max(0, seconds - 0.05)
        r.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 60_000), duration: .positiveInfinity)
        guard r.startReading() else { return false }
        reader = r; output = o
        return true
    }

    /// Reads on until the next frame would come after `seconds`; returns the frame showing then.
    private func advance(to seconds: Double) -> CVPixelBuffer? {
        while true {
            if ahead == nil { ahead = readOne() }
            guard let next = ahead else { break }               // end of file: hold the last frame
            if next.time <= seconds + 0.0005 || frames.isEmpty {
                frames.append(next); ahead = nil
                if frames.count > Self.keep { frames.removeFirst(frames.count - Self.keep) }
                if next.time > seconds + 0.0005 { break }         // first frame is already past: show it
            } else {
                break
            }
        }
        return frames.last(where: { $0.time <= seconds + 0.0005 })?.buffer ?? frames.first?.buffer
    }

    private func readOne() -> (time: Double, buffer: CVPixelBuffer)? {
        guard let output, reader?.status == .reading else { return nil }
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard t.isFinite else { continue }
            return (t, buffer)
        }
        return nil
    }

    private func image(_ buffer: CVPixelBuffer) -> CIImage {
        var img = CIImage(cvPixelBuffer: buffer)
        if !orient.isIdentity {
            img = img.transformed(by: orient)
            img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        }
        return img
    }
}

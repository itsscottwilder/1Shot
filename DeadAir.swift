// DeadAir — finds the silence before the first sound and after the last sound of one source clip
// (3.4.0), so Claude can propose each clip's in/out (MCP find_dead_air) before the A-roll is built.
// Audio only: reads the clip's first audio track at 16 kHz mono and looks at 50 ms loudness blocks.

import AVFoundation

enum DeadAir {
    struct Result {
        let duration: Double
        let firstSound: Double?     // nil = no sound found anywhere
        let lastSound: Double?      // end of the last sound
        let noiseFloorDb: Double
        let speechDb: Double
        let thresholdDb: Double
    }

    static let block = 0.05          // seconds per loudness block
    static let minRun = 4            // a sound must last 4 blocks (200 ms) in a row: clicks and taps don't count

    /// Reads the audio and finds where sound starts and stops. Runs off the main thread.
    static func analyze(url: URL) async throws -> Result {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw MCPError("\(url.lastPathComponent) has no audio track.")
        }
        let rate = 16_000.0
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1
        ])
        guard reader.canAdd(output) else { throw MCPError("Couldn't read the audio of \(url.lastPathComponent).") }
        reader.add(output)
        guard reader.startReading() else {
            throw MCPError(reader.error?.localizedDescription ?? "Couldn't read the audio of \(url.lastPathComponent).")
        }

        let step = Int(rate * block)
        var levels: [Double] = []          // dB per block
        var sum = 0.0, count = 0
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let data = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let n = CMBlockBufferGetDataLength(data) / MemoryLayout<Float>.size
            guard n > 0 else { continue }
            if samples.count < n { samples = [Float](repeating: 0, count: n) }
            let status = samples.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: n * MemoryLayout<Float>.size, destination: $0.baseAddress!)
            }
            guard status == noErr else { continue }
            for i in 0..<n {
                let x = Double(samples[i])
                sum += x * x
                count += 1
                if count == step {
                    let ms = sum / Double(step)
                    levels.append(ms > 0 ? 10 * log10(ms) : -120)
                    sum = 0; count = 0
                }
            }
        }
        if reader.status == .failed {
            throw MCPError(reader.error?.localizedDescription ?? "Couldn't read the audio of \(url.lastPathComponent).")
        }
        return find(in: levels, duration: duration > 0 ? duration : Double(levels.count) * block)
    }

    /// The loud part between the room tone at either end. The threshold sits a third of the way
    /// from the room tone (10th percentile) up to the voice (90th percentile), and at least 10 dB
    /// above the room tone.
    static func find(in levels: [Double], duration: Double) -> Result {
        guard levels.count >= minRun else {
            return Result(duration: duration, firstSound: nil, lastSound: nil, noiseFloorDb: -120, speechDb: -120, thresholdDb: -120)
        }
        let sorted = levels.sorted()
        let floor = sorted[Int(Double(sorted.count - 1) * 0.10)]
        let speech = sorted[Int(Double(sorted.count - 1) * 0.90)]
        let threshold = max(floor + 10, floor + (speech - floor) / 3)
        let loud = levels.map { $0 >= threshold }

        var first: Int?
        var run = 0
        for i in loud.indices {
            run = loud[i] ? run + 1 : 0
            if run == minRun { first = i - minRun + 1; break }
        }
        var last: Int?
        run = 0
        for i in loud.indices.reversed() {
            run = loud[i] ? run + 1 : 0
            if run == minRun { last = i + minRun; break }   // block index just past the sound
        }
        let speechFound = speech - floor >= 10
        return Result(duration: duration,
                      firstSound: speechFound ? first.map { Double($0) * block } : nil,
                      lastSound: speechFound ? last.map { min(duration, Double($0) * block) } : nil,
                      noiseFloorDb: floor, speechDb: speech, thresholdDb: threshold)
    }
}

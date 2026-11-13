// CubeLUT — loads standard .cube 3D LUT files (Resolve / Final Cut / LUT packs)
// and keeps a small library of them in Application Support.

import Foundation
import CoreImage

final class CubeLUT {
    enum LUTError: LocalizedError {
        case unreadable, unsupported1D, badSize, wrongCount(Int, Int)
        var errorDescription: String? {
            switch self {
            case .unreadable: return "The file couldn't be read as a .cube LUT."
            case .unsupported1D: return "This is a 1D LUT. Only 3D .cube LUTs are supported."
            case .badSize: return "The LUT doesn't say its size (LUT_3D_SIZE) or the size is unusual."
            case .wrongCount(let found, let expected):
                return "The LUT has \(found) color entries but should have \(expected)."
            }
        }
    }

    let name: String
    let dimension: Int
    let data: Data            // RGBA float, red changing fastest — what Core Image's color cube wants

    init(url: URL) throws {
        guard let text = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else { throw LUTError.unreadable }
        var size = 0
        var domainMin: [Float] = [0, 0, 0]
        var domainMax: [Float] = [1, 1, 1]
        var values: [Float] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = parts.first else { continue }
            switch first.uppercased() {
            case "TITLE":
                continue
            case "LUT_1D_SIZE":
                throw LUTError.unsupported1D
            case "LUT_3D_SIZE":
                size = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
                if size >= 2 && size <= 256 { values.reserveCapacity(size * size * size * 4) }
            case "DOMAIN_MIN":
                domainMin = parts.dropFirst().compactMap { Float($0) }
            case "DOMAIN_MAX":
                domainMax = parts.dropFirst().compactMap { Float($0) }
            default:
                let nums = parts.prefix(3).compactMap { Float($0) }
                if nums.count == 3 { values += [nums[0], nums[1], nums[2], 1] }
            }
        }
        guard size >= 2, size <= 256 else { throw LUTError.badSize }
        let expected = size * size * size
        guard values.count == expected * 4 else { throw LUTError.wrongCount(values.count / 4, expected) }

        // Rare: output values given in a range other than 0…1 — rescale them.
        if domainMin.count == 3, domainMax.count == 3, domainMin != [0, 0, 0] || domainMax != [1, 1, 1] {
            for i in stride(from: 0, to: values.count, by: 4) {
                for c in 0..<3 {
                    let span = max(domainMax[c] - domainMin[c], 0.0001)
                    values[i + c] = (values[i + c] - domainMin[c]) / span
                }
            }
        }

        name = url.deletingPathExtension().lastPathComponent
        dimension = size
        data = values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func apply(to image: CIImage) -> CIImage {
        guard let f = CIFilter(name: "CIColorCubeWithColorSpace") else { return image }
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(dimension, forKey: "inputCubeDimension")
        f.setValue(data, forKey: "inputCubeData")
        // Look LUTs expect normal Rec. 709 video values going in.
        f.setValue(CGColorSpace(name: CGColorSpace.itur_709), forKey: "inputColorSpace")
        return f.outputImage ?? image
    }

    // MARK: Library

    /// ~/Library/Application Support/1Shot/LUTs
    static var libraryFolder: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("1Shot/LUTs", isDirectory: true)
        // Bring over LUTs saved under the app's earlier names.
        for oldName in ["1Shot Pipeline/LUTs", "One Shot Prep/LUTs", "Timecode Player/LUTs"] {
            let old = base.appendingPathComponent(oldName, isDirectory: true)
            if !fm.fileExists(atPath: folder.path), fm.fileExists(atPath: old.path) {
                try? fm.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.moveItem(at: old, to: folder)
            }
        }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func libraryFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: libraryFolder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "cube" }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Copies a .cube into the library (replacing one with the same name) and returns the copy.
    static func importToLibrary(_ url: URL) throws -> URL {
        _ = try CubeLUT(url: url)    // make sure it's valid before keeping it
        let destination = libraryFolder.appendingPathComponent(url.lastPathComponent)
        if url.standardizedFileURL != destination.standardizedFileURL {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: url, to: destination)
        }
        return destination
    }
}

import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Frame-level access to an animated GIF for the in-app frame editor
/// (Preview can only view frames, not delete them — verified during design
/// research, hence this exists).
struct GIFDocument {
    struct Frame: Identifiable {
        let id: Int
        let thumbnail: CGImage
        let delay: Double
    }

    let url: URL
    let frames: [Frame]

    static func load(url: URL) throws -> GIFDocument {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ScrecError.gifFailed("could not read \(url.lastPathComponent)")
        }
        let count = CGImageSourceGetCount(source)
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways as String: true,
            kCGImageSourceThumbnailMaxPixelSize as String: 220,
        ] as CFDictionary
        var frames: [Frame] = []
        for index in 0..<count {
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, index,
                                                                      thumbnailOptions)
            else { continue }
            frames.append(Frame(id: index,
                                thumbnail: thumbnail,
                                delay: delay(of: source, at: index)))
        }
        guard !frames.isEmpty else {
            throw ScrecError.gifFailed("no frames in \(url.lastPathComponent)")
        }
        return GIFDocument(url: url, frames: frames)
    }

    /// Rewrites the GIF keeping only `keptIndices` (original delays and loop
    /// behavior preserved). Atomic: writes a temp file, then replaces.
    static func save(url: URL, keptIndices: [Int]) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ScrecError.gifFailed("could not read \(url.lastPathComponent)")
        }
        let kept = keptIndices.sorted().filter { $0 < CGImageSourceGetCount(source) }
        guard !kept.isEmpty else {
            throw ScrecError.gifFailed("cannot remove every frame")
        }

        let loopCount = (CGImageSourceCopyProperties(source, nil) as? [String: Any])
            .flatMap { $0[kCGImagePropertyGIFDictionary as String] as? [String: Any] }
            .flatMap { $0[kCGImagePropertyGIFLoopCount as String] as? Int } ?? 0

        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp")
        try? FileManager.default.removeItem(at: tempURL)
        guard let destination = CGImageDestinationCreateWithURL(
                tempURL as CFURL, UTType.gif.identifier as CFString, kept.count, nil)
        else { throw ScrecError.gifFailed("could not create output") }

        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: loopCount,
            ],
        ] as CFDictionary)

        for index in kept {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let delay = delay(of: source, at: index)
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary as String: [
                    kCGImagePropertyGIFDelayTime as String: delay,
                    kCGImagePropertyGIFUnclampedDelayTime as String: delay,
                ],
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw ScrecError.gifFailed("could not write output")
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
    }

    private static func delay(of source: CGImageSource, at index: Int) -> Double {
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            as? [String: Any])?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
        let unclamped = properties?[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double
        let clamped = properties?[kCGImagePropertyGIFDelayTime as String] as? Double
        let delay = unclamped ?? clamped ?? (1.0 / 12.0)
        return delay > 0 ? delay : (1.0 / 12.0)
    }
}

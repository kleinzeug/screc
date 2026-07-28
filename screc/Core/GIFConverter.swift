import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

/// MP4 → animated GIF, fully native (ImageIO). Frames are decoded already
/// downscaled (decompression-session scaling via pixel-buffer size hints),
/// sampled at the target GIF frame rate along the source timeline, and each
/// frame carries its real display duration (PTS gap to the next kept frame),
/// so wall-clock timing survives the recorder's sparse damage-driven
/// delivery. Sits behind this enum so a
/// gifski-based encoder can drop in later (better palettes, AGPL/commercial
/// licensing decision — see DESIGN.md §5.3).
///
/// Deliberately uses AVAssetReader, not AVAssetImageGenerator (slow since the
/// iOS 17-era OSes and throws random decode errors; the Gifski project itself
/// migrated away from it).
enum GIFConverter {
    static func convert(movie: URL, to output: URL, maxWidth: Int, fps: Int,
                        loopForever: Bool = true, dither: Double = 0) async throws {
        let asset = AVURLAsset(url: movie)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ScrecError.gifFailed("no video track")
        }
        let naturalSize = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration).seconds

        let scale = min(1, CGFloat(maxWidth) / max(naturalSize.width, 1))
        let width = max(2, Int((naturalSize.width * scale).rounded()) & ~1)
        let height = max(2, Int((naturalSize.height * scale).rounded()) & ~1)

        let reader = try AVAssetReader(asset: asset)
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        trackOutput.alwaysCopiesSampleData = false
        reader.add(trackOutput)
        guard reader.startReading() else {
            throw ScrecError.gifFailed(reader.error?.localizedDescription ?? "could not read movie")
        }

        let estimatedFrames = max(1, Int(duration * Double(fps)) + 2)
        guard let destination = CGImageDestinationCreateWithURL(
                output as CFURL, UTType.gif.identifier as CFString, estimatedFrames, nil)
        else { throw ScrecError.gifFailed("could not create \(output.lastPathComponent)") }

        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: loopForever ? 0 : 1,
            ],
        ] as CFDictionary)

        // Optional CIDither pre-pass: trades noise for less banding on
        // gradients under GIF's 256-color quantization.
        let ciContext = dither > 0.01 ? CIContext(options: [.cacheIntermediates: false]) : nil

        // Sample along the SOURCE TIMELINE at the target rate, and give each
        // kept frame its real duration — the PTS gap to the next kept frame.
        // The recorder is damage-driven: idle stretches arrive as sparse
        // frames (~1/s heartbeat), so a fixed per-frame delay would
        // time-compress them (10 s of idle ≈ 10 frames ≈ 0.8 s of GIF).
        let step = 1.0 / Double(fps)
        var nextKeepTime = 0.0
        var framesAdded = 0
        var pending: (image: CGImage, pts: Double)?
        // GIF stores delays in centiseconds; carry the rounding remainder so
        // quantization doesn't accumulate into drift on long clips.
        var carry = 0.0

        func flush(_ entry: (image: CGImage, pts: Double), until nextPTS: Double) {
            let target = max(nextPTS - entry.pts, 0) + carry
            let centiseconds = max(2, Int((target * 100).rounded()))
            let delay = Double(centiseconds) / 100
            carry = target - delay
            CGImageDestinationAddImage(destination, entry.image, [
                kCGImagePropertyGIFDictionary as String: [
                    kCGImagePropertyGIFDelayTime as String: delay,
                    kCGImagePropertyGIFUnclampedDelayTime as String: delay,
                ],
            ] as CFDictionary)
            framesAdded += 1
        }

        while let sample = trackOutput.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts >= nextKeepTime,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sample)
            else { continue }
            var cgImage: CGImage?
            if let ciContext {
                var image = CIImage(cvPixelBuffer: pixelBuffer)
                if let filter = CIFilter(name: "CIDither") {
                    filter.setValue(image, forKey: kCIInputImageKey)
                    filter.setValue(dither, forKey: "inputIntensity")
                    image = filter.outputImage ?? image
                }
                cgImage = ciContext.createCGImage(image, from: image.extent)
            } else {
                VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
            }
            guard let cgImage else { continue }
            if let entry = pending {
                flush(entry, until: pts)
            }
            pending = (cgImage, pts)
            // Snap the grid to the timeline (never += per kept frame): a
            // sparse source must not pull the grid along with it.
            nextKeepTime = (floor(pts / step) + 1) * step
        }
        if let entry = pending {
            // The last frame has no successor: give it the remaining movie
            // time so total GIF duration matches the recording.
            flush(entry, until: max(entry.pts + step, duration))
        }
        if reader.status == .failed {
            try? FileManager.default.removeItem(at: output)
            throw ScrecError.gifFailed(reader.error?.localizedDescription ?? "decode failed")
        }
        guard framesAdded > 0, CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: output)
            throw ScrecError.gifFailed("no frames written")
        }
    }
}

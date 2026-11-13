import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Builds a camera-roll-like folder from real photos, for calibrating thresholds on real
/// image content rather than drawn shapes.
///
/// Each source becomes one series. A single image is turned into handheld frames (small
/// reframing and tilt, exposure drift); several images (consecutive video frames, say) are
/// used as the frames as they are. Every frame but one gets motion or focus blur, so the
/// sharp one is the right keeper. Series follow each other seconds apart, so time alone
/// can't separate them, and sources marked as singles sit in between as one-off photos.
public enum BurstLibrary {
    public struct Source: Sendable {
        public var name: String
        public var frames: [URL]

        public init(name: String, frames: [URL]) {
            self.name = name
            self.frames = frames
        }
    }

    public static func write(
        series sources: [Source],
        singles: [URL],
        to folder: URL,
        framesPerSeries: ClosedRange<Int> = 2...5,
        gapBetweenMoments: ClosedRange<Double> = 6...40,
        start: Date = Date(timeIntervalSince1970: 1_767_225_600),
        seed: UInt64 = 7,
        maxSide: Int = 1024
    ) throws -> SyntheticLibrary.Truth {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var rng = SplitMix64(seed: seed)
        let context = CIContext()
        var manifest: [String: FolderPhotoManifestEntry] = [:]
        var truth = SyntheticLibrary.Truth(series: [], singles: [])
        var clock = start
        var pendingSingles = singles[...]

        for (s, source) in sources.enumerated() {
            let images = try source.frames.map(load)
            let n = images.count > 1 ? images.count : Int.random(in: framesPerSeries, using: &rng)
            let bestIndex = Int.random(in: 0..<n, using: &rng)
            var files: [String] = []
            for f in 0..<n {
                var image = images.count > 1 ? images[f] : handheld(images[0], rng: &rng)
                if f != bestIndex { image = shaken(image, rng: &rng) }
                let name = String(format: "s%02d_%@_%d.jpg", s, source.name, f)
                try writeJPEG(image, maxSide: maxSide, context: context, to: folder.appendingPathComponent(name))
                manifest[name] = FolderPhotoManifestEntry(date: clock)
                clock.addTimeInterval(Double(Int.random(in: 1...3, using: &rng)))
                files.append(name)
            }
            truth.series.append(.init(files: files, best: files[bestIndex]))
            clock.addTimeInterval(Double.random(in: gapBetweenMoments, using: &rng).rounded())

            if let single = pendingSingles.popFirst() {
                let name = String(format: "single%02d_%@.jpg", truth.singles.count, single.deletingPathExtension().lastPathComponent)
                try writeJPEG(handheld(try load(single), rng: &rng), maxSide: maxSide, context: context, to: folder.appendingPathComponent(name))
                manifest[name] = FolderPhotoManifestEntry(date: clock)
                clock.addTimeInterval(Double.random(in: gapBetweenMoments, using: &rng).rounded())
                truth.singles.append(name)
            }
        }

        try writeManifest(manifest, to: folder)
        return truth
    }

    // MARK: - Frames

    static func load(_ url: URL) throws -> CIImage {
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return image
    }

    /// Another frame of the same moment from a hand-held phone: slightly reframed and tilted,
    /// slightly brighter or darker.
    static func handheld(_ image: CIImage, rng: inout SplitMix64) -> CIImage {
        let extent = image.extent
        let scale = Double.random(in: 0.90...0.96, using: &rng)
        let w = extent.width * scale, h = extent.height * scale
        let x = extent.minX + Double.random(in: 0...(extent.width - w), using: &rng)
        let y = extent.minY + Double.random(in: 0...(extent.height - h), using: &rng)
        let angle = Double.random(in: -1.5...1.5, using: &rng) * .pi / 180
        let center = CGPoint(x: extent.midX, y: extent.midY)
        let rotation = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angle).translatedBy(x: -center.x, y: -center.y)
        return image.clampedToExtent()
            .transformed(by: rotation)
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: Double.random(in: -0.3...0.3, using: &rng)])
            .cropped(to: CGRect(x: x, y: y, width: w, height: h))
            .transformed(by: CGAffineTransform(translationX: -x, y: -y))
    }

    /// The camera moved or focus missed: motion blur in a random direction, or a soft focus.
    static func shaken(_ image: CIImage, rng: inout SplitMix64) -> CIImage {
        let extent = image.extent
        // Blur sizes are for a 1024-pixel image; scale them to the source.
        let unit = max(extent.width, extent.height) / 1024
        let blurred: CIImage
        if Double.random(in: 0...1, using: &rng) < 0.6 {
            blurred = image.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [
                kCIInputRadiusKey: Double.random(in: 4...12, using: &rng) * unit,
                kCIInputAngleKey: Double.random(in: 0...Double.pi, using: &rng),
            ])
        } else {
            blurred = image.clampedToExtent().applyingGaussianBlur(sigma: Double.random(in: 1.5...3.5, using: &rng) * unit)
        }
        return blurred.cropped(to: extent)
    }

    static func writeJPEG(_ image: CIImage, maxSide: Int, context: CIContext, to url: URL) throws {
        let longest = max(image.extent.width, image.extent.height)
        let fitted = longest > CGFloat(maxSide)
            ? image.transformed(by: CGAffineTransform(scaleX: CGFloat(maxSide) / longest, y: CGFloat(maxSide) / longest))
            : image
        let extent = fitted.extent.integral
        guard let cg = context.createCGImage(fitted, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try SyntheticScene.writeJPEG(cg, to: url)
    }
}

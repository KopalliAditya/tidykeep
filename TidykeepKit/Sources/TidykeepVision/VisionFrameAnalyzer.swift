import CoreGraphics
import CoreImage
import Foundation
import TidykeepCore
import Vision

/// On-device analysis with Apple's Vision framework. Nothing leaves the device.
///
/// Request revisions are pinned. A new SDK can change a default revision silently, and
/// feature prints from different revisions can't be compared, so the revisions are part
/// of `version` and a change invalidates the cache.
public struct VisionFrameAnalyzer: FrameAnalyzing {
    /// Gaussian blur applied before the feature print, as a fraction of the image's long side.
    ///
    /// Blur moves a feature print a lot: in bursts made from real photos with simulated shake
    /// and blur (`tkscan bursts`), a sharp frame and a blurred frame of the same moment were as
    /// far apart as two different scenes. Softening both first makes the print about what's in
    /// the picture, not how crisp it is. 0.008 was picked with `tkscan calibrate` and
    /// `tkscan sweep` on those synthetic bursts (see README); bench/RESULTS.md checks it on
    /// held-out real camera shake, where it helps, and on photos without blur, where it costs recall.
    public var softening: Double

    public init(softening: Double = 0.008) {
        self.softening = softening
    }

    public var version: String { "fp2.aes1.fq3.sharp1" + (softening > 0 ? String(format: ".soft%.4f", softening) : "") }

    /// Throws rather than return partial results: what's returned is cached for good, and a
    /// failed request (say, no GPU while the app is in the background) would leave a photo
    /// grouped or ranked wrongly forever. A photo that throws is skipped and retried next scan.
    public func analyze(_ image: CGImage) async throws -> FrameSignals {
        let print = try await GenerateImageFeaturePrintRequest(.revision2).perform(on: softening > 0 ? try Self.softened(image, by: softening) : image)
        let aesthetics = try await CalculateImageAestheticsScoresRequest(.revision1).perform(on: image)
        let faces = try await DetectFaceCaptureQualityRequest(.revision3).perform(on: image)

        return FrameSignals(
            embedding: QuantizedEmbedding(try Self.vector(print)),
            aesthetics: aesthetics.overallScore,
            isUtility: aesthetics.isUtility,
            sharpness: Sharpness.focusMeasure(image),
            faceQualities: faces.compactMap { $0.captureQuality?.score }
        )
    }

    enum AnalysisError: Error { case emptyFeaturePrint, softeningFailed }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func softened(_ image: CGImage, by fraction: Double) throws -> CGImage {
        let input = CIImage(cgImage: image)
        let sigma = fraction * Double(max(image.width, image.height))
        let output = input.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: input.extent)
        guard let softened = context.createCGImage(output, from: input.extent) else { throw AnalysisError.softeningFailed }
        return softened
    }

    static func vector(_ print: FeaturePrintObservation) throws -> [Float] {
        let vector: [Float] = print.data.withUnsafeBytes { raw in
            switch print.elementType {
            case .float: Array(raw.bindMemory(to: Float.self).prefix(print.elementCount))
            case .double: raw.bindMemory(to: Double.self).prefix(print.elementCount).map(Float.init)
            @unknown default: []
            }
        }
        guard !vector.isEmpty else { throw AnalysisError.emptyFeaturePrint }
        return vector
    }
}

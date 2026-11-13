import CoreGraphics
import CoreText
import Foundation
import TidykeepCore
import TidykeepTestSupport
@testable import TidykeepVision
import Testing
import Vision

@Suite struct VisionAnalyzerTests {
    let scene = SyntheticScene(seed: 11)

    @Test func featurePrintIsAUnitVectorOfTheExpectedSize() async throws {
        let signals = try await VisionFrameAnalyzer().analyze(scene.render())
        let values = signals.embedding.dequantized()
        #expect(values.count == 768)
        let norm = values.reduce(0) { $0 + $1 * $1 }.squareRoot()
        #expect(abs(norm - 1) < 0.02)
    }

    /// Our compact copy of the feature print must measure distance the way Vision does.
    /// Vision reports the squared distance; the thresholds use the plain one.
    @Test func quantizedDistanceMatchesVision() async throws {
        let request = GenerateImageFeaturePrintRequest(.revision2)
        let images = [scene.render(), scene.render(shift: CGPoint(x: 30, y: 10), blur: 2), SyntheticScene(seed: 99).render()]
        let prints = try await images.asyncMap { try await request.perform(on: $0) }
        for i in 0..<prints.count {
            for j in (i + 1)..<prints.count {
                let vision = Float(try prints[i].distance(to: prints[j]))
                let ours = QuantizedEmbedding(try VisionFrameAnalyzer.vector(prints[i]))
                    .distance(to: QuantizedEmbedding(try VisionFrameAnalyzer.vector(prints[j])))
                #expect(abs(vision - ours * ours) < 0.01, "pair \(i)-\(j): Vision \(vision), ours squared \(ours * ours)")
            }
        }
    }

    @Test func sharpnessFallsAsBlurRises() {
        let measures = [0.0, 1.0, 3.0, 6.0].map { Sharpness.focusMeasure(scene.render(blur: $0)) }
        #expect(zip(measures, measures.dropFirst()).allSatisfy { $0 > $1 }, "\(measures)")
    }

    /// The reason for softening: a blurred frame of the same moment should land near the
    /// sharp one, so blur changes the pick but not the grouping.
    @Test func softeningPullsBlurredFramesOfTheSameMomentTogether() async throws {
        let sharp = scene.render(), blurred = scene.render(blur: 3)
        func distance(_ analyzer: VisionFrameAnalyzer) async throws -> Float {
            let a = try await analyzer.analyze(sharp), b = try await analyzer.analyze(blurred)
            return a.embedding.distance(to: b.embedding)
        }
        let raw = try await distance(VisionFrameAnalyzer(softening: 0))
        let softened = try await distance(VisionFrameAnalyzer())
        #expect(softened < raw, "raw \(raw), softened \(softened)")
    }

    @Test func softeningStillSeparatesDifferentScenes() async throws {
        let analyzer = VisionFrameAnalyzer()
        let a = try await analyzer.analyze(scene.render())
        let b = try await analyzer.analyze(scene.render(shift: CGPoint(x: 12, y: -8), blur: 2))
        let other = try await analyzer.analyze(SyntheticScene(seed: 5_000).render())
        #expect(a.embedding.distance(to: b.embedding) < a.embedding.distance(to: other.embedding))
    }

    @Test func versionChangesWithSettingsThatChangeResults() {
        #expect(VisionFrameAnalyzer().version == "fp2.aes1.fq3.sharp1.soft0.0080.dinos-pal8g.crop256aa")
        #expect(VisionFrameAnalyzer(content: nil).version == "fp2.aes1.fq3.sharp1.soft0.0080")
        #expect(VisionFrameAnalyzer(softening: 0, content: nil).version == "fp2.aes1.fq3.sharp1")
        #expect(VisionFrameAnalyzer(softening: 0.01).version != VisionFrameAnalyzer().version)
    }

    /// The content embeddings come from the same pass, from the unsoftened photo.
    @Test func theAnalyzerStoresBothContentEmbeddings() async throws {
        let image = scene.render()
        let signals = try await VisionFrameAnalyzer().analyze(image)
        let direct = try await #require(ContentEmbedder.bundled).embed(image)
        #expect(signals.dinoCLS == QuantizedEmbedding(direct.cls))
        #expect(signals.dinoMean == QuantizedEmbedding(direct.mean))
        #expect(signals.dinoCLS?.count == 384 && signals.dinoMean?.count == 384)

        let without = try await VisionFrameAnalyzer(content: nil).analyze(image)
        #expect(without.dinoCLS == nil && without.dinoMean == nil)
        #expect(without.embedding == signals.embedding)
    }

    @Test func softenedImageKeepsItsSize() throws {
        let image = scene.render(width: 640, height: 480)
        let softened = try VisionFrameAnalyzer.softened(image, by: 0.008)
        #expect(softened.width == 640 && softened.height == 480)
    }

    @Test func noFacesInAScene() async throws {
        #expect(try await VisionFrameAnalyzer().analyze(scene.render()).faceQualities.isEmpty)
    }

    /// Document pages are kept out of groups. This checks that Vision does flag a page of text.
    @Test func aPageOfTextIsAUtilityPhoto() async throws {
        let signals = try await VisionFrameAnalyzer().analyze(textPage())
        #expect(signals.isUtility)
    }

    func textPage() -> CGImage {
        let width = 1240, height = 1754
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 34, nil)
        let line = "Invoice 10432   Qty 2   Unit price 18.50   Subtotal 37.00   Tax 3.24   Total 40.24"
        for row in 0..<36 {
            let text = NSAttributedString(string: row == 0 ? "RECEIPT" : line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ])
            ctx.textPosition = CGPoint(x: 90, y: height - 140 - row * 44)
            CTLineDraw(CTLineCreateWithAttributedString(text), ctx)
        }
        return ctx.makeImage()!
    }
}

extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        for element in self { out.append(try await transform(element)) }
        return out
    }
}

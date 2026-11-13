import CoreGraphics
import CoreML
import Foundation
import TidykeepCore
import TidykeepTestSupport
@testable import TidykeepVision
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite struct ContentEmbedderTests {
    let embedder: ContentEmbedder
    let scene = SyntheticScene(seed: 11)

    init() throws { embedder = try #require(ContentEmbedder.bundled) }

    @Test func theBundledModelLoadsForEveryComputeUnit() async throws {
        #expect(try await embedder.computeUnits == .all)
        #expect(embedder.version == "dinos-pal8g.crop256aa")
    }

    /// `version` is known before the model loads, so the model must be what it claims.
    @Test func aModelThatIsNotTheClaimedVariantIsRefused() async throws {
        let url = try #require(ContentEmbedder.bundledModelURL)
        let wrong = ContentEmbedder(modelURL: url, variant: "fp16")
        await #expect(throws: ContentEmbedder.Failure.wrongModel(expected: "fp16", found: "pal8g")) {
            try await wrong.embed(scene.render())
        }
    }

    @Test func bothOutputsAreUnitVectorsOfTheExpectedSize() async throws {
        let output = try await embedder.embed(scene.render())
        for v in [output.cls, output.mean] {
            #expect(v.count == 384)
            #expect(abs(v.reduce(0) { $0 + $1 * $1 }.squareRoot() - 1) < 1e-5)
        }
        // Two different summaries of the picture, not one output twice.
        #expect(distance(output.cls, output.mean) > 0.1)
    }

    /// Embeddings are cached for good, so the same picture must give the same vectors.
    @Test func theSameImageGivesTheSameEmbedding() async throws {
        let image = scene.render()
        let a = try await embedder.embed(image), b = try await embedder.embed(image)
        #expect(distance(a.cls, b.cls) < 1e-4 && distance(a.mean, b.mean) < 1e-4)
    }

    /// The CPU fallback must give nearly what the Neural Engine or GPU gives, or photos
    /// analyzed in the background wouldn't match the rest.
    @Test func theCPUFallbackAgreesWithTheDefault() async throws {
        let cpu = try ContentEmbedder(modelURL: #require(ContentEmbedder.bundledModelURL), variant: "pal8g", computeUnits: .cpuOnly)
        #expect(try await cpu.computeUnits == .cpuOnly)
        #expect(cpu.version == embedder.version)
        let image = scene.render()
        let a = try await embedder.embed(image), b = try await cpu.embed(image)
        #expect(distance(a.cls, b.cls) < 0.1 && distance(a.mean, b.mean) < 0.1, "\(distance(a.cls, b.cls)) \(distance(a.mean, b.mean))")
    }

    /// The copy pass links CLS embeddings at most 0.59 apart. A re-encoded, resized copy must
    /// land well inside that, and a different scene further away than the copy.
    @Test func aCopyIsCloseAndAnotherSceneIsFar() async throws {
        let original = scene.render(width: 1024, height: 768)
        let copy = try reencoded(scaled(original, by: 0.5), quality: 0.6)
        let other = SyntheticScene(seed: 5_000).render(width: 1024, height: 768)
        let o = try await embedder.embed(original), c = try await embedder.embed(copy), x = try await embedder.embed(other)
        #expect(distance(o.cls, c.cls) < 0.3, "copy \(distance(o.cls, c.cls))")
        #expect(distance(o.cls, c.cls) < distance(o.cls, x.cls))
        #expect(distance(o.mean, c.mean) < distance(o.mean, x.mean))
    }

    /// The same on real pictures that ship with macOS, when they're there.
    @Test(.enabled(if: [ContentEmbedderTests.owl, ContentEmbedderTests.poppy].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }))
    func realPicturesCopiesCloseOthersFar() async throws {
        let owl = try #require(Self.load(Self.owl)), poppy = try #require(Self.load(Self.poppy))
        let copy = try reencoded(scaled(owl, by: 0.6), quality: 0.5)
        let o = try await embedder.embed(owl), c = try await embedder.embed(copy), p = try await embedder.embed(poppy)
        #expect(distance(o.cls, c.cls) < 0.3, "copy \(distance(o.cls, c.cls))")
        #expect(distance(o.cls, p.cls) > 0.59, "owl to poppy \(distance(o.cls, p.cls))")
    }

    @Test func anOutputThatIsNotAUnitVectorIsRejected() throws {
        let unit = [Float](repeating: 0, count: 383) + [1]
        #expect(try ContentEmbedder.normalized(unit, "x") == unit)
        #expect(throws: ContentEmbedder.Failure.badOutput("x")) { try ContentEmbedder.normalized([1, 0], "x") }
        #expect(throws: ContentEmbedder.Failure.badOutput("x")) { try ContentEmbedder.normalized(unit.map { $0 * 2 }, "x") }
        #expect(throws: ContentEmbedder.Failure.badOutput("x")) { try ContentEmbedder.normalized([Float.nan] + unit.dropFirst(), "x") }
    }

    // MARK: -

    static let owl = URL(fileURLWithPath: "/Library/User Pictures/Animals/Owl.heic")
    static let poppy = URL(fileURLWithPath: "/Library/User Pictures/Flowers/Poppy.heic")

    static func load(_ url: URL) -> CGImage? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    func distance(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }.squareRoot()
    }

    func scaled(_ image: CGImage, by factor: Double) -> CGImage {
        let width = Int(Double(image.width) * factor), height = Int(Double(image.height) * factor)
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    func reencoded(_ image: CGImage, quality: Double) throws -> CGImage {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let source = try #require(CGImageSourceCreateWithData(data, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
}

@Suite struct ContentFramingTests {
    /// Expected values from the transformers DINOv2 processor (resize short side 256, center
    /// crop 224) for the same sizes: scaled size, then left and top crop offsets.
    @Test(arguments: [
        (3024, 4032, 256, 341, 16, 58), // portrait
        (4032, 3024, 341, 256, 58, 16), // landscape
        (1000, 1000, 256, 256, 16, 16), // square
        (1170, 2532, 256, 554, 16, 165), // a phone screenshot
        (225, 1000, 256, 1137, 16, 456), // tall and small
        (798, 533, 383, 256, 79, 16), // odd excess: floored (torchvision's own crop would round to 80)
    ])
    func matchesTheProcessorsCrop(width: Int, height: Int, scaledW: Int, scaledH: Int, left: Int, top: Int) throws {
        let f = try #require(ContentFraming.frame(width: width, height: height))
        #expect(f.width == scaledW && f.height == scaledH)
        #expect(f.left == left && f.top == top)
    }

    @Test func anEmptyImageHasNoFrame() {
        #expect(ContentFraming.frame(width: 0, height: 10) == nil)
        #expect(ContentFraming.frame(width: 10, height: 0) == nil)
    }

    /// The buffer is the resampler's crop of the scaled photo, in BGRA.
    @Test func aScaledPhotoIsTheResamplersCrop() throws {
        let image = Self.bands(width: 300, height: 520)
        let f = try #require(ContentFraming.frame(width: 300, height: 520))
        let expected = BicubicResampler.resize(try ContentFraming.rgb(image), width: f.width, height: f.height,
                                               window: (f.left, f.top, 224, 224))
        let buffer = try ContentFraming.pixelBuffer(for: image)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var got: [UInt8] = []
        for y in 0..<224 { for x in 0..<224 { got += [base[y * rowBytes + x * 4 + 2], base[y * rowBytes + x * 4 + 1], base[y * rowBytes + x * 4]] } }
        #expect(got == (0..<(224 * 224)).flatMap { expected.pixels[($0 * 4)..<($0 * 4 + 3)] })
    }

    /// Drawing at the image's own size changes no pixel of an sRGB image.
    @Test func decodingAnSRGBImageKeepsItsPixels() throws {
        let image = Self.bands(width: 40, height: 30)
        let rgb = try ContentFraming.rgb(image)
        let data = try #require(image.dataProvider?.data) as Data
        let colors = { (bytes: [UInt8]) in (0..<(40 * 30)).flatMap { i in bytes[(i * 4)..<(i * 4 + 3)] } }
        #expect(rgb.width == 40 && rgb.height == 30 && rgb.channels == 4)
        #expect(colors(rgb.pixels) == colors([UInt8](data)))
    }

    /// A 256x480 picture needs no scaling, so the buffer should hold exactly its center
    /// 224x224, the right way up, in BGRA: red above, blue below, none of the black margins.
    @Test func theBufferHoldsTheCenterUprightInBGRA() throws {
        let image = Self.bands(width: 256, height: 480)
        let buffer = try ContentFraming.pixelBuffer(for: image)
        #expect(CVPixelBufferGetWidth(buffer) == 224 && CVPixelBufferGetHeight(buffer) == 224)
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
        #expect(CVPixelBufferGetIOSurface(buffer) != nil)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { (0..<4).map { base[y * rowBytes + x * 4 + $0] } }
        for x in [0, 112, 223] {
            #expect(pixel(x, 0) == [0, 0, 255, 255], "top at x \(x): \(pixel(x, 0))")
            #expect(pixel(x, 108) == [0, 0, 255, 255])
            #expect(pixel(x, 116) == [255, 0, 0, 255])
            #expect(pixel(x, 223) == [255, 0, 0, 255], "bottom at x \(x): \(pixel(x, 223))")
        }
    }

    /// Transparent pixels become white, as in the bench.
    @Test func transparencyIsDrawnOverWhite() throws {
        let ctx = CGContext(
            data: nil, width: 300, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let buffer = try ContentFraming.pixelBuffer(for: ctx.makeImage()!)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        #expect((0..<4).map { base[$0] } == [255, 255, 255, 255])
    }

    /// Black margins 16 px wide, red above the middle row of the center, blue below it.
    static func bands(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let top = (height - 224) / 2
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Bottom-left coordinates: the center's upper half is the higher y range.
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 16, y: height - top - 112, width: 224, height: 112))
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 16, y: height - top - 224, width: 224, height: 112))
        return ctx.makeImage()!
    }
}

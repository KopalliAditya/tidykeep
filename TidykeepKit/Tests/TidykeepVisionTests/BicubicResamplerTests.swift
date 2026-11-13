@testable import TidykeepVision
import Testing

@Suite struct BicubicResamplerTests {
    /// A patterned RGB image with sharp steps, so any change in the filter shows.
    static func pattern(width: Int, height: Int) -> BicubicResampler.Image {
        var pixels: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width {
                for c in 0..<3 { pixels.append(UInt8((x * x * 3 + y * 17 + c * 85 + x * y * 5) % 256)) }
            }
        }
        return .init(width: width, height: height, channels: 3, pixels: pixels)
    }

    /// FNV-1a, to compare whole outputs with torchvision's in one number.
    static func hash(_ bytes: [UInt8]) -> UInt64 {
        bytes.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
    }

    /// Hashes of `torchvision.transforms.v2.functional.resize(..., BICUBIC, antialias=True)` on
    /// the same uint8 images (torch 2 on the bench's venv), and of its rows 1..<5, columns
    /// 2..<7: shrinking, enlarging, both at once, and a 142x shrink that runs out of weight
    /// precision.
    @Test(arguments: [
        (37, 23, 11, 7, 0xf5ad_1b27_cfc4_84a7 as UInt64, 0xc0e6_a385_0259_a54b as UInt64?),
        (6, 5, 13, 9, 0x2b61_26c4_d6c2_7fb5, 0x392b_3027_b6fd_96b1),
        (40, 9, 12, 14, 0x8923_8150_b932_99d0, 0x6b9a_a6e6_3ef3_64ec),
        (1000, 3, 7, 3, 0x896b_7144_c6f4_ed7c, nil),
    ])
    func matchesTorchvisionBitForBit(width: Int, height: Int, toWidth: Int, toHeight: Int, whole: UInt64, window: UInt64?) {
        let image = Self.pattern(width: width, height: height)
        let full = BicubicResampler.resize(image, width: toWidth, height: toHeight, window: (0, 0, toWidth, toHeight))
        #expect(full.width == toWidth && full.height == toHeight)
        #expect(Self.hash(full.pixels) == whole, "\(full.pixels.prefix(6))")
        if let window {
            let part = BicubicResampler.resize(image, width: toWidth, height: toHeight, window: (2, 1, 5, 4))
            #expect(Self.hash(part.pixels) == window)
        }
    }

    /// The window is cut from the full result, not resized on its own.
    @Test func aWindowIsPartOfTheWholeResult() {
        let image = Self.pattern(width: 300, height: 200)
        let full = BicubicResampler.resize(image, width: 120, height: 80, window: (0, 0, 120, 80))
        let part = BicubicResampler.resize(image, width: 120, height: 80, window: (30, 10, 50, 60))
        let cut = (10..<70).flatMap { y in full.pixels[(y * 120 + 30) * 3..<(y * 120 + 80) * 3] }
        #expect(part.width == 50 && part.height == 60 && part.pixels == cut)
    }

    @Test func onlyTheBytesAskedForAreResized() {
        let image = Self.pattern(width: 30, height: 20)
        let all = BicubicResampler.resize(image, width: 12, height: 8, window: (0, 0, 12, 8))
        let two = BicubicResampler.resize(image, width: 12, height: 8, window: (0, 0, 12, 8), using: 2)
        for i in 0..<(12 * 8) {
            #expect(two.pixels[i * 3] == all.pixels[i * 3] && two.pixels[i * 3 + 1] == all.pixels[i * 3 + 1])
            #expect(two.pixels[i * 3 + 2] == 0)
        }
    }

    @Test func theSameSizeChangesNothing() {
        let image = Self.pattern(width: 9, height: 7)
        #expect(BicubicResampler.resize(image, width: 9, height: 7, window: (0, 0, 9, 7)) == image)
        // A full pass at scale 1 is the identity too, so skipping it loses nothing.
        let taps = BicubicResampler.Taps(input: 9, output: 9)
        for i in 0..<9 {
            let weights = taps.weights[(i * taps.stride)..<((i + 1) * taps.stride)]
            #expect(weights.filter { $0 != 0 } == [1 << taps.precision])
        }
    }

    @Test func weightsSumToOneAndFitInSixteenBits() {
        for (input, output) in [(1000, 7), (37, 11), (6, 13)] {
            let taps = BicubicResampler.Taps(input: input, output: output)
            #expect(taps.precision <= 22 && taps.weights.allSatisfy { abs($0) < 1 << 15 })
            for i in 0..<output {
                let sum = taps.weights[(i * taps.stride)..<((i + 1) * taps.stride)].reduce(0, +)
                #expect(abs(Int(sum) - (1 << Int(taps.precision))) <= taps.stride, "\(input)->\(output) at \(i)")
            }
        }
    }
}

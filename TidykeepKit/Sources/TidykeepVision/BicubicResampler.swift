import Accelerate
import Foundation

/// Antialiased bicubic resizing of 8-bit pixels, bit for bit as torchvision does it for the
/// transformers processor that made the bench's embeddings (`resize(..., BICUBIC,
/// antialias=True)` on a uint8 tensor).
///
/// CoreGraphics' high-quality resampling is a different filter. Through it the CLS vectors sat a
/// median 0.056 from the bench's, which flipped a few series and screenshot pairs near the
/// fitted thresholds. With this resampler the input is the bench's input.
///
/// The method: one pass along each axis, horizontal first, each through 8-bit pixels. An output
/// pixel is a weighted sum of the inputs under a cubic kernel (a = -0.5) stretched by the scale
/// factor, so shrinking averages every input pixel instead of skipping some. The weights are
/// rounded to 16-bit integers at the largest precision that holds the biggest one, and sums
/// are rounded and clamped back to 8 bits after each pass.
///
/// The sums run in Accelerate's double precision, which is exact here: every partial sum is an
/// integer far below 2^53. That keeps a debug build fast enough for tests.
enum BicubicResampler {
    /// The input pixels that make each output pixel along one axis, and their weights.
    struct Taps: Equatable {
        /// First input index for each output index.
        var first: [Int]
        /// Weights for each output index, `stride` per output; unused slots are zero.
        var weights: [Int32]
        var stride: Int
        var precision: Int32

        init(input: Int, output: Int) {
            let scale = Double(input) / Double(output)
            let stretch = max(scale, 1)
            let support = 2 * stretch
            stride = Int(support.rounded(.up)) * 2 + 1
            var real = [Double](repeating: 0, count: output * stride)
            first = []
            first.reserveCapacity(output)
            for i in 0..<output {
                let center = (Double(i) + 0.5) * scale
                let low = max(Int(center - support + 0.5), 0)
                let high = min(Int(center + support + 0.5), input)
                var total = 0.0
                for j in low..<high {
                    let w = Self.cubic((Double(j) - center + 0.5) / stretch)
                    real[i * stride + j - low] = w
                    total += w
                }
                if total != 0 {
                    for k in 0..<(high - low) { real[i * stride + k] /= total }
                }
                first.append(low)
            }
            // The largest precision below 22 bits at which the biggest weight still fits in 15.
            let biggest = real.max() ?? 0
            var bits = 0
            while bits < 22, Int(0.5 + biggest * Double(1 << (bits + 1))) < 1 << 15 { bits += 1 }
            precision = Int32(bits)
            let one = Double(1 << bits)
            weights = real.map { Int32($0 < 0 ? -0.5 + $0 * one : 0.5 + $0 * one) }
        }

        static func cubic(_ x: Double) -> Double {
            let a = -0.5, x = abs(x)
            if x < 1 { return ((a + 2) * x - (a + 3)) * x * x + 1 }
            if x < 2 { return (((x - 5) * x + 8) * x - 4) * a }
            return 0
        }

        /// The input indices output `i` reads (the weights past the image edge are zero).
        func span(_ i: Int, input: Int) -> Range<Int> { first[i]..<min(first[i] + stride, input) }

        /// `rows` vectors of `length`, the outputs `window` of this axis, from `input`, which holds
        /// one vector of `length` per input index starting at index `base`. Rounded, clamped.
        func apply(_ input: UnsafePointer<Double>, base: Int, inputCount: Int, length: Int, window: Range<Int>) -> [Double] {
            var out = [Double](repeating: 0, count: window.count * length)
            out.withUnsafeMutableBufferPointer { out in
                for (n, o) in window.enumerated() {
                    let row = out.baseAddress! + n * length
                    for (k, j) in span(o, input: inputCount).enumerated() where weights[o * stride + k] != 0 {
                        var w = Double(weights[o * stride + k])
                        vDSP_vsmaD(input + (j - base) * length, 1, &w, row, 1, row, 1, vDSP_Length(length))
                    }
                }
                // (sum + half) >> precision, then clamped to 8 bits; all exact in doubles.
                let n = vDSP_Length(out.count)
                var half = Double(1 << (precision - 1)), unit = 1 / Double(1 << precision), low = 0.0, high = 255.0
                vDSP_vsaddD(out.baseAddress!, 1, &half, out.baseAddress!, 1, n)
                vDSP_vsmulD(out.baseAddress!, 1, &unit, out.baseAddress!, 1, n)
                var count = Int32(out.count)
                vvfloor(out.baseAddress!, out.baseAddress!, &count)
                vDSP_vclipD(out.baseAddress!, 1, &low, &high, out.baseAddress!, 1, n)
            }
            return out
        }
    }

    /// An 8-bit image: `channels` bytes per pixel, rows packed.
    struct Image: Equatable {
        var width: Int
        var height: Int
        var channels: Int
        var pixels: [UInt8]
    }

    /// The image resized to `width x height`, but only the `window` of that result: its pixels
    /// are exactly those of the full resize, with less work. Only the first `using` bytes of each
    /// pixel are resized (all by default); the rest stay zero, as for an unused padding byte.
    static func resize(
        _ image: Image, width: Int, height: Int, window: (x: Int, y: Int, width: Int, height: Int), using: Int? = nil
    ) -> Image {
        let c = image.channels
        let across = Taps(input: image.width, output: width), down = Taps(input: image.height, output: height)
        // The input rows the window's output rows read.
        let rows = down.first[window.y]..<down.span(window.y + window.height - 1, input: image.height).upperBound
        var out = Image(width: window.width, height: window.height, channels: c,
                        pixels: [UInt8](repeating: 0, count: window.width * window.height * c))
        var plane = [Double](repeating: 0, count: rows.count * image.width)
        var columns = [Double](repeating: 0, count: rows.count * image.width)
        for ch in 0..<min(using ?? c, c) {
            // One channel of those rows, then turned so each input column is one vector.
            image.pixels.withUnsafeBufferPointer { src in
                vDSP_vfltu8D(src.baseAddress! + rows.lowerBound * image.width * c + ch, vDSP_Stride(c),
                             &plane, 1, vDSP_Length(rows.count * image.width))
            }
            vDSP_mtransD(plane, 1, &columns, 1, vDSP_Length(image.width), vDSP_Length(rows.count))
            // Horizontal pass: one vector over the rows per output column.
            let partial = across.apply(columns, base: 0, inputCount: image.width, length: rows.count,
                                       window: window.x..<(window.x + window.width))
            // Back to one vector per row, then the vertical pass: one vector per output row.
            var byRow = [Double](repeating: 0, count: partial.count)
            vDSP_mtransD(partial, 1, &byRow, 1, vDSP_Length(rows.count), vDSP_Length(window.width))
            let result = down.apply(byRow, base: rows.lowerBound, inputCount: image.height, length: window.width,
                                    window: window.y..<(window.y + window.height))
            out.pixels.withUnsafeMutableBufferPointer { dst in
                vDSP_vfixu8D(result, 1, dst.baseAddress! + ch, vDSP_Stride(c), vDSP_Length(result.count))
            }
        }
        return out
    }
}

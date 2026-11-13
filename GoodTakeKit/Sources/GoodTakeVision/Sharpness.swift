import CoreGraphics
import Foundation

/// Focus measure: variance of the Laplacian on a grayscale copy, per tile.
///
/// A whole-image measure punishes a sharp subject on a soft background, so the image is
/// split into a grid and the sharpest tiles count. The result is `log1p` of the mean of
/// the top tiles' variances. Only compare values from the same `side` and `grid`.
public enum Sharpness {
    public static func focusMeasure(_ image: CGImage, side: Int = 512, grid: Int = 4, topTiles: Int = 3) -> Float {
        guard let gray = grayscale(image, longEdge: side) else { return 0 }
        let (pixels, w, h) = gray
        guard w >= 3, h >= 3 else { return 0 }

        let tiles = grid * grid
        var sum = [Double](repeating: 0, count: tiles)
        var sumSq = [Double](repeating: 0, count: tiles)
        var n = [Int](repeating: 0, count: tiles)

        pixels.withUnsafeBufferPointer { p in
            for y in 1..<(h - 1) {
                let row = y * w
                let ty = min(y * grid / h, grid - 1) * grid
                for x in 1..<(w - 1) {
                    let i = row + x
                    let lap = Int(p[i - 1]) + Int(p[i + 1]) + Int(p[i - w]) + Int(p[i + w]) - 4 * Int(p[i])
                    let t = ty + min(x * grid / w, grid - 1)
                    let v = Double(lap)
                    sum[t] += v
                    sumSq[t] += v * v
                    n[t] += 1
                }
            }
        }

        let variances = (0..<tiles).compactMap { t -> Double? in
            guard n[t] > 0 else { return nil }
            let mean = sum[t] / Double(n[t])
            return sumSq[t] / Double(n[t]) - mean * mean
        }.sorted(by: >)
        let top = variances.prefix(max(1, topTiles))
        return Float(log1p(top.reduce(0, +) / Double(top.count)))
    }

    /// 8-bit grayscale, scaled so the long edge is at most `longEdge`.
    static func grayscale(_ image: CGImage, longEdge: Int) -> ([UInt8], Int, Int)? {
        let scale = min(1, Double(longEdge) / Double(max(image.width, image.height)))
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? (pixels, w, h) : nil
    }
}

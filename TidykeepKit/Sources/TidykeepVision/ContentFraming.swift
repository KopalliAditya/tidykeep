import CoreGraphics
import CoreVideo
import Foundation

/// How a photo becomes the content model's 224x224 input.
///
/// The transformers processor's crop: scale so the short side is 256, then take the center
/// 224x224. Every series and copy threshold was fitted on embeddings of this input
/// (bench/rules.py). Squashing the whole photo into the square, or letterboxing it, gives
/// different embeddings, and with those the thresholds are wrong: the squashed patch mean fails
/// held-out series precision and the squashed CLS finds 139 of 150 copy sets instead of 150.
/// The crop loses the edges of tall pictures, which is why the copy pass has its own rule for
/// screen-shaped ones.
///
/// The photo is first drawn at its own size in sRGB over white, then scaled with the
/// processor's own filter (`BicubicResampler`), so only the pixels of the crop are computed.
enum ContentFraming {
    static let side = 224
    static let shortSide = 256
    /// Part of `ContentEmbedder.version`: a different framing gives different embeddings.
    /// "aa" is the processor's antialiased bicubic, which replaced CoreGraphics' resampling.
    static let version = "crop256aa"

    /// The scaled size and the crop's offsets from its top-left corner. They use the
    /// processor's integer arithmetic (the long side truncated from 256 * long / short, the
    /// offsets floored from half the excess), so the same pixels are kept. The image must
    /// already be upright.
    static func frame(width: Int, height: Int) -> (width: Int, height: Int, left: Int, top: Int)? {
        guard width > 0, height > 0 else { return nil }
        let (w, h): (Int, Int)
        if width <= height {
            (w, h) = (shortSide, Int(Double(shortSide) * Double(height) / Double(width)))
        } else {
            (w, h) = (Int(Double(shortSide) * Double(width) / Double(height)), shortSide)
        }
        return (w, h, (w - side) / 2, (h - side) / 2)
    }

    enum Failure: Error { case emptyImage, pixelBuffer(CVReturn), context }

    /// A 224x224 BGRA pixel buffer holding the framed photo, as the model's image input wants it.
    /// IOSurface-backed, so Core ML can hand it to the Neural Engine without a copy.
    static func pixelBuffer(for image: CGImage) throws -> CVPixelBuffer {
        guard let f = frame(width: image.width, height: image.height) else { throw Failure.emptyImage }
        let framed = BicubicResampler.resize(try rgb(image), width: f.width, height: f.height,
                                             window: (f.left, f.top, side, side), using: 3)
        var made: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]()]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &made)
        guard status == kCVReturnSuccess, let buffer = made else { throw Failure.pixelBuffer(status) }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { throw Failure.context }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<side {
            for x in 0..<side {
                let p = (y * side + x) * 4, q = y * rowBytes + x * 4
                (base[q], base[q + 1], base[q + 2], base[q + 3]) = (framed.pixels[p + 2], framed.pixels[p + 1], framed.pixels[p], 255)
            }
        }
        return buffer
    }

    /// The image's pixels at its own size as 8-bit RGBX (the fourth byte unused), top row
    /// first. Transparent pixels count as white, as in the bench. Drawing at the same size copies
    /// pixels, converting colors to sRGB; the bench's images carry no color profile, which reads
    /// as sRGB, so for them this changes nothing.
    static func rgb(_ image: CGImage) throws -> BicubicResampler.Image {
        let (w, h) = (image.width, image.height)
        var rgbx = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgbx.withUnsafeMutableBytes { raw -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                  )
            else { return false }
            context.interpolationQuality = .none
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw Failure.context }
        return .init(width: w, height: h, channels: 4, pixels: rgbx)
    }
}

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A deterministic, made-up "photo": a gradient, shapes and fine texture from a seed.
/// The same seed with a small shift or blur looks like another frame of the same moment.
/// Each seed has its own color family and layout, the way two real scenes differ.
public struct SyntheticScene: Sendable {
    public let seed: UInt64

    public init(seed: UInt64) { self.seed = seed }

    public func render(
        width: Int = 1024,
        height: Int = 768,
        shift: CGPoint = .zero,
        brightness: CGFloat = 0,
        blur: Double = 0
    ) -> CGImage {
        var rng = SplitMix64(seed: seed)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let w = CGFloat(width), h = CGFloat(height)

        let hue = rng.unit()
        func color(_ alpha: CGFloat = 1) -> CGColor {
            let (r, g, b) = Self.rgb(
                hue: (hue + (rng.unit() - 0.5) * 0.16 + 1).truncatingRemainder(dividingBy: 1),
                saturation: 0.35 + rng.unit() * 0.6,
                value: 0.25 + rng.unit() * 0.7
            )
            return CGColor(srgbRed: min(1, r + brightness), green: min(1, g + brightness), blue: min(1, b + brightness), alpha: alpha)
        }

        let gradient = CGGradient(colorsSpace: space, colors: [color(), color()] as CFArray, locations: [0, 1])!
        let angle = rng.unit() * 2 * .pi
        let center = CGPoint(x: w / 2, y: h / 2)
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: center.x - cos(angle) * w / 2, y: center.y - sin(angle) * h / 2),
            end: CGPoint(x: center.x + cos(angle) * w / 2, y: center.y + sin(angle) * h / 2),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )

        ctx.translateBy(x: shift.x, y: shift.y)
        // A few big shapes set the layout; many small ones add detail.
        let roundness = rng.unit()
        for k in 0..<28 {
            ctx.setFillColor(color(0.9))
            let big = k < 4
            let rect = CGRect(
                x: rng.unit() * w, y: rng.unit() * h,
                width: big ? w / 3 + rng.unit() * w / 3 : 20 + rng.unit() * w / 6,
                height: big ? h / 3 + rng.unit() * h / 3 : 20 + rng.unit() * h / 6
            )
            if rng.unit() < roundness { ctx.fillEllipse(in: rect) } else { ctx.fill(rect) }
        }
        // Fine stripes: detail that blur visibly destroys, like texture in a real photo.
        for _ in 0..<6 {
            ctx.setStrokeColor(color())
            ctx.setLineWidth(1.5)
            let origin = CGPoint(x: rng.unit() * w, y: rng.unit() * h)
            for k in 0..<24 {
                let x = origin.x + CGFloat(k) * 4
                ctx.move(to: CGPoint(x: x, y: origin.y))
                ctx.addLine(to: CGPoint(x: x, y: origin.y + 90))
            }
            ctx.strokePath()
        }

        let sharp = ctx.makeImage()!
        return blur > 0 ? Self.blurred(sharp, radius: blur) : sharp
    }

    static func rgb(hue: CGFloat, saturation s: CGFloat, value v: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let h = hue * 6
        let c = v * s
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (CGFloat, CGFloat, CGFloat) = switch Int(h) % 6 {
        case 0: (c, x, 0)
        case 1: (x, c, 0)
        case 2: (0, c, x)
        case 3: (0, x, c)
        case 4: (x, 0, c)
        default: (c, 0, x)
        }
        let m = v - c
        return (r + m, g + m, b + m)
    }

    static func blurred(_ image: CGImage, radius: Double) -> CGImage {
        let input = CIImage(cgImage: image)
        let output = input.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: input.extent)
        return CIContext().createCGImage(output, from: input.extent)!
    }

    public static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.9) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}

/// SplitMix64: tiny, fast, and the same on every platform.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> CGFloat { CGFloat(next() >> 11) / CGFloat(1 << 53) }
}

// Draws the 1024×1024 app icon: a stack of near-identical photos with the best one on top.
// Usage: swift scripts/make-icon.swift App/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.png")
let space = CGColorSpace(name: CGColorSpace.sRGB)!
// No alpha channel: App Store icons must be opaque.
let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

// Background: deep teal to indigo.
let background = CGGradient(colorsSpace: space, colors: [rgb(0.05, 0.42, 0.47), rgb(0.16, 0.18, 0.45)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

/// One photo card centred on (cx, cy), rotated, with a little landscape inside.
func card(cx: CGFloat, cy: CGFloat, angle: CGFloat, fade: CGFloat) {
    let w: CGFloat = 560, h: CGFloat = 430, frame: CGFloat = 26
    ctx.saveGState()
    ctx.translateBy(x: cx, y: cy)
    ctx.rotate(by: angle)
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: rgb(0, 0, 0, 0.35))
    let outer = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
    ctx.addPath(CGPath(roundedRect: outer, cornerWidth: 44, cornerHeight: 44, transform: nil))
    ctx.setFillColor(rgb(1, 1, 1, 1 - 0.25 * fade))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    let inner = outer.insetBy(dx: frame, dy: frame)
    ctx.addPath(CGPath(roundedRect: inner, cornerWidth: 24, cornerHeight: 24, transform: nil))
    ctx.clip()
    let sky = CGGradient(colorsSpace: space, colors: [rgb(0.55, 0.80, 0.98), rgb(0.98, 0.86, 0.62)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: inner.maxY), end: CGPoint(x: 0, y: inner.minY), options: [])
    ctx.setFillColor(rgb(1.0, 0.80, 0.25))
    ctx.fillEllipse(in: CGRect(x: inner.maxX - 170, y: inner.maxY - 150, width: 100, height: 100))
    let hills = CGMutablePath()
    hills.move(to: CGPoint(x: inner.minX, y: inner.minY))
    hills.addLine(to: CGPoint(x: inner.minX, y: inner.minY + 120))
    hills.addLine(to: CGPoint(x: inner.minX + 170, y: inner.minY + 250))
    hills.addLine(to: CGPoint(x: inner.minX + 300, y: inner.minY + 150))
    hills.addLine(to: CGPoint(x: inner.minX + 390, y: inner.minY + 210))
    hills.addLine(to: CGPoint(x: inner.maxX, y: inner.minY + 90))
    hills.addLine(to: CGPoint(x: inner.maxX, y: inner.minY))
    hills.closeSubpath()
    ctx.addPath(hills)
    ctx.setFillColor(rgb(0.12, 0.55, 0.42))
    ctx.fillPath()
    if fade > 0 {
        ctx.setFillColor(rgb(1, 1, 1, 0.45 * fade))
        ctx.fill(inner)
    }
    ctx.restoreGState()
}

card(cx: 470, cy: 600, angle: 0.16, fade: 1)
card(cx: 540, cy: 560, angle: -0.10, fade: 0.6)
card(cx: 512, cy: 470, angle: 0.02, fade: 0)

// The pick: a green check badge on the top card.
let badge = CGRect(x: 640, y: 210, width: 210, height: 210)
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: rgb(0, 0, 0, 0.3))
ctx.setFillColor(rgb(0.20, 0.78, 0.35))
ctx.fillEllipse(in: badge)
ctx.setShadow(offset: .zero, blur: 0, color: nil)
ctx.setStrokeColor(rgb(1, 1, 1))
ctx.setLineWidth(30)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: badge.minX + 55, y: badge.midY + 2))
ctx.addLine(to: CGPoint(x: badge.minX + 92, y: badge.midY - 38))
ctx.addLine(to: CGPoint(x: badge.maxX - 50, y: badge.midY + 44))
ctx.strokePath()

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("couldn't write \(out.path)") }
print("wrote \(out.path)")

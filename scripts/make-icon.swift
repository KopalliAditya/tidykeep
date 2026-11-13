// Draws the app icon, "The one you keep": a white photo card standing in front of two paler
// cards, on Ledger teal. The front card is the photo you keep; the ones behind are the rest.
//
// Usage: swift scripts/make-icon.swift App/Assets.xcassets/AppIcon.appiconset
//
// Writes three 1024 x 1024 opaque PNGs into the folder: AppIcon.png (default),
// AppIcon-Dark.png and AppIcon-Tinted.png. Contents.json in the icon set lists all three.
//
// Rules the drawing keeps (from the design spec):
// - Full-bleed square, no alpha channel, no rounded corners: iOS applies its own mask.
// - Nothing finer than 1/24 of the canvas, so it still reads at 29 pt in Settings.
// - No text, checkmarks, trash cans or arrows.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let canvas = CGFloat(size)
let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".", isDirectory: true)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    let r = CGFloat((value >> 16) & 0xFF) / 255
    let g = CGFloat((value >> 8) & 0xFF) / 255
    let b = CGFloat(value & 0xFF) / 255
    return CGColor(colorSpace: space, components: [r, g, b, alpha])!
}

/// The colours of one appearance.
struct Palette {
    var top: CGColor
    var bottom: CGColor
    var card: UInt32
    var backCardAlpha: CGFloat
    var sun: CGColor
    var shadowAlpha: CGFloat
}

let palettes: [(file: String, palette: Palette)] = [
    // Default: Ledger teal, white cards, the dark-mode accent as the sun.
    ("AppIcon.png", Palette(
        top: hex(0x0B6E78), bottom: hex(0x084E56), card: 0xFFFFFF, backCardAlpha: 0.35,
        sun: hex(0x5CC8D2), shadowAlpha: 0.20)),
    // Dark: near-black teal so the cards stay the brightest thing on the Home Screen.
    ("AppIcon-Dark.png", Palette(
        top: hex(0x0A3338), bottom: hex(0x06262B), card: 0xE6F4F5, backCardAlpha: 0.35,
        sun: hex(0x5CC8D2), shadowAlpha: 0.35)),
    // Tinted: grayscale on black, which iOS maps to the user's tint. The front card is the
    // lightest shape and the sun is cut out of it.
    ("AppIcon-Tinted.png", Palette(
        top: hex(0x000000), bottom: hex(0x000000), card: 0xFFFFFF, backCardAlpha: 0.40,
        sun: hex(0x000000), shadowAlpha: 0)),
]

// Geometry, in a top-left origin space (y grows downwards) so the numbers read like a layout.
// Cards are 3:2 with corners about 13% of the width. The front card sits below the middle so
// the cards behind it have room to show above; the group as a whole is centred.
let cardWidth: CGFloat = 600
let cardHeight: CGFloat = 400
let cardRadius: CGFloat = 78
let front = CGRect(x: (canvas - cardWidth) / 2 + 34, y: 400, width: cardWidth, height: cardHeight)
/// Back cards, the furthest first: each turns about its own centre (negative is
/// counterclockwise) and sits higher and further left, so it shows as a wide band above the
/// front card rather than a thin sliver.
let fan: [(degrees: CGFloat, dx: CGFloat, dy: CGFloat)] = [(-16, -44, -128), (-8, -22, -64)]
/// The sun: about 18% of the card's width, in the top-right of the front card.
let sunDiameter: CGFloat = 112
let sunCenter = CGPoint(x: front.maxX - 132, y: front.minY + 118)

func render(_ p: Palette) -> CGImage {
    // No alpha channel: App Store icons must be opaque.
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    ctx.translateBy(x: 0, y: canvas)
    ctx.scaleBy(x: 1, y: -1)

    let background = CGGradient(colorsSpace: space, colors: [p.top, p.bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: .zero, end: CGPoint(x: 0, y: canvas), options: [])

    let cardPath = CGPath(roundedRect: front, cornerWidth: cardRadius, cornerHeight: cardRadius, transform: nil)

    // Back cards, the furthest first.
    for card in fan {
        ctx.saveGState()
        ctx.translateBy(x: front.midX + card.dx, y: front.midY + card.dy)
        ctx.rotate(by: card.degrees * .pi / 180)
        ctx.translateBy(x: -front.midX, y: -front.midY)
        ctx.addPath(cardPath)
        ctx.setFillColor(hex(p.card, p.backCardAlpha))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // The front card, with a soft shadow so it lifts off the cards behind it.
    ctx.saveGState()
    if p.shadowAlpha > 0 {
        ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 28, color: hex(0x000000, p.shadowAlpha))
    }
    ctx.addPath(cardPath)
    ctx.setFillColor(hex(p.card))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.setFillColor(p.sun)
    ctx.fillEllipse(in: CGRect(
        x: sunCenter.x - sunDiameter / 2, y: sunCenter.y - sunDiameter / 2,
        width: sunDiameter, height: sunDiameter))

    return ctx.makeImage()!
}

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for (file, palette) in palettes {
    let url = outDir.appendingPathComponent(file)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, render(palette), nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("couldn't write \(url.path)") }
    print("wrote \(url.path)")
}

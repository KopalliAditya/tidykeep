// Makes the photos and videos CI adds to the simulator's library, with the right answers.
//
//   swift scripts/ci/make-seed-media.swift <out-folder> [--pictures DIR] [--newest-age SECONDS]
//
// What it makes (40 photos and 2 videos):
//   - 3 bursts of 5 near-identical frames, 1-2 seconds apart. One frame in each is sharp;
//     the others have motion or focus blur, so the sharp one is the right keeper.
//   - 3 sets of copies: an original JPEG and 2 re-saves of it, smaller or in another
//     format (HEIC, PNG, low-quality JPEG, a light crop), dated hours or days later.
//   - 6 screenshots: phone-sized PNGs marked the way iOS marks its own (EXIF UserComment
//     "Screenshot"), each showing a different picture.
//   - 10 one-off photos.
//   - 2 videos just over a minute long (64 s and 75 s), H.264 in QuickTime.
//
// The pictures come from the ones that ship with macOS (DIR, default "/Library/User
// Pictures"). Never anyone's own photos. Without them it draws plain synthetic scenes and
// says so in seed.json ("source": "synthetic"); those look more alike to Vision than photos.
//
// Every capture date is written into the file (EXIF for photos, QuickTime metadata for
// videos), because `simctl addmedia` reads the file. The dates sit on a 7-hour grid that
// ends --newest-age seconds ago (default one day), so they're always recent and no two
// moments are near each other in time.
//
// <out-folder> gets the media, truth.json (which file is what) and seed.json, a summary CI
// hands to the tests:
//   {"photos", "screenshots", "videos", "bursts", "copySets", "first", "last", "source",
//    "names": [every photo file], "extras": [the files the app may offer to remove],
//    "keepers": [each burst's sharp frame and each copy set's original: never removed]}
//
// Uses only Apple frameworks, so it runs on a bare GitHub macOS runner with no packages.
import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-seed-media: \(message)\n".utf8))
    exit(1)
}

func note(_ message: String) {
    FileHandle.standardError.write(Data("make-seed-media: \(message)\n".utf8))
}

// MARK: - Arguments

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { fail("\(name) needs a value") }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}
let picturesPath = option("--pictures") ?? "/Library/User Pictures"
let newestAge = option("--newest-age").map { TimeInterval($0) ?? -1 } ?? 86_400
guard newestAge >= 0 else { fail("bad --newest-age") }
guard args.count == 1 else { fail("usage: make-seed-media.swift <out-folder> [--pictures DIR] [--newest-age SECONDS]") }
let output = URL(fileURLWithPath: args[0], isDirectory: true)

// MARK: - Randomness that's the same every run

/// SplitMix64: a tiny, well-known generator, so every run makes the same pictures.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
var rng = SeededRandom(state: 20_261_113)

// MARK: - Pictures

let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// The macOS account pictures, sorted, so the same ones are picked every run. They're
/// symlinks into /System/Library/Templates, so links are followed.
func macPictures(in folder: String) -> [URL] {
    let root = URL(fileURLWithPath: folder, isDirectory: true)
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
    let kinds: Set<String> = ["heic", "jpg", "jpeg", "png", "tif", "tiff"]
    var found: [URL] = []
    for case let url as URL in walker where kinds.contains(url.pathExtension.lowercased()) {
        found.append(url.resolvingSymlinksInPath())
    }
    return found.sorted { $0.path < $1.path }
}

/// A plain scene for when there are no pictures: a gradient sky, ground and a few shapes.
func syntheticScene(_ index: Int) -> CIImage {
    var local = SeededRandom(state: UInt64(1_000 + index))
    let width = 1024, height = 768
    guard let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                             space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("no CGContext") }
    func color() -> CGColor {
        CGColor(red: .random(in: 0...1, using: &local), green: .random(in: 0...1, using: &local), blue: .random(in: 0...1, using: &local), alpha: 1)
    }
    let gradient = CGGradient(colorsSpace: sRGB, colors: [color(), color()] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: Double.random(in: 0...1024, using: &local), y: 768), options: [])
    for _ in 0..<Int.random(in: 4...9, using: &local) {
        cg.setFillColor(color())
        let rect = CGRect(x: .random(in: 0...900, using: &local), y: .random(in: 0...650, using: &local),
                          width: .random(in: 60...380, using: &local), height: .random(in: 60...320, using: &local))
        if Bool.random(using: &local) { cg.fillEllipse(in: rect) } else { cg.fill(rect) }
    }
    return CIImage(cgImage: cg.makeImage()!)
}

/// One picture per moment, never the same one twice.
let picturesNeeded = 24
// Shuffled with a fixed seed: the same picks every run, spread over every category.
var pickOrder = SeededRandom(state: 43)
let pictureURLs = macPictures(in: picturesPath).shuffled(using: &pickOrder)
let seedSource = pictureURLs.count >= picturesNeeded ? "macos-pictures" : "synthetic"
if seedSource == "synthetic" {
    note("only \(pictureURLs.count) pictures in \(picturesPath); drawing synthetic scenes instead")
}

/// Picture `index`, cropped to 4:3 landscape (account pictures are square).
func picture(_ index: Int) -> (name: String, image: CIImage) {
    if seedSource == "synthetic" { return ("scene\(index)", syntheticScene(index)) }
    let url = pictureURLs[index]
    guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { fail("can't read \(url.path)") }
    let e = image.extent
    let h = e.width * 3 / 4
    let cropped = image.cropped(to: CGRect(x: e.minX, y: e.midY - h / 2, width: e.width, height: h))
    let name = url.deletingPathExtension().lastPathComponent.lowercased()
        .replacingOccurrences(of: " ", with: "")
        .filter { $0.isLetter || $0.isNumber }
    return (name, cropped.transformed(by: CGAffineTransform(translationX: -cropped.extent.minX, y: -cropped.extent.minY)))
}

/// Another frame of the same moment from a hand-held phone: slightly reframed and tilted,
/// slightly brighter or darker.
func handheld(_ image: CIImage) -> CIImage {
    let e = image.extent
    let scale = Double.random(in: 0.92...0.97, using: &rng)
    let w = e.width * scale, h = e.height * scale
    let x = e.minX + .random(in: 0...(e.width - w), using: &rng)
    let y = e.minY + .random(in: 0...(e.height - h), using: &rng)
    let angle = Double.random(in: -1.2...1.2, using: &rng) * .pi / 180
    let rotation = CGAffineTransform(translationX: e.midX, y: e.midY).rotated(by: angle).translatedBy(x: -e.midX, y: -e.midY)
    return image.clampedToExtent()
        .transformed(by: rotation)
        .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: Double.random(in: -0.25...0.25, using: &rng)])
        .cropped(to: CGRect(x: x, y: y, width: w, height: h))
        .transformed(by: CGAffineTransform(translationX: -x, y: -y))
}

/// The camera moved or focus missed. Sizes are for a 512-pixel source.
func shaken(_ image: CIImage) -> CIImage {
    let e = image.extent
    let unit = max(e.width, e.height) / 512
    let blurred = Bool.random(using: &rng)
        ? image.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [
            kCIInputRadiusKey: Double.random(in: 3...7, using: &rng) * unit,
            kCIInputAngleKey: Double.random(in: 0...Double.pi, using: &rng),
        ])
        : image.clampedToExtent().applyingGaussianBlur(sigma: .random(in: 1.2...2.4, using: &rng) * unit)
    return blurred.cropped(to: e)
}

/// Scaled to `width` by `height` pixels (4:3 unless given), as a CGImage. Every photo is
/// nominally 4:3, so frames of one burst come out exactly the same size, as a camera's do;
/// the stretch that takes is a fraction of a percent.
func render(_ image: CIImage, width: Int, height: Int? = nil) -> CGImage {
    let height = height ?? width * 3 / 4
    let e = image.extent
    let sx = CGFloat(width) / e.width, sy = CGFloat(height) / e.height
    let scaled = image
        .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy])
    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    guard let cg = context.createCGImage(scaled.clampedToExtent().cropped(to: rect), from: rect, format: .RGBA8, colorSpace: sRGB) else {
        fail("can't render")
    }
    return cg
}

// MARK: - Writing photos

let exifFormat = DateFormatter()
exifFormat.locale = Locale(identifier: "en_US_POSIX")
exifFormat.timeZone = TimeZone(identifier: "UTC")
exifFormat.dateFormat = "yyyy:MM:dd HH:mm:ss"

enum Format: String { case jpeg = "JPEG", heic = "HEIC", png = "PNG" }

/// Writes `image` with its capture date in EXIF. HEIC needs an HEVC encoder, which a
/// virtual machine may lack; then the copy is written as PNG instead (still another format).
/// Returns the file name actually written.
@discardableResult
func writePhoto(_ image: CGImage, base: String, format: Format, quality: Double = 0.9, date: Date, screenshot: Bool = false) -> String {
    let text = exifFormat.string(from: date)
    var exif: [CFString: Any] = [
        kCGImagePropertyExifDateTimeOriginal: text,
        kCGImagePropertyExifDateTimeDigitized: text,
        kCGImagePropertyExifSubsecTimeOriginal: "000",
        kCGImagePropertyExifOffsetTimeOriginal: "+00:00",
        kCGImagePropertyExifOffsetTimeDigitized: "+00:00",
        kCGImagePropertyExifPixelXDimension: image.width,
        kCGImagePropertyExifPixelYDimension: image.height,
    ]
    // What iOS writes into its own screenshots, and what Photos looks for.
    if screenshot { exif[kCGImagePropertyExifUserComment] = "Screenshot" }
    var properties: [CFString: Any] = [kCGImagePropertyExifDictionary: exif]
    if format != .png { properties[kCGImageDestinationLossyCompressionQuality] = quality }
    // TIFF DateTime too: some importers read that one when EXIF has no zone.
    properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFDateTime: text] as [CFString: Any]

    func attempt(_ format: Format) -> String? {
        let ext: String, type: UTType
        switch format {
        case .jpeg: (ext, type) = ("jpg", .jpeg)
        case .heic: (ext, type) = ("heic", .heic)
        case .png: (ext, type) = ("png", .png)
        }
        let name = "\(base).\(ext)"
        let url = output.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return name
    }
    if let name = attempt(format) { return name }
    if format == .heic, let name = attempt(.png) {
        note("no HEIC encoder here; wrote \(name) instead")
        return name
    }
    fail("can't write \(base) as \(format.rawValue)")
}

// MARK: - Screenshots

/// A phone screen: status bar, a title bar, a picture card and rows, in colours and a
/// layout that differ per screenshot, so no two look like copies of each other.
func screenshot(_ index: Int, showing picture: CIImage) -> CGImage {
    var local = SeededRandom(state: UInt64(500 + index))
    let width = 1320.0, height = 2868.0  // iPhone 17 Pro Max, portrait
    guard let cg = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                             space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("no CGContext") }
    let dark = index % 2 == 1
    let hue = Double(index) / 6
    func tint(_ s: Double, _ b: Double) -> CGColor {
        // HSB to RGB, enough for flat colours.
        let h = hue * 6, i = floor(h), f = h - i
        let p = b * (1 - s), q = b * (1 - s * f), t = b * (1 - s * (1 - f))
        let (r, g, bl): (Double, Double, Double) = switch Int(i) % 6 {
        case 0: (b, t, p)
        case 1: (q, b, p)
        case 2: (p, b, t)
        case 3: (p, q, b)
        case 4: (t, p, b)
        default: (b, p, q)
        }
        return CGColor(red: r, green: g, blue: bl, alpha: 1)
    }
    let background = dark ? CGColor(gray: 0.07, alpha: 1) : CGColor(gray: 0.96, alpha: 1)
    let ink = dark ? CGColor(gray: 0.85, alpha: 1) : CGColor(gray: 0.15, alpha: 1)
    cg.setFillColor(background)
    cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
    // CoreGraphics' origin is bottom left: y counts up from the bottom of the screen.
    cg.setFillColor(ink)
    cg.fill(CGRect(x: 120, y: height - 150, width: 150, height: 44))           // the time
    cg.fill(CGRect(x: width - 260, y: height - 146, width: 140, height: 36))  // battery and signal
    cg.setFillColor(tint(0.7, dark ? 0.8 : 0.6))
    cg.fill(CGRect(x: 60, y: height - 380, width: Double.random(in: 420...820, using: &local), height: 90))  // title

    // The picture card, in a different place on each layout.
    let layout = index % 3
    let cardRect: CGRect = switch layout {
    case 0: CGRect(x: 60, y: height - 1400, width: width - 120, height: 900)
    case 1: CGRect(x: 60, y: 700, width: width - 120, height: 1100)
    default: CGRect(x: 200, y: 1200, width: width - 400, height: 700)
    }
    let pictureImage = render(picture, width: Int(cardRect.width), height: Int(cardRect.height))
    cg.saveGState()
    cg.addPath(CGPath(roundedRect: cardRect, cornerWidth: 48, cornerHeight: 48, transform: nil))
    cg.clip()
    cg.draw(pictureImage, in: cardRect)
    cg.restoreGState()

    // Rows of "text": bars of varying length, plus a coloured chip per row.
    var y = layout == 1 ? height - 520 : 600
    let rowCount = layout == 1 ? 2 : 6
    for _ in 0..<rowCount {
        cg.setFillColor(tint(0.5, dark ? 0.7 : 0.8))
        cg.fillEllipse(in: CGRect(x: 60, y: y, width: 110, height: 110))
        cg.setFillColor(ink)
        cg.fill(CGRect(x: 210, y: y + 62, width: Double.random(in: 380...980, using: &local), height: 36))
        cg.setFillColor(dark ? CGColor(gray: 0.5, alpha: 1) : CGColor(gray: 0.6, alpha: 1))
        cg.fill(CGRect(x: 210, y: y + 10, width: Double.random(in: 200...700, using: &local), height: 28))
        y += layout == 1 ? -170 : 150
    }
    // A tab bar or a keyboard-ish grid at the bottom.
    cg.setFillColor(dark ? CGColor(gray: 0.15, alpha: 1) : CGColor(gray: 0.88, alpha: 1))
    if index % 2 == 0 {
        cg.fill(CGRect(x: 0, y: 0, width: width, height: 260))
    } else {
        for row in 0..<3 {
            for key in 0..<10 {
                cg.fill(CGRect(x: 20 + key * 129, y: 40 + row * 150, width: 112, height: 128))
            }
        }
    }
    guard let image = cg.makeImage() else { fail("can't draw screenshot \(index)") }
    return image
}

// MARK: - Videos

/// A slow pan across `picture` with a dot crossing it, `seconds` long at 10 frames a second,
/// H.264 in a QuickTime file whose creation date Photos imports. Falls back to Motion JPEG
/// when there's no H.264 encoder (a virtual machine without media hardware).
func writeVideo(named name: String, showing picture: CIImage, seconds: Int, date: Date) -> String {
    for codec in [AVVideoCodecType.h264, .jpeg] {
        let url = output.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        if encodeVideo(to: url, codec: codec, picture: picture, seconds: seconds, date: date) {
            if codec != .h264 { note("no H.264 encoder here; \(name) is Motion JPEG") }
            return name
        }
    }
    fail("can't write \(name)")
}

func encodeVideo(to url: URL, codec: AVVideoCodecType, picture: CIImage, seconds: Int, date: Date) -> Bool {
    let width = 1280, height = 720, fps: Int32 = 10
    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
    var settings: [String: Any] = [AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height]
    if codec == .h264 {
        settings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: 900_000, AVVideoMaxKeyFrameIntervalKey: 50]
    } else {
        settings[AVVideoCompressionPropertiesKey] = [AVVideoQualityKey: 0.5]
    }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ])
    guard writer.canAdd(input) else { return false }
    writer.add(input)
    let created = AVMutableMetadataItem()
    created.identifier = .quickTimeMetadataCreationDate
    created.dataType = kCMMetadataBaseDataType_UTF8 as String
    created.value = ISO8601DateFormatter().string(from: date) as NSString
    writer.metadata = [created]
    guard writer.startWriting() else { return false }
    writer.startSession(atSourceTime: .zero)

    // The picture, 1.4x the frame, panned from one side to the other.
    let scale = 1.4 * CGFloat(width) / picture.extent.width
    let big = picture.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let travelX = big.extent.width - CGFloat(width)
    let travelY = max(0, big.extent.height - CGFloat(height))
    let frames = seconds * Int(fps)
    for frame in 0..<frames {
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed { return false }
            usleep(2_000)
        }
        guard let pool = adaptor.pixelBufferPool else { return false }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return false }
        let t = CGFloat(frame) / CGFloat(max(1, frames - 1))
        let panned = big.transformed(by: CGAffineTransform(translationX: -travelX * t, y: -travelY * (1 - t) / 2))
        let dot = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.85))
            .cropped(to: CGRect(x: 40 + (CGFloat(width) - 120) * t, y: 60, width: 40, height: 40))
        context.render(dot.composited(over: panned).cropped(to: CGRect(x: 0, y: 0, width: width, height: height)),
                       to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: sRGB)
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)) else { return false }
    }
    input.markAsFinished()
    // Ends exactly at `seconds`, not one frame short.
    writer.endSession(atSourceTime: CMTime(value: CMTimeValue(seconds), timescale: 1))
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    return writer.status == .completed
}

// MARK: - The library

try? FileManager.default.removeItem(at: output)
do {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
} catch {
    fail("can't create \(output.path): \(error)")
}

/// The capture times: a grid of moments 7 hours apart, newest first, ending newestAge ago.
/// Copies made later sit halfway between grid points, so they're never near another moment.
let newest = Date(timeIntervalSince1970: (Date().addingTimeInterval(-newestAge).timeIntervalSince1970).rounded(.down))
let step: TimeInterval = 7 * 3600
var nextMoment = 0
func moment() -> Date {
    defer { nextMoment += 1 }
    return newest.addingTimeInterval(-step * Double(nextMoment))
}

enum Kind { case burst, copies, single, screenshot, video }
// Interleaved the way a camera roll is: never two of a kind in a row.
let plan: [Kind] = [
    .single, .burst, .single, .screenshot, .copies, .single, .video, .single, .burst,
    .screenshot, .single, .copies, .screenshot, .single, .burst, .single, .screenshot,
    .copies, .single, .video, .screenshot, .single, .screenshot, .single,
]

struct Truth: Encodable {
    struct Burst: Encodable { var files: [String]; var best: String }
    struct CopySet: Encodable { var original: String; var copies: [String] }
    struct Video: Encodable { var file: String; var seconds: Int }
    var source = seedSource
    var bursts: [Burst] = []
    var copySets: [CopySet] = []
    var singles: [String] = []
    var screenshots: [String] = []
    var videos: [Video] = []
}
var truth = Truth()
var photoDates: [Date] = []
var allDates: [Date] = []
var nextPicture = 0
func takePicture() -> (name: String, image: CIImage) {
    defer { nextPicture += 1 }
    return picture(nextPicture)
}
let photoWidth = 1600
guard plan.count == picturesNeeded else { fail("the plan has \(plan.count) moments but picks \(picturesNeeded) pictures") }

for kind in plan {
    let when = moment()
    switch kind {
    case .burst:
        let (name, base) = takePicture()
        let n = truth.bursts.count + 1
        let best = 2
        var clock = when
        var files: [String] = []
        for f in 0..<5 {
            var frame = handheld(base)
            if f != best { frame = shaken(frame) }
            files.append(writePhoto(render(frame, width: photoWidth), base: "burst\(n)-\(name)-\(f + 1)", format: .jpeg, date: clock))
            photoDates.append(clock)
            clock.addTimeInterval(Double(Int.random(in: 1...2, using: &rng)))
        }
        truth.bursts.append(.init(files: files, best: files[best]))

    case .copies:
        let (name, base) = takePicture()
        let n = truth.copySets.count + 1
        let original = writePhoto(render(base, width: photoWidth), base: "copy\(n)-\(name)-original", format: .jpeg, date: when)
        photoDates.append(when)
        // Re-saves: smaller, another format, recompressed, or lightly cropped. Each set
        // mixes them differently. Dated hours to days later, as a re-save would be.
        let resaves: [(image: CIImage, width: Int, format: Format, quality: Double)] = switch n {
        case 1: [(base, 1200, .heic, 0.8), (base, 800, .jpeg, 0.55)]
        case 2: [(base, 1024, .png, 1), (base.cropped(to: base.extent.insetBy(dx: base.extent.width * 0.03, dy: base.extent.height * 0.03)), 1552, .heic, 0.85)]
        default: [(base, 1280, .jpeg, 0.6), (base, 960, .png, 1)]
        }
        var copies: [String] = []
        for (c, resave) in resaves.enumerated() {
            let image = resave.image.transformed(by: CGAffineTransform(translationX: -resave.image.extent.minX, y: -resave.image.extent.minY))
            // Half a grid step later, then whole days, but never in the future.
            var date = when.addingTimeInterval(step / 2 + Double(c) * 86_400 * Double(n))
            if date > newest { date = when.addingTimeInterval(step / 2 + Double(c) * 5_400) }
            copies.append(writePhoto(render(image, width: resave.width), base: "copy\(n)-\(name)-resave\(c + 1)", format: resave.format, quality: resave.quality, date: date))
            photoDates.append(date)
        }
        truth.copySets.append(.init(original: original, copies: copies))

    case .single:
        let (name, base) = takePicture()
        let n = truth.singles.count + 1
        truth.singles.append(writePhoto(render(handheld(base), width: photoWidth), base: String(format: "single%02d-%@", n, name), format: .jpeg, date: when))
        photoDates.append(when)

    case .screenshot:
        let (_, base) = takePicture()
        let n = truth.screenshots.count + 1
        truth.screenshots.append(writePhoto(screenshot(n, showing: base), base: "screenshot\(n)", format: .png, date: when, screenshot: true))
        photoDates.append(when)

    case .video:
        let (_, base) = takePicture()
        let n = truth.videos.count + 1
        let seconds = n == 1 ? 64 : 75
        truth.videos.append(.init(file: writeVideo(named: "video\(n).mov", showing: base, seconds: seconds, date: when), seconds: seconds))
    }
    allDates.append(when)
}
allDates += photoDates

// MARK: - Answers

let photoNames = truth.bursts.flatMap(\.files) + truth.copySets.flatMap { [$0.original] + $0.copies } + truth.singles + truth.screenshots
let extras = truth.bursts.flatMap { burst in burst.files.filter { $0 != burst.best } } + truth.copySets.flatMap(\.copies)
let keepers = truth.bursts.map(\.best) + truth.copySets.map(\.original)
let iso = ISO8601DateFormatter()
let summary: [String: Any] = [
    "source": seedSource,
    "photos": photoNames.count,
    "screenshots": truth.screenshots.count,
    "videos": truth.videos.count,
    "bursts": truth.bursts.count,
    "copySets": truth.copySets.count,
    "first": iso.string(from: allDates.min()!),
    "last": iso.string(from: allDates.max()!),
    "names": photoNames.sorted(),
    "extras": extras.sorted(),
    "keepers": keepers.sorted(),
]
do {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(truth).write(to: output.appendingPathComponent("truth.json"))
    try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("seed.json"))
} catch {
    fail("can't write truth.json or seed.json: \(error)")
}
print("make-seed-media: \(photoNames.count) photos (\(truth.bursts.count) bursts, \(truth.copySets.count) copy sets, \(truth.screenshots.count) screenshots, \(truth.singles.count) singles) and \(truth.videos.count) videos from \(seedSource), \(iso.string(from: allDates.min()!)) to \(iso.string(from: allDates.max()!)), in \(output.path)")

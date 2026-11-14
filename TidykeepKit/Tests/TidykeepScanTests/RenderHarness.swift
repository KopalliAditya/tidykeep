import CoreGraphics
import Foundation
import AppKit
import QuartzCore
import ImageIO
import SwiftUI
import Testing
import TidykeepCore
import TidykeepFolderSource
import TidykeepTestSupport
@testable import TidykeepUI
import TidykeepVision
import UniformTypeIdentifiers

/// Draws screens to PNG files for design review, from a demo library with every photo list
/// filled. Set TK_RENDER_DIR to keep the images; without it the screens are still drawn, so a
/// screen that can't draw fails its test.
///
///     TK_RENDER_DIR=/tmp/renders bash scripts/test.sh --filter Renders
@MainActor
enum RenderHarness {
    static let phone = CGSize(width: 393, height: 852)

    static var directory: URL? {
        guard let path = ProcessInfo.processInfo.environment["TK_RENDER_DIR"], !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A checked library: four similar-shot series, singles, six screenshots and five videos,
    /// with every thumbnail already loaded so the renders show pictures.
    static func demoState(defaults: UserDefaults = freshDefaults()) async throws -> AppState {
        let library = temporaryDirectory("demo-library-\(UUID().uuidString)")
        _ = try SyntheticLibrary.write(to: library, seriesCount: 4, framesPerSeries: 3...5, singles: 4, start: Date().addingTimeInterval(-40 * 86_400))
        try DemoPhotoSource.addScreenshots(to: library, count: 6)
        defaults.set(ScanScope.everything.rawValue, forKey: "scanScope")
        defaults.set(Sensitivity.strict.rawValue, forKey: "sensitivity")
        defaults.set(true, forKey: "onboarded")
        let source = DemoPhotoSource(folder: library)
        let state = AppState(
            photoSource: source,
            analyzer: VisionFrameAnalyzer(),
            directory: temporaryDirectory("demo-data-\(UUID().uuidString)"),
            defaults: defaults,
            findsCopies: false
        )
        await state.start()
        try await waitForScan(state.photos)
        let ids = try await source.fetchAssets(since: nil).map(\.id) + source.fetchVideos(since: nil).map(\.id)
        for id in ids {
            _ = await state.photos.thumbnail(for: id, pixelSize: 300)
        }
        return state
    }

    /// Draws `view` in a navigation stack at iPhone size, light and dark, and writes
    /// `<name>-light.png` and `<name>-dark.png` when TK_RENDER_DIR is set. The view is hosted
    /// in an offscreen window and given a moment to run its tasks, so scroll views, navigation
    /// bars and loaded thumbnails all draw.
    static func render(_ view: some View, named name: String, state: AppState, height: CGFloat = phone.height) async {
        _ = NSApplication.shared
        for scheme in [ColorScheme.light, .dark] {
            let content = NavigationStack { view }
                .frame(width: phone.width, height: height)
                .background(Palette.groupedBackground)
                .environment(state)
                .environment(state.photos)
                .environment(state.files)
                .environment(state.contacts)
                .environment(state.history)
                .environment(state.notices)
                .environment(state.preferences)
                .environment(\.colorScheme, scheme)
            let frame = CGRect(x: 0, y: 0, width: phone.width, height: height)
            let host = NSHostingView(rootView: content)
            host.frame = frame
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            window.orderBack(nil)
            host.wantsLayer = true
            // The test runner doesn't spin the main run loop, and SwiftUI lays out and draws
            // from run-loop observers, so turn it by hand between the view's tasks.
            for _ in 0..<8 {
                spinRunLoop(0.03)
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try? await Task.sleep(for: .milliseconds(20))
            }
            defer { window.orderOut(nil); window.contentView = nil }
            guard let layer = host.layer, let image = snapshot(layer, size: frame.size) else {
                Issue.record("\(name) didn't draw")
                continue
            }
            guard let directory else { continue }
            let url = directory.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
    }
}

extension RenderHarness {
    nonisolated static func spinRunLoop(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func snapshot(_ layer: CALayer, size: CGSize, scale: CGFloat = 2) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        if layer.isGeometryFlipped {
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        layer.render(in: ctx)
        return ctx.makeImage()
    }
}

/// A folder library plus videos and albums, which a folder can't hold.
final class DemoPhotoSource: PhotoSource, @unchecked Sendable {
    private let folder: FolderPhotoSource
    private let lock = NSLock()
    private var videoList: [VideoMeta]
    /// A photo in an album nothing can be added to, as some synced albums are.
    private let closedAlbumPhoto: String?

    init(folder url: URL, closedAlbumPhoto: String? = nil) {
        folder = FolderPhotoSource(folder: url)
        self.closedAlbumPhoto = closedAlbumPhoto
        let now = Date()
        videoList = [
            VideoMeta(id: "video-beach", creationDate: now.addingTimeInterval(-3 * 86_400), duration: 754, pixelWidth: 3840, pixelHeight: 2160),
            VideoMeta(id: "video-concert", creationDate: now.addingTimeInterval(-9 * 86_400), duration: 1_312, pixelWidth: 1920, pixelHeight: 1080),
            VideoMeta(id: "video-birthday", creationDate: now.addingTimeInterval(-15 * 86_400), duration: 245, pixelWidth: 3840, pixelHeight: 2160, isFavorite: true),
            VideoMeta(id: "video-drive", creationDate: now.addingTimeInterval(-21 * 86_400), duration: 402, pixelWidth: 1920, pixelHeight: 1080),
            VideoMeta(id: "video-clip", creationDate: now.addingTimeInterval(-30 * 86_400), duration: 95, pixelWidth: 1280, pixelHeight: 720),
        ]
    }

    func access() async -> LibraryAccess { .full }
    func requestAccess() async -> LibraryAccess { .full }
    func changes() -> AsyncStream<Void> { folder.changes() }
    func fetchAssets(since: Date?) async throws -> [AssetMeta] { try await folder.fetchAssets(since: since) }
    func analysisImage(for id: String, maxPixelSize: Int) async throws -> CGImage {
        try await folder.analysisImage(for: id, maxPixelSize: maxPixelSize)
    }
    func fetchVideos(since: Date?) async throws -> [VideoMeta] { lock.withLock { videoList } }

    func thumbnail(for id: String, pixelSize: Int) async -> CGImage? {
        if id.hasPrefix("video-") { return Self.poster(seed: id.hashValue, size: CGSize(width: 480, height: 270)) }
        return await folder.thumbnail(for: id, pixelSize: pixelSize)
    }

    func delete(_ ids: [String]) async -> Set<String> {
        let videos = Set(ids.filter { $0.hasPrefix("video-") })
        lock.withLock { videoList.removeAll { videos.contains($0.id) } }
        return await folder.delete(ids.filter { !$0.hasPrefix("video-") }).union(videos)
    }

    func existing(_ ids: [String]) async -> Set<String> {
        let videos = lock.withLock { Set(videoList.map(\.id)) }
        return await folder.existing(ids.filter { !videos.contains($0) }).union(Set(ids).intersection(videos))
    }

    func albums() async -> [PhotoAlbum] {
        var albums = [
            PhotoAlbum(id: "album-family", title: "Family", assetIDs: ["series00_frame0.jpg"]),
            PhotoAlbum(id: "album-receipts", title: "Receipts", assetIDs: ["screenshot-1.png"]),
            PhotoAlbum(id: "album-trip", title: "Lisbon trip", assetIDs: ["video-beach"]),
        ]
        if let closedAlbumPhoto {
            albums.append(PhotoAlbum(id: "album-synced", title: "Synced", assetIDs: [closedAlbumPhoto], canAddPhotos: false))
        }
        return albums
    }

    func formats(for ids: [String]) async -> [String: String] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, $0.hasSuffix(".png") ? "PNG" : "JPEG") })
    }

    func coverage(since: Date?) async -> LibraryCoverage { LibraryCoverage(outsideRange: 0, inSharedAlbums: 12) }

    // MARK: Drawing

    /// Writes phone-shaped screenshots (a status bar, a header and lines of "text") and marks
    /// them as screenshots in the folder's manifest.
    static func addScreenshots(to folder: URL, count: Int) throws {
        var manifest = FolderPhotoSource.Manifest(files: [:])
        if let data = try? Data(contentsOf: folder.appendingPathComponent(FolderPhotoSource.Manifest.fileName)) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            manifest = try decoder.decode(FolderPhotoSource.Manifest.self, from: data)
        }
        let tints: [(CGFloat, CGFloat, CGFloat)] = [(0.2, 0.5, 0.9), (0.95, 0.55, 0.2), (0.3, 0.7, 0.45), (0.6, 0.35, 0.8), (0.9, 0.3, 0.4), (0.25, 0.6, 0.65)]
        for i in 0..<count {
            let name = "screenshot-\(i).png"
            let image = screenshot(tint: tints[i % tints.count], lines: 6 + i)
            let url = folder.appendingPathComponent(name)
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
            manifest.files[name] = .init(date: Date().addingTimeInterval(-Double(i) * 2 * 86_400), screenshot: true)
        }
        try manifest.write(to: folder)
    }

    private static func context(_ size: CGSize) -> CGContext {
        CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
    }

    private static func screenshot(tint: (CGFloat, CGFloat, CGFloat), lines: Int) -> CGImage {
        let size = CGSize(width: 590, height: 1278)
        let ctx = context(size)
        ctx.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.setFillColor(CGColor(red: tint.0, green: tint.1, blue: tint.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: size.height - 260, width: size.width, height: 260))
        ctx.setFillColor(CGColor(gray: 0.78, alpha: 1))
        for line in 0..<lines {
            let width = size.width - 80 - CGFloat((line * 53) % 180)
            ctx.fill(CGRect(x: 40, y: size.height - 330 - CGFloat(line) * 70, width: width, height: 26))
        }
        return ctx.makeImage()!
    }

    static func poster(seed: Int, size: CGSize) -> CGImage {
        let ctx = context(size)
        var rng = SplitMix(seed: UInt64(bitPattern: Int64(seed)))
        let top = CGColor(red: rng.next(0.1...0.5), green: rng.next(0.3...0.7), blue: rng.next(0.6...0.95), alpha: 1)
        let bottom = CGColor(red: rng.next(0.7...1), green: rng.next(0.5...0.85), blue: rng.next(0.2...0.5), alpha: 1)
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [bottom, top] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 0.35))
        ctx.fillEllipse(in: CGRect(x: rng.next(0...size.width * 0.6), y: 0, width: size.width * 0.5, height: size.height * 0.45))
        return ctx.makeImage()!
    }
}

private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(_ range: ClosedRange<CGFloat>) -> CGFloat {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return range.lowerBound + CGFloat(Double(z >> 11) / Double(1 << 53)) * (range.upperBound - range.lowerBound)
    }
}

/// Every screen, drawn from the demo library. Each slice adds its screens here.
@MainActor @Suite(.serialized) struct Renders {
    @Test func home() async throws {
        let state = try await RenderHarness.demoState()
        await RenderHarness.render(TidyHomeView(), named: "home", state: state)
        await RenderHarness.render(OnboardingView(), named: "onboarding", state: state)
        await RenderHarness.render(CoverageSheet(coverage: state.photos.coverage), named: "coverage", state: state)
    }
}

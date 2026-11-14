import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import TidykeepCore
import TidykeepFolderSource
import TidykeepTestSupport
@testable import TidykeepUI
import TidykeepVision
import UniformTypeIdentifiers
import AppKit

// MARK: - Renders

/// Copies, Screenshots and Big Videos, drawn from demo libraries.
///
///     TK_RENDER_DIR=/tmp/renders bash scripts/test.sh --filter PhotoListsRenders
@MainActor @Suite(.serialized) struct PhotoListsRenders {
    @Test func copies() async throws {
        let empty = try await RenderHarness.demoState()
        await RenderHarness.render(CopiesView(), named: "copies-empty", state: empty)

        let state = try await CopiesDemo.state()
        #expect(state.photos.copies.count == 2)
        await RenderHarness.render(CopiesView(), named: "copies", state: state)
        let set = try #require(state.photos.copies.first { $0.members.count == 3 })
        await RenderHarness.render(CopySetView(groupID: set.id), named: "copy-set", state: state, height: 1_200)
        let review = state.photos.mergeReview(for: state.photos.copies)
        await renderSheet(ReviewSheet(request: review), named: "review-merge", state: state)

        // The smallest copy is a favorite, so it's the one kept and the others can't be chosen.
        let locked = try await CopiesDemo.state(favorite: "series00_frame0.jpg")
        let lockedSet = try #require(locked.photos.copies.first { $0.members.count == 3 })
        #expect(locked.photos.copyKeeper(in: lockedSet).isFavorite)
        await RenderHarness.render(CopySetView(groupID: lockedSet.id), named: "copy-set-locked", state: locked, height: 1_200)
    }

    @Test func screenshots() async throws {
        let state = try await ListsDemo.state(screenshots: 16)
        await RenderHarness.render(ScreenshotsView(), named: "screenshots", state: state)
        let months = ScreenshotMonth.sections(state.photos.screenshots)
        #expect(months.count >= 2)
        state.photos.toggleMarks(months[0].items.map(\.id))
        state.photos.markedScreenshots.insert(months[1].items[0].id)
        await RenderHarness.render(ScreenshotsView(isSelecting: true), named: "screenshots-select", state: state)
        let review = state.photos.screenshotsReview(Array(state.photos.markedScreenshots), keepsAlbums: true)
        await renderSheet(ReviewSheet(request: review), named: "review-screenshots", state: state)
        // Marks the filter hides are left out of the count and the bar, and said so.
        await RenderHarness.render(ScreenshotsView(filter: .olderThanMonth), named: "screenshots-filtered", state: state)
    }

    @Test func videos() async throws {
        let state = try await RenderHarness.demoState()
        await RenderHarness.render(BigVideosView(), named: "videos", state: state)
        state.photos.markedVideos = ["video-concert", "video-drive"]
        await RenderHarness.render(BigVideosView(isSelecting: true), named: "videos-select", state: state)
        // After Done, marked videos keep their check.
        await RenderHarness.render(BigVideosView(), named: "videos-marked", state: state)
        await RenderHarness.render(VideoDetailView(videoID: "video-beach"), named: "video-detail", state: state)
        let review = state.photos.videosReview(Array(state.photos.markedVideos), minimum: state.preferences.videoMinimum)
        await renderSheet(ReviewSheet(request: review), named: "review-videos", state: state)
    }
}

extension PhotoListsRenders {
    /// Like `RenderHarness.render`, without the navigation stack around the view: the review
    /// sheet brings its own, and a stack inside a stack draws nothing here.
    private func renderSheet(_ view: some View, named name: String, state: AppState) async {
        _ = NSApplication.shared
        let size = RenderHarness.phone
        for scheme in [ColorScheme.light, .dark] {
            let content = view
                .frame(width: size.width, height: size.height)
                .environment(state)
                .environment(state.photos)
                .environment(state.history)
                .environment(state.notices)
                .environment(state.preferences)
                .environment(\.colorScheme, scheme)
            let frame = CGRect(origin: .zero, size: size)
            let host = NSHostingView(rootView: content)
            host.frame = frame
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            window.orderBack(nil)
            host.wantsLayer = true
            for _ in 0..<8 {
                RenderHarness.spinRunLoop(0.03)
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try? await Task.sleep(for: .milliseconds(20))
            }
            defer { window.orderOut(nil); window.contentView = nil }
            guard let layer = host.layer, let image = RenderHarness.snapshot(layer, size: size) else {
                Issue.record("\(name) didn't draw")
                continue
            }
            guard let directory = RenderHarness.directory else { continue }
            let url = directory.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
    }
}

// MARK: - Behaviour

@MainActor struct PhotoListsBehaviour {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func shot(_ id: String, _ date: Date) -> AssetMeta {
        AssetMeta(id: id, creationDate: date, isScreenshot: true)
    }

    @Test func screenshotsGroupByMonthNewestFirst() {
        let metas = [
            shot("sep", date(2026, 9, 30)),
            shot("nov-early", date(2026, 11, 1)),
            shot("oct", date(2026, 10, 15)),
            shot("nov-late", date(2026, 11, 12)),
            shot("last-nov", date(2025, 11, 20)),
        ]
        let sections = ScreenshotMonth.sections(metas, calendar: calendar)
        #expect(sections.map { $0.items.map(\.id) } == [["nov-late", "nov-early"], ["oct"], ["sep"], ["last-nov"]])
        #expect(sections[0].month == calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        #expect(ScreenshotMonth.sections([], calendar: calendar).isEmpty)
    }

    @Test func markAllMarksOnlyThatMonthAndTogglesBack() async throws {
        let now = Date()
        let source = MemoryPhotoSource(photos: [
            AssetMeta(id: "a", creationDate: now, isScreenshot: true),
            AssetMeta(id: "b", creationDate: now.addingTimeInterval(-60), isScreenshot: true),
            AssetMeta(id: "c", creationDate: now.addingTimeInterval(-70 * 86_400), isScreenshot: true),
            AssetMeta(id: "d", creationDate: now.addingTimeInterval(-71 * 86_400), isScreenshot: true),
        ])
        let state = try await Self.memoryState(source)
        let photos = state.photos
        let months = ScreenshotMonth.sections(photos.screenshots)
        #expect(months.count >= 2)
        let first = months[0].items.map(\.id)

        #expect(photos.toggleMarks(first))
        #expect(photos.markedScreenshots == Set(first))

        // One unmarked in the month: Mark all marks the rest, leaving other months alone.
        photos.markedScreenshots.remove(first[0])
        photos.markedScreenshots.insert(months[1].items[0].id)
        #expect(photos.toggleMarks(first))
        #expect(photos.markedScreenshots == Set(first).union([months[1].items[0].id]))

        // All marked: Unmark all clears only that month.
        #expect(!photos.toggleMarks(first))
        #expect(photos.markedScreenshots == [months[1].items[0].id])
    }

    @Test func screenshotReviewListsMarkedNewestFirstAndRemoves() async throws {
        let now = Date()
        let source = MemoryPhotoSource(photos: [
            AssetMeta(id: "new", creationDate: now, isScreenshot: true),
            AssetMeta(id: "mid", creationDate: now.addingTimeInterval(-3_600), isScreenshot: true),
            AssetMeta(id: "old", creationDate: now.addingTimeInterval(-7_200), isScreenshot: true),
        ])
        let state = try await Self.memoryState(source)
        let review = state.photos.screenshotsReview(["old", "new"], keepsAlbums: true)
        #expect(review.title == "Remove 2 screenshots?")
        #expect(review.confirmTitle == "Remove 2 screenshots")
        #expect(review.removing.map(\.id) == ["new", "old"])
        #expect(review.staying.isEmpty)
        #expect(review.reason.keptSafe != nil)
        state.photos.markedScreenshots = ["old", "new"]
        await review.confirm()
        #expect(state.photos.screenshots.map(\.id) == ["mid"])
        #expect(state.photos.markedScreenshots.isEmpty)
    }

    @Test func videoReviewFollowsListOrderAndRunsItsHook() async throws {
        let now = Date()
        let source = MemoryPhotoSource(photos: [], videos: [
            VideoMeta(id: "short", creationDate: now, duration: 90, pixelWidth: 1280, pixelHeight: 720),
            VideoMeta(id: "long", creationDate: now, duration: 900, pixelWidth: 3840, pixelHeight: 2160),
            VideoMeta(id: "tiny", creationDate: now, duration: 20, pixelWidth: 1920, pixelHeight: 1080),
        ])
        let state = try await Self.memoryState(source)
        #expect(state.photos.videos.map(\.id) == ["long", "short"])
        var done = false
        let review = state.photos.videosReview(["short", "long"], minimum: 60, title: Copy.Videos.removeTitle) { done = true }
        #expect(review.title == "Remove this video?")
        #expect(review.removing.map(\.id) == ["long", "short"])
        #expect(review.confirmTitle == "Remove 2 videos")
        await review.confirm()
        #expect(done)
        #expect(state.photos.videos.isEmpty)
    }

    @Test func mergeReviewCountsSetsAndKeepers() async throws {
        let state = try await CopiesDemo.state()
        let photos = state.photos
        let review = photos.mergeReview(for: photos.copies)
        #expect(review.title == "Merge 2 sets?")
        #expect(review.removing.count == photos.copyRemovalCount)
        #expect(review.staying.map(\.id) == photos.copies.map { photos.copyKeeper(in: $0).id })
        await review.confirm()
        #expect(photos.copies.isEmpty)
    }

    @Test func onlyCopiesAboveEveryKeptSafeOneCanBeChosen() async throws {
        let state = try await Self.memoryState(MemoryPhotoSource(photos: []))
        let photos = state.photos
        let now = Date()
        func copy(_ id: String, _ width: Int) -> (meta: AssetMeta, signals: FrameSignals) {
            (AssetMeta(id: id, creationDate: now, pixelWidth: width, pixelHeight: width),
             FrameSignals(embedding: QuantizedEmbedding([1, 0]), aesthetics: 0.5, isUtility: false, sharpness: 1, faceQualities: []))
        }
        // "b" is in an album the rules protect; "a" has the most detail and comes first.
        let group = PhotoGroup(copies: [copy("a", 3_000), copy("b", 2_000), copy("c", 1_000)]).applying(keptByRules: ["b"])
        #expect(photos.canChooseCopy("a", in: group))
        #expect(photos.canChooseCopy("b", in: group))
        #expect(!photos.canChooseCopy("c", in: group))

        // Choosing "b" makes it the one kept; choosing "c" couldn't, since "b" always stays.
        photos.keepOnly("b", in: group)
        #expect(photos.copyKeeper(in: group).id == "b")
        photos.keepOnly("c", in: group)
        #expect(photos.copyKeeper(in: group).id == "b")

        // Copies numbered as the rows are, best first, not by date.
        #expect(Copy.Copies.keepingOnly("b", in: group, removing: 1) == "Keeping copy 2 of 3. 1 to remove.")
        #expect(Copy.Copies.keepingOnly("a", in: group, removing: 0) == "Keeping copy 1 of 3. Nothing to remove.")
    }

    @Test func copyTextIsPlain() {
        #expect(Copy.Videos.overMinimum(5, minimum: 60) == "5 videos over 1 minute")
        #expect(Copy.Videos.overMinimum(1, minimum: 300) == "1 video over 5 minutes")
        #expect(Copy.Copies.list(["Family", "Trip", "Work"]) == "Family, Trip and Work")
        #expect(Copy.Copies.afterMerge(favorite: true, albums: ["Family"]).contains("a favorite and in Family"))
        let words = [
            Copy.Copies.explainer, Copy.Copies.undo(until: Date()), Copy.Copies.reviewWhy(sets: 2),
            Copy.Screenshots.keptSafeFooter(albums: true), Copy.Videos.footer(kept: 2), Copy.Videos.removesEverywhere,
            Copy.Copies.keptSafeFirst, Copy.Copies.cantChooseKeptSafeFirst, Copy.Screenshots.hiddenMarked(2),
        ].joined(separator: " ").lowercased()
        for banned in ["we ", "oops", "!", "junk", "boost", "free up"] {
            #expect(!words.contains(banned), "\(banned)")
        }
    }

    @Test func filtersByAge() {
        let now = date(2026, 11, 13)
        #expect(Copy.Screenshots.Filter.all.includes(now, now: now, calendar: calendar))
        #expect(!Copy.Screenshots.Filter.olderThanMonth.includes(date(2026, 11, 1), now: now, calendar: calendar))
        #expect(Copy.Screenshots.Filter.olderThanMonth.includes(date(2026, 10, 1), now: now, calendar: calendar))
        #expect(!Copy.Screenshots.Filter.olderThanYear.includes(date(2026, 1, 1), now: now, calendar: calendar))
        #expect(Copy.Screenshots.Filter.olderThanYear.includes(date(2025, 10, 1), now: now, calendar: calendar))
    }

    static func memoryState(_ source: MemoryPhotoSource) async throws -> AppState {
        let defaults = freshDefaults()
        defaults.set(ScanScope.everything.rawValue, forKey: "scanScope")
        defaults.set(true, forKey: "onboarded")
        let state = AppState(photoSource: source, analyzer: ConstantAnalyzer(), directory: nil, defaults: defaults, findsCopies: false)
        await state.start()
        try await waitForScan(state.photos)
        return state
    }
}

// MARK: - Demo libraries

/// The render harness's demo library with more screenshots, so they span two months.
@MainActor
enum ListsDemo {
    static func state(screenshots: Int) async throws -> AppState {
        let library = temporaryDirectory("lists-library-\(UUID().uuidString)")
        _ = try SyntheticLibrary.write(to: library, seriesCount: 2, framesPerSeries: 3...4, singles: 2, start: Date().addingTimeInterval(-40 * 86_400))
        try DemoPhotoSource.addScreenshots(to: library, count: screenshots)
        return try await CopiesDemo.start(DemoPhotoSource(folder: library), analyzer: VisionFrameAnalyzer(), findsCopies: false)
    }
}

/// A small library with real copy sets: a picture saved three times (once byte for byte, once
/// smaller), another saved as JPEG and PNG, and one with no copies. Copies are days apart, as
/// they usually are, so the time window never takes them as similar shots.
@MainActor
enum CopiesDemo {
    /// `favorite` names a file Photos would call a favorite.
    static func state(favorite: String? = nil) async throws -> AppState {
        let library = temporaryDirectory("copies-library-\(UUID().uuidString)")
        let now = Date()
        func day(_ n: Double) -> Date { now.addingTimeInterval(-n * 86_400) }
        var manifest = FolderPhotoSource.Manifest(files: [:])

        let lake = picture(hue: 0.54, size: CGSize(width: 1600, height: 1200), seed: 1)
        try write(lake, as: "lake.jpg", in: library)
        try FileManager.default.copyItem(at: library.appendingPathComponent("lake.jpg"), to: library.appendingPathComponent("lake-copy.jpg"))
        // In the demo's Family album, so merging moves the album onto the kept copy.
        try write(scaled(lake, to: CGSize(width: 800, height: 600)), as: "series00_frame0.jpg", in: library)
        manifest.files["lake.jpg"] = .init(date: day(30))
        manifest.files["lake-copy.jpg"] = .init(date: day(22))
        manifest.files["series00_frame0.jpg"] = .init(date: day(12))

        let sunset = picture(hue: 0.04, size: CGSize(width: 1200, height: 1600), seed: 2)
        try write(sunset, as: "sunset.jpg", in: library)
        try write(sunset, as: "sunset.png", in: library)
        manifest.files["sunset.jpg"] = .init(date: day(18))
        manifest.files["sunset.png"] = .init(date: day(4))

        try write(picture(hue: 0.29, size: CGSize(width: 1600, height: 1200), seed: 3), as: "meadow.jpg", in: library)
        manifest.files["meadow.jpg"] = .init(date: day(9))
        if let favorite { manifest.files[favorite]?.favorite = true }
        try manifest.write(to: library)

        return try await start(DemoPhotoSource(folder: library), analyzer: HueAnalyzer(), findsCopies: true)
    }

    static func start(_ source: DemoPhotoSource, analyzer: any FrameAnalyzing, findsCopies: Bool) async throws -> AppState {
        let defaults = freshDefaults()
        defaults.set(ScanScope.everything.rawValue, forKey: "scanScope")
        defaults.set(Sensitivity.strict.rawValue, forKey: "sensitivity")
        defaults.set(true, forKey: "onboarded")
        let state = AppState(
            photoSource: source,
            analyzer: analyzer,
            directory: temporaryDirectory("lists-data-\(UUID().uuidString)"),
            defaults: defaults,
            findsCopies: findsCopies
        )
        await state.start()
        try await waitForScan(state.photos)
        let ids = try await source.fetchAssets(since: nil).map(\.id) + source.fetchVideos(since: nil).map(\.id)
        for id in ids {
            _ = await state.photos.thumbnail(for: id, pixelSize: 300)
        }
        for group in state.photos.copies {
            await state.photos.loadFormats(for: group)
        }
        return state
    }

    // MARK: Drawing

    private static func context(_ size: CGSize) -> CGContext {
        CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
    }

    /// A simple landscape in shades of one hue: sky, a sun and two hills.
    static func picture(hue: CGFloat, size: CGSize, seed: Int) -> CGImage {
        let ctx = context(size)
        func color(_ saturation: CGFloat, _ brightness: CGFloat) -> CGColor {
            let rgb = hsb(hue, saturation, brightness)
            return CGColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        }
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(0.25, 1), color(0.7, 0.85)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height * 0.4), end: CGPoint(x: 0, y: size.height), options: [])
        ctx.setFillColor(color(0.08, 1))
        let sun = size.width * 0.16
        ctx.fillEllipse(in: CGRect(x: size.width * (0.2 + 0.15 * CGFloat(seed % 3)), y: size.height * 0.62, width: sun, height: sun))
        ctx.setFillColor(color(0.55, 0.55))
        ctx.fillEllipse(in: CGRect(x: -size.width * 0.3, y: -size.height * 0.35, width: size.width * 1.1, height: size.height * 0.8))
        ctx.setFillColor(color(0.75, 0.35))
        ctx.fillEllipse(in: CGRect(x: size.width * 0.3, y: -size.height * 0.45, width: size.width * 1.0, height: size.height * 0.75))
        return ctx.makeImage()!
    }

    private static func hsb(_ h: CGFloat, _ s: CGFloat, _ v: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let i = Int(h * 6) % 6, f = h * 6 - floor(h * 6)
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    static func scaled(_ image: CGImage, to size: CGSize) -> CGImage {
        let ctx = context(size)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        return ctx.makeImage()!
    }

    static func write(_ image: CGImage, as name: String, in folder: URL) throws {
        let type = name.hasSuffix(".png") ? UTType.png : UTType.jpeg
        let url = folder.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}

/// Stands in for the content model: a picture's average hue, as one of twelve directions. The
/// demo pictures are each drawn in one hue, so copies of a picture match exactly and different
/// pictures are far apart.
struct HueAnalyzer: FrameAnalyzing {
    let version = "hue"

    func analyze(_ image: CGImage) async throws -> FrameSignals {
        var vector = [Float](repeating: 0, count: 12)
        vector[Self.hueBin(image)] = 1
        let embedding = QuantizedEmbedding(vector)
        return FrameSignals(
            embedding: embedding, aesthetics: 0.5, isUtility: false, sharpness: 1, faceQualities: [],
            dinoCLS: embedding, dinoMean: embedding
        )
    }

    static func hueBin(_ image: CGImage) -> Int {
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return 0 }
        let r = Double(pixel[0]), g = Double(pixel[1]), b = Double(pixel[2])
        let maxC = max(r, g, b), minC = min(r, g, b), delta = maxC - minC
        guard delta > 0 else { return 0 }
        var hue: Double
        if maxC == r { hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
        else if maxC == g { hue = (b - r) / delta + 2 }
        else { hue = (r - g) / delta + 4 }
        hue /= 6
        if hue < 0 { hue += 1 }
        return min(Int(hue * 12), 11)
    }
}

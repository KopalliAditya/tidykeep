// PhotoKitSource against the real Photos framework, inside the app, on the seeded simulator.
//
// What a unit test can't do is confirm PhotoKit's own "Delete" prompt: only a person (or a
// UI test, through SpringBoard) can. EndToEndUITests covers deleting and merging; here the
// read side is checked, plus the two calls the app relies on around a change: `existing(_:)`
// to tell which photos are still there, and `changes()` to hear that something changed.
//
// Simulator only, so a device's own library is never read.
#if targetEnvironment(simulator)
import CoreGraphics
import Foundation
import ImageIO
import Photos
import Testing
import UniformTypeIdentifiers

import TidykeepCore
import TidykeepPhotoKit
import TidykeepVision

@Suite(
    "PhotoKit on the seeded simulator library",
    .serialized,
    .enabled(if: TestEnvironment.photosAuthorized, "needs photo access, granted by CI with simctl privacy")
)
struct PhotoKitIntegrationTests {
    let source = PhotoKitSource()

    @Test func theAppHasFullAccess() async {
        #expect(await source.access() == .full)
    }

    /// The seeded photos, as the scan sees them.
    private func seeded() async throws -> [AssetMeta] {
        let range = try #require(TestEnvironment.seedRange, "TK_SEED_FIRST and TK_SEED_LAST aren't set")
        return try await source.fetchAssets(since: nil).filter { range.contains($0.creationDate) }
    }

    @Test(.enabled(if: TestEnvironment.seedPhotos != nil))
    func seededPhotosArriveWithTheirCaptureDates() async throws {
        let photos = try await seeded()
        let expected = try #require(TestEnvironment.seedPhotos)
        #expect(photos.count <= expected, "More photos in the seed's dates than were seeded")
        #expect(
            photos.count >= expected - TestEnvironment.removedByUITestsAtMost,
            "Only \(photos.count) of \(expected) seeded photos are left"
        )
        for photo in photos {
            #expect(photo.pixelWidth > 0 && photo.pixelHeight > 0, "\(photo.id) has no size")
        }

        // Burst frames were taken one or two seconds apart, and Photos keeps the capture
        // date from EXIF: the library has runs of photos that close together.
        let dates = photos.map(\.creationDate).sorted()
        let close = zip(dates, dates.dropFirst()).filter { $1.timeIntervalSince($0) <= 2.5 }.count
        #expect(close >= 4, "Only \(close) photos are seconds after the one before; burst dates were lost")
    }

    @Test(.enabled(if: TestEnvironment.seedScreenshots != nil))
    func seededScreenshotsAreMarkedAsScreenshots() async throws {
        let expected = try #require(TestEnvironment.seedScreenshots)
        let marked = try await seeded().filter(\.isScreenshot).count
        // Photos decides itself whether an imported PNG is a screenshot (screen-sized, no
        // camera EXIF); `simctl addmedia` doesn't always get the same answer.
        withKnownIssue("Photos may not mark imported PNGs as screenshots", isIntermittent: true) {
            #expect(marked >= expected, "\(marked) of \(expected) seeded screenshots are marked")
        }
    }

    @Test(.enabled(if: TestEnvironment.seedVideos != nil))
    func longVideosArrive() async throws {
        let expected = try #require(TestEnvironment.seedVideos)
        let long = try await source.fetchVideos(since: nil).filter { $0.duration > 60 }
        #expect(long.count >= expected, "\(long.count) videos over a minute, \(expected) seeded")
    }

    /// The analysis image comes from the photo on the simulator, never from the network
    /// (PhotoKitSource turns network access off), and Vision and the bundled content model
    /// both run on it.
    @Test(.enabled(if: TestEnvironment.seedPhotos != nil))
    func imagesLoadLocallyAndVisionRunsOnThem() async throws {
        let photo = try #require(try await seeded().first { !$0.isScreenshot }, "No seeded photo left")

        let thumbnail = try #require(await source.thumbnail(for: photo.id, pixelSize: 256))
        #expect(max(thumbnail.width, thumbnail.height) <= 256)

        let image = try await source.analysisImage(for: photo.id, maxPixelSize: 512)
        #expect(image.width > 0 && image.height > 0)
        #expect(max(image.width, image.height) <= 512)

        let signals = try await VisionFrameAnalyzer().analyze(image)
        #expect(!signals.embedding.codes.isEmpty, "Vision gave no feature print")
        #expect(signals.dinoCLS != nil, "The bundled content model didn't run (missing from the app bundle?)")
    }

    @Test func anUnknownPhotoIsNotFound() async {
        await #expect(throws: PhotoSourceError.notFound) {
            _ = try await source.analysisImage(for: "00000000-0000-0000-0000-000000000000/L0/001", maxPixelSize: 64)
        }
    }

    @Test(.enabled(if: TestEnvironment.seedPhotos != nil))
    func existingReportsOnlyWhatIsThere() async throws {
        let ids = try await seeded().prefix(3).map(\.id)
        try #require(!ids.isEmpty, "No seeded photo left")
        let unknown = "00000000-0000-0000-0000-000000000000/L0/001"
        #expect(await source.existing(ids + [unknown]) == Set(ids))
        #expect(await source.existing([unknown]).isEmpty)
    }

    /// Adding a photo is heard through `changes()`. The photo is a favorite, and a favorite
    /// is never deleted: `delete` returns before PhotoKit would ask, so this can run without
    /// anyone to answer a prompt. The photo stays in the simulator's library, dated 2001 so
    /// it's outside the seed's dates; CI runs these tests after the UI tests for that reason.
    @Test func changesAreHeardAndAFavoriteIsNeverDeleted() async throws {
        let changes = source.changes()
        let id = try await Self.addPhoto(favorite: true, date: Date(timeIntervalSince1970: 978_350_400))

        #expect(await Self.first(of: changes, within: 20), "No change heard after adding a photo")
        #expect(await source.existing([id]) == [id])

        let deleted = await source.delete([id])
        #expect(deleted.isEmpty, "A favorite was deleted")
        #expect(await source.existing([id]) == [id])
    }

    // MARK: Helpers

    /// Whether `stream` yields within `seconds`.
    private static func first(of stream: AsyncStream<Void>, within seconds: Double) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in stream { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// Adds a small JPEG to the library and returns its local identifier.
    private static func addPhoto(favorite: Bool, date: Date) async throws -> String {
        let data = try #require(gradientJPEG(width: 640, height: 480))
        let created = Locked<String?>(nil)
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
            request.creationDate = date
            request.isFavorite = favorite
            created.value = request.placeholderForCreatedAsset?.localIdentifier
        }
        return try #require(created.value, "PhotoKit made no placeholder for the new photo")
    }

    private static func gradientJPEG(width: Int, height: Int) -> Data? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        let colors = [
            CGColor(srgbRed: 0.05, green: 0.45, blue: 0.45, alpha: 1),
            CGColor(srgbRed: 0.95, green: 0.85, blue: 0.6, alpha: 1),
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { return nil }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        guard let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
#endif

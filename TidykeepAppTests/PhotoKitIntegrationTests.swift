// PhotoKitSource against the real Photos framework, inside the app, on the seeded simulator.
//
// What a unit test can't do is confirm PhotoKit's own "Delete" prompt: only a person (or a
// UI test, through SpringBoard) can. EndToEndUITests covers deleting and merging; here the
// read side is checked, plus the calls the app relies on around a change: `existing(_:)`
// to tell which photos are still there, `changes()` to hear that something changed, and
// `undoMerge` to take a keeper back out of an album. Since the UI tests run first, this is
// also where the library is checked for what they removed.
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

    /// What the UI tests removed, checked in the library itself: every burst's sharp frame
    /// and every copy set's original is still there, and every seeded photo that's gone is
    /// one the app may offer to remove. Photos are matched by the name of the file
    /// `simctl addmedia` imported them from (PHAssetResource's originalFilename). The names
    /// found are printed to the log, so a name Photos changed on import is easy to tell
    /// from a photo removed by mistake.
    @Test(.enabled(if: TestEnvironment.seedKeepers != nil))
    func theUITestsRemovedOnlyExtras() throws {
        let names = try #require(TestEnvironment.seedNames, "TK_SEED_NAMES isn't set").map { $0.lowercased() }
        let keepers = try #require(TestEnvironment.seedKeepers).map { $0.lowercased() }
        let extras = Set(try #require(TestEnvironment.seedExtras, "TK_SEED_EXTRAS isn't set").map { $0.lowercased() })
        let found = Self.originalFilenames()
        let missing = names.filter { !found.contains($0) }
        let lostKeepers = keepers.filter { !found.contains($0) }
        let lostOthers = missing.filter { !extras.contains($0) }
        print("""
            theUITestsRemovedOnlyExtras: \(names.count - missing.count) of \(names.count) seeded photos found \
            by file name, among \(found.count) names in the library.
              Missing: \(missing.isEmpty ? "none" : missing.joined(separator: ", "))
              In the library: \(found.sorted().joined(separator: ", "))
            """)

        // None found at all means the names didn't map, not that everything was removed.
        try #require(
            missing.count < names.count,
            "No seeded file name in the library; Photos names them: \(found.sorted().prefix(8).joined(separator: ", "))"
        )
        #expect(lostKeepers.isEmpty, "Keepers gone from the library: \(lostKeepers.joined(separator: ", "))")
        #expect(lostOthers.isEmpty, "Gone but not extras: \(lostOthers.joined(separator: ", "))")
    }

    /// Undoing a merge takes the keeper back out of the album the merge added it to. The
    /// photo and album are this test's own: a favorite dated 2001, like the one above, and an
    /// album whose name nobody else has. Both stay in the simulator's library, since
    /// deleting either needs a person to confirm.
    @Test func undoingAMergeTakesTheKeeperOutOfItsAlbum() async throws {
        let id = try await Self.addPhoto(favorite: true, date: Date(timeIntervalSince1970: 978_350_400))
        let title = "TidykeepCI " + UUID().uuidString.prefix(8).lowercased()
        let albumID = try await Self.addAlbum(titled: title, holding: id)
        let before = await source.albums().first(where: { $0.id == albumID })
        try #require(before?.assetIDs.contains(id) == true, "The new album \"\(title)\" doesn't hold the new photo")

        // What a merge saves when it adds the keeper to an album, with nothing deleted.
        let outcome = MergeOutcome(keeperID: id, deletedIDs: [], albumIDsAdded: [albumID])
        #expect(await source.undoMerge([outcome]), "undoMerge reported a failure")

        let after = try #require(
            await source.albums().first(where: { $0.id == albumID }), "The album \"\(title)\" is gone after the undo"
        )
        #expect(!after.assetIDs.contains(id), "The photo is still in \"\(title)\" after the undo")
        #expect(await source.existing([id]) == [id], "The undo removed the photo itself")
    }

    // MARK: Helpers

    /// The name of the file each photo in the library came from, lowercased.
    private static func originalFilenames() -> Set<String> {
        let photos = PHAsset.fetchAssets(with: .image, options: nil)
        var names = Set<String>()
        for i in 0..<photos.count {
            let resources = PHAssetResource.assetResources(for: photos.object(at: i))
            // The original's resource, not an edit's.
            guard let original = resources.first(where: { $0.type == .photo }) ?? resources.first else { continue }
            names.insert(original.originalFilename.lowercased())
        }
        return names
    }

    /// Makes an album holding the photo `id` and returns the album's local identifier.
    private static func addAlbum(titled title: String, holding id: String) async throws -> String {
        let created = Locked<String?>(nil)
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            request.addAssets(PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil))
            created.value = request.placeholderForCreatedAssetCollection.localIdentifier
        }
        return try #require(created.value, "PhotoKit made no placeholder for the new album")
    }

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

import AVFoundation
import CoreGraphics
import Foundation
import TidykeepCore
import os
import Photos
import UniformTypeIdentifiers
#if canImport(UIKit)
import PhotosUI
import UIKit
#else
import AppKit
#endif

/// The user's photo library through PhotoKit.
///
/// Never downloads from iCloud (`isNetworkAccessAllowed = false`): photos whose full
/// image isn't on the device are skipped, and the app makes no network requests at all.
public final class PhotoKitSource: PhotoSource {
    private let manager = PHImageManager.default()
    /// Assets from the last fetch, so loading an image doesn't run a query per photo.
    private let assets = OSAllocatedUnfairLock(initialState: [String: PHAsset]())
    private let videos = OSAllocatedUnfairLock(initialState: [String: PHAsset]())
    private let monitor = OSAllocatedUnfairLock<ChangeMonitor?>(initialState: nil)

    public init() {}

    public func access() async -> LibraryAccess {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    public func requestAccess() async -> LibraryAccess {
        Self.map(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    public func fetchAssets(since: Date?) async throws -> [AssetMeta] {
        let options = Self.options(.image, since: since)
        options.includeAllBurstAssets = true
        let result = PHAsset.fetchAssets(with: options)
        var metas: [AssetMeta] = []
        var byID: [String: PHAsset] = [:]
        metas.reserveCapacity(result.count)
        for i in 0..<result.count {
            autoreleasepool {
                let asset = result.object(at: i)
                guard let created = asset.creationDate else { return }
                byID[asset.localIdentifier] = asset
                metas.append(AssetMeta(
                    id: asset.localIdentifier,
                    creationDate: created,
                    // The edit's date, so an edit or a revert checks the photo again. (The
                    // iOS 26 SDK has no adjustment timestamp.)
                    contentVersion: asset.hasAdjustments ? asset.modificationDate : nil,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight,
                    burstID: asset.burstIdentifier,
                    isFavorite: asset.isFavorite,
                    hasAdjustments: asset.hasAdjustments,
                    isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot)
                ))
            }
        }
        let snapshot = byID
        assets.withLock { $0 = snapshot }
        return metas
    }

    public func analysisImage(for id: String, maxPixelSize: Int) async throws -> CGImage {
        guard let asset = asset(id) else { throw PhotoSourceError.notFound }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        // `.fast` may return a bigger image than asked for; the analysis expects the long side
        // to be at most `maxPixelSize`, like `FolderPhotoSource`.
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = false
        options.version = .current
        return try await image(asset, size: CGSize(width: maxPixelSize, height: maxPixelSize), mode: .aspectFit, options: options)
    }

    /// Long side `pixelSize`, like the analysis image, so a photo that was analyzed can be shown.
    public func thumbnail(for id: String, pixelSize: Int) async -> CGImage? {
        guard let asset = asset(id) else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = false
        return try? await image(asset, size: CGSize(width: pixelSize, height: pixelSize), mode: .aspectFit, options: options)
    }

    public func delete(_ ids: [String]) async -> Set<String> {
        // The scan may be minutes old: a photo made a favorite or edited in Photos since then
        // is kept.
        let current = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var targets: [String] = []
        for i in 0..<current.count {
            let asset = current.object(at: i)
            if !asset.isFavorite && !asset.hasAdjustments { targets.append(asset.localIdentifier) }
        }
        guard !targets.isEmpty else { return [] }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(PHAsset.fetchAssets(withLocalIdentifiers: targets, options: nil))
            }
        } catch {
            // The user tapped Don't Allow, or the change failed. It's all or nothing, so nothing is gone.
            return []
        }
        let deleted = Set(targets)
        forget(deleted)
        return deleted
    }

    public func fetchVideos(since: Date?) async throws -> [VideoMeta] {
        let result = PHAsset.fetchAssets(with: Self.options(.video, since: since))
        var metas: [VideoMeta] = []
        var byID: [String: PHAsset] = [:]
        metas.reserveCapacity(result.count)
        for i in 0..<result.count {
            autoreleasepool {
                let asset = result.object(at: i)
                guard let created = asset.creationDate else { return }
                byID[asset.localIdentifier] = asset
                metas.append(VideoMeta(
                    id: asset.localIdentifier,
                    creationDate: created,
                    duration: asset.duration,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight,
                    isFavorite: asset.isFavorite,
                    hasAdjustments: asset.hasAdjustments
                ))
            }
        }
        let snapshot = byID
        videos.withLock { $0 = snapshot }
        return metas
    }

    public func albums() async -> [PhotoAlbum] {
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        var albums: [PhotoAlbum] = []
        for i in 0..<collections.count {
            autoreleasepool {
                let collection = collections.object(at: i)
                let members = PHAsset.fetchAssets(in: collection, options: nil)
                var ids = Set<String>()
                for j in 0..<members.count { ids.insert(members.object(at: j).localIdentifier) }
                albums.append(PhotoAlbum(
                    id: collection.localIdentifier,
                    title: collection.localizedTitle ?? "",
                    assetIDs: ids,
                    canAddPhotos: collection.canPerform(.addContent)
                ))
            }
        }
        return albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public func merge(_ sets: [CopyMerge]) async -> [MergeOutcome]? {
        let albums = await albums()
        var plans: [MergePlan] = []
        for set in sets {
            let all = PHAsset.fetchAssets(withLocalIdentifiers: [set.keeperID] + set.removeIDs, options: nil)
            var byID: [String: PHAsset] = [:]
            for i in 0..<all.count { byID[all.object(at: i).localIdentifier] = all.object(at: i) }
            guard let keeper = byID[set.keeperID] else { continue }
            // As in `delete`: a copy made a favorite or edited since the check is kept. So is a
            // copy in an album the keeper can't join, so that album keeps the photo.
            let unprotected = set.removeIDs.compactMap { byID[$0] }.filter { !$0.isFavorite && !$0.hasAdjustments }
            let merge = CopyMerge(keeperID: set.keeperID, removeIDs: unprotected.map(\.localIdentifier)).sparingAlbums(albums)
            let removing = merge.removeIDs.compactMap { byID[$0] }
            guard !removing.isEmpty else { continue }
            var outcome = MergeOutcome(keeperID: set.keeperID, deletedIDs: Set(merge.removeIDs))
            outcome.albumIDsAdded = merge.albumsToJoin(albums).map(\.id)
            plans.append(MergePlan(keeper: keeper, removing: removing, outcome: outcome))
        }
        guard !plans.isEmpty else { return nil }
        let collections = Self.collections(Set(plans.flatMap(\.outcome.albumIDsAdded)))
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for plan in plans {
                    for id in plan.outcome.albumIDsAdded {
                        guard let album = collections[id] else { continue }
                        PHAssetCollectionChangeRequest(for: album)?.addAssets([plan.keeper] as NSArray)
                    }
                    PHAssetChangeRequest.deleteAssets(plan.removing as NSArray)
                }
            }
        } catch {
            return nil
        }
        let deleted = Set(plans.flatMap(\.outcome.deletedIDs))
        forget(deleted)
        return plans.map(\.outcome)
    }

    public func undoMerge(_ outcomes: [MergeOutcome]) async -> Bool {
        let collections = Self.collections(Set(outcomes.flatMap(\.albumIDsAdded)))
        let keepers = PHAsset.fetchAssets(withLocalIdentifiers: outcomes.map(\.keeperID), options: nil)
        var byID: [String: PHAsset] = [:]
        for i in 0..<keepers.count { byID[keepers.object(at: i).localIdentifier] = keepers.object(at: i) }
        let work = outcomes.filter { byID[$0.keeperID] != nil && ($0.favoriteAdded || !$0.albumIDsAdded.isEmpty) }
        guard !work.isEmpty else { return true }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for outcome in work {
                    guard let keeper = byID[outcome.keeperID] else { continue }
                    if outcome.favoriteAdded { PHAssetChangeRequest(for: keeper).isFavorite = false }
                    for id in outcome.albumIDsAdded {
                        guard let album = collections[id] else { continue }
                        PHAssetCollectionChangeRequest(for: album)?.removeAssets([keeper] as NSArray)
                    }
                }
            }
            return true
        } catch {
            return false
        }
    }

    public func formats(for ids: [String]) async -> [String: String] {
        var formats: [String: String] = [:]
        for id in ids {
            guard let asset = asset(id) else { continue }
            let resources = PHAssetResource.assetResources(for: asset)
            let original = resources.first { $0.type == .photo } ?? resources.first
            guard let type = original.flatMap({ UTType($0.uniformTypeIdentifier) }) else { continue }
            formats[id] = Self.formatName(type)
        }
        return formats
    }

    public func coverage(since: Date?) async -> LibraryCoverage {
        var coverage = LibraryCoverage()
        if let since {
            let older = PHFetchOptions()
            older.predicate = NSPredicate(format: "mediaType == %d AND creationDate < %@", PHAssetMediaType.image.rawValue, since as NSDate)
            older.includeAssetSourceTypes = [.typeUserLibrary]
            coverage.outsideRange = PHAsset.fetchAssets(with: older).count
        }
        let shared = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumCloudShared, options: nil)
        for i in 0..<shared.count {
            coverage.inSharedAlbums += PHAsset.fetchAssets(in: shared.object(at: i), options: nil).count
        }
        return coverage
    }

    public func videoURL(for id: String) async -> URL? {
        guard let asset = asset(id), asset.mediaType == .video else { return nil }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false
        options.version = .current
        options.deliveryMode = .highQualityFormat
        return await withCheckedContinuation { continuation in
            manager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                // A slow-motion video comes back as a composition with no single file.
                continuation.resume(returning: (avAsset as? AVURLAsset)?.url)
            }
        }
    }

    public func existing(_ ids: [String]) async -> Set<String> {
        let found = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var present = Set<String>()
        for i in 0..<found.count { present.insert(found.object(at: i).localIdentifier) }
        return present
    }

    public func chooseMorePhotos() async {
        #if os(iOS)
        await Self.presentLimitedLibraryPicker()
        #endif
    }

    #if os(iOS)
    /// The app turns off iOS's own "Select More Photos" prompt
    /// (`PHPhotoLibraryPreventAutomaticLimitedAccessAlert`), so it offers this instead.
    @MainActor
    private static func presentLimitedLibraryPicker() async {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard var top = scene?.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        _ = await PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top)
    }
    #endif

    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let monitor = ChangeMonitor(continuation)
        PHPhotoLibrary.shared().register(monitor)
        self.monitor.withLock { old in
            if let old { PHPhotoLibrary.shared().unregisterChangeObserver(old) }
            old = monitor
        }
        return stream
    }

    // MARK: -

    private func asset(_ id: String) -> PHAsset? {
        if let cached = assets.withLock({ $0[id] }) ?? videos.withLock({ $0[id] }) { return cached }
        return PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    private func forget(_ ids: Set<String>) {
        assets.withLock { cache in ids.forEach { cache[$0] = nil } }
        videos.withLock { cache in ids.forEach { cache[$0] = nil } }
    }

    /// The user's own library, oldest first. Hidden items are left out by default.
    private static func options(_ type: PHAssetMediaType, since: Date?) -> PHFetchOptions {
        let options = PHFetchOptions()
        var predicates = [NSPredicate(format: "mediaType == %d", type.rawValue)]
        if let since {
            predicates.append(NSPredicate(format: "creationDate >= %@", since as NSDate))
        }
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.includeAssetSourceTypes = [.typeUserLibrary]
        return options
    }

    private static func collections(_ ids: Set<String>) -> [String: PHAssetCollection] {
        guard !ids.isEmpty else { return [:] }
        let found = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: Array(ids), options: nil)
        var byID: [String: PHAssetCollection] = [:]
        for i in 0..<found.count { byID[found.object(at: i).localIdentifier] = found.object(at: i) }
        return byID
    }

    static func formatName(_ type: UTType) -> String {
        if type.conforms(to: .heic) || type.conforms(to: .heif) { return "HEIC" }
        if type.conforms(to: .jpeg) { return "JPEG" }
        if type.conforms(to: .png) { return "PNG" }
        if type.conforms(to: .rawImage) { return "RAW" }
        return type.preferredFilenameExtension?.uppercased() ?? "Other"
    }

    private func image(_ asset: PHAsset, size: CGSize, mode: PHImageContentMode, options: PHImageRequestOptions) async throws -> CGImage {
        let delivered: Delivered = try await withCheckedThrowingContinuation { continuation in
            // `.highQualityFormat` calls the handler exactly once, on the main thread.
            manager.requestImage(for: asset, targetSize: size, contentMode: mode, options: options) { image, info in
                if let image {
                    continuation.resume(returning: Delivered(image: image))
                } else if (info?[PHImageResultIsInCloudKey] as? Bool) == true {
                    continuation.resume(throwing: PhotoSourceError.notAvailableLocally)
                } else {
                    continuation.resume(throwing: PhotoSourceError.unreadable)
                }
            }
        }
        // Redrawn here, off the main thread: most iPhone photos aren't stored upright.
        guard let upright = delivered.image.uprightCGImage() else { throw PhotoSourceError.unreadable }
        return upright
    }

    private static func map(_ status: PHAuthorizationStatus) -> LibraryAccess {
        switch status {
        case .authorized: .full
        case .limited: .limited
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }
}

/// One set's change, worked out before PhotoKit is asked, so the change block only writes.
private struct MergePlan: @unchecked Sendable {
    let keeper: PHAsset
    let removing: [PHAsset]
    let outcome: MergeOutcome
}

/// Carries PhotoKit's image out of its main-thread callback. It's not touched there again.
private struct Delivered: @unchecked Sendable {
    #if canImport(UIKit)
    let image: UIImage
    #else
    let image: NSImage
    #endif
}

private final class ChangeMonitor: NSObject, PHPhotoLibraryChangeObserver, Sendable {
    let continuation: AsyncStream<Void>.Continuation

    init(_ continuation: AsyncStream<Void>.Continuation) {
        self.continuation = continuation
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        continuation.yield()
    }
}

#if canImport(UIKit)
extension UIImage {
    /// PhotoKit images can carry an EXIF orientation; Vision and SwiftUI get pixels already upright.
    func uprightCGImage() -> CGImage? {
        if imageOrientation == .up, let cgImage { return cgImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        format.preferredRange = .standard  // 8 bits per channel, not wide color at twice the memory
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }
}
#else
extension NSImage {
    func uprightCGImage() -> CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
#endif

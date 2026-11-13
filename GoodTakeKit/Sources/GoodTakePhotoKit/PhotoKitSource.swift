import CoreGraphics
import Foundation
import GoodTakeCore
import os
import Photos
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
    private let monitor = OSAllocatedUnfairLock<ChangeMonitor?>(initialState: nil)

    public init() {}

    public func access() async -> LibraryAccess {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    public func requestAccess() async -> LibraryAccess {
        Self.map(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    public func fetchAssets(since: Date?) async throws -> [AssetMeta] {
        let options = PHFetchOptions()
        var predicates = [
            NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue),
            NSPredicate(format: "(mediaSubtypes & %d) == 0", PHAssetMediaSubtype.photoScreenshot.rawValue),
        ]
        if let since {
            predicates.append(NSPredicate(format: "creationDate >= %@", since as NSDate))
        }
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.includeAllBurstAssets = true
        options.includeAssetSourceTypes = [.typeUserLibrary]

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
                    contentVersion: asset.adjustmentTimestamp,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight,
                    burstID: asset.burstIdentifier,
                    isFavorite: asset.isFavorite,
                    hasAdjustments: asset.hasAdjustments
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
        assets.withLock { cache in deleted.forEach { cache[$0] = nil } }
        return deleted
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
        if let cached = assets.withLock({ $0[id] }) { return cached }
        return PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
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

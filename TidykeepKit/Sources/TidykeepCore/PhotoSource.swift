import CoreGraphics
import Foundation

/// A photo library: PhotoKit in the app, a folder of files in the CLI and tests.
public protocol PhotoSource: Sendable {
    func access() async -> LibraryAccess
    func requestAccess() async -> LibraryAccess
    /// Still photos taken on or after `since`, screenshots excluded, burst frames included.
    func fetchAssets(since: Date?) async throws -> [AssetMeta]
    /// An upright image no larger than `maxPixelSize` on its long edge, for analysis.
    func analysisImage(for id: String, maxPixelSize: Int) async throws -> CGImage
    /// An upright image for display, or nil if it isn't available on the device.
    func thumbnail(for id: String, pixelSize: Int) async -> CGImage?
    /// Deletes photos (PhotoKit asks the user to confirm) and returns the IDs actually deleted.
    /// Looks at each photo again first and leaves out any made a favorite or edited since the scan.
    func delete(_ ids: [String]) async -> Set<String>
    /// Which of these photos are still in the library.
    func existing(_ ids: [String]) async -> Set<String>
    /// Fires when the library changes outside the app.
    func changes() -> AsyncStream<Void>
    /// With limited access, lets the user change which photos the app can see.
    func chooseMorePhotos() async
}

extension PhotoSource {
    public func existing(_ ids: [String]) async -> Set<String> { Set(ids) }
    public func chooseMorePhotos() async {}
}

public enum PhotoSourceError: Error, Equatable {
    case notFound
    /// The full photo is only in iCloud and the app never downloads.
    case notAvailableLocally
    case unreadable
}

/// Turns one image into `FrameSignals`.
public protocol FrameAnalyzing: Sendable {
    /// Changes whenever results would change, e.g. a new Vision request revision.
    var version: String { get }
    func analyze(_ image: CGImage) async throws -> FrameSignals
}

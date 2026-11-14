import CoreGraphics
import Foundation

/// A photo library: PhotoKit in the app, a folder of files in the CLI and tests.
public protocol PhotoSource: Sendable {
    func access() async -> LibraryAccess
    func requestAccess() async -> LibraryAccess
    /// Still photos taken on or after `since`, screenshots included (marked `isScreenshot`),
    /// burst frames included, hidden photos left out.
    func fetchAssets(since: Date?) async throws -> [AssetMeta]
    /// An upright image no larger than `maxPixelSize` on its long edge, for analysis.
    func analysisImage(for id: String, maxPixelSize: Int) async throws -> CGImage
    /// An upright image for display, or nil if it isn't available on the device.
    func thumbnail(for id: String, pixelSize: Int) async -> CGImage?
    /// Deletes photos or videos (PhotoKit asks the user to confirm) and returns the IDs actually
    /// deleted. Looks at each one again first and leaves out any made a favorite or edited since
    /// the scan.
    func delete(_ ids: [String]) async -> Set<String>
    /// Which of these photos are still in the library.
    func existing(_ ids: [String]) async -> Set<String>
    /// Fires when the library changes outside the app.
    func changes() -> AsyncStream<Void>
    /// With limited access, lets the user change which photos the app can see.
    func chooseMorePhotos() async

    /// Videos taken on or after `since`, hidden ones left out.
    func fetchVideos(since: Date?) async throws -> [VideoMeta]
    /// The user's own albums with what is in them, for "Always keep" and the copy merge.
    func albums() async -> [PhotoAlbum]
    /// Merges copy sets in one change, so PhotoKit asks once: each keeper joins every album a
    /// removed copy was in, then the copies are deleted. Favorites and edited copies are never
    /// deleted, and neither is a copy in an album the keeper can't join (`CopyMerge.sparingAlbums`).
    /// Favorites, dates and places are never written. Nil when nothing changed (the user said
    /// no, or the change failed: PhotoKit applies all of it or none).
    func merge(_ sets: [CopyMerge]) async -> [MergeOutcome]?
    /// Takes the keepers back out of the albums `merge` added them to. The deleted copies stay
    /// in Recently Deleted.
    func undoMerge(_ outcomes: [MergeOutcome]) async -> Bool
    /// File formats ("HEIC", "JPEG", "PNG") for a few photos, such as the members of a copy set.
    func formats(for ids: [String]) async -> [String: String]
    /// Counts for the Coverage sheet that only the library knows.
    func coverage(since: Date?) async -> LibraryCoverage
    /// A file the system player can open, or nil when the video is only in iCloud.
    func videoURL(for id: String) async -> URL?
}

extension PhotoSource {
    public func existing(_ ids: [String]) async -> Set<String> { Set(ids) }
    public func chooseMorePhotos() async {}
    public func fetchVideos(since: Date?) async throws -> [VideoMeta] { [] }
    public func albums() async -> [PhotoAlbum] { [] }
    public func merge(_ sets: [CopyMerge]) async -> [MergeOutcome]? {
        let deleted = await delete(sets.flatMap(\.removeIDs))
        guard !deleted.isEmpty else { return nil }
        return sets.map { MergeOutcome(keeperID: $0.keeperID, deletedIDs: deleted.intersection($0.removeIDs)) }
    }
    public func undoMerge(_ outcomes: [MergeOutcome]) async -> Bool { true }
    public func formats(for ids: [String]) async -> [String: String] { [:] }
    public func coverage(since: Date?) async -> LibraryCoverage { LibraryCoverage() }
    public func videoURL(for id: String) async -> URL? { nil }
}

/// A video, for Big Videos. Videos are never analyzed, only listed.
public struct VideoMeta: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let creationDate: Date
    public let duration: TimeInterval
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let isFavorite: Bool
    public let hasAdjustments: Bool

    public init(id: String, creationDate: Date, duration: TimeInterval, pixelWidth: Int, pixelHeight: Int, isFavorite: Bool = false, hasAdjustments: Bool = false) {
        self.id = id
        self.creationDate = creationDate
        self.duration = duration
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isFavorite = isFavorite
        self.hasAdjustments = hasAdjustments
    }

    public var isProtected: Bool { isFavorite || hasAdjustments }

    /// How much room it likely takes, for sorting only. iOS 26 has no public way to read a
    /// video's size, and Tidykeep never shows a guess as a number.
    public var weight: Double { duration * Double(pixelWidth) * Double(pixelHeight) }
}

/// One of the user's albums.
public struct PhotoAlbum: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let assetIDs: Set<String>
    /// False for albums PhotoKit won't let the app add to, such as some synced ones.
    public let canAddPhotos: Bool

    public init(id: String, title: String, assetIDs: Set<String>, canAddPhotos: Bool = true) {
        self.id = id
        self.title = title
        self.assetIDs = assetIDs
        self.canAddPhotos = canAddPhotos
    }
}

/// One copy set to merge: keep `keeperID`, remove the rest.
public struct CopyMerge: Sendable, Hashable, Codable {
    public let keeperID: String
    public let removeIDs: [String]

    public init(keeperID: String, removeIDs: [String]) {
        self.keeperID = keeperID
        self.removeIDs = removeIDs
    }
}

extension CopyMerge {
    /// This merge without the copies that have to stay. A copy in an album the keeper isn't in
    /// and can't be added to (PhotoKit won't add to some synced albums) is kept, as a favorite
    /// is, so that album never loses the photo and the keeper ends up in every album the
    /// removed copies were in.
    public func sparingAlbums(_ albums: [PhotoAlbum]) -> CopyMerge {
        let closed = albums.filter { !$0.canAddPhotos && !$0.assetIDs.contains(keeperID) }
        return CopyMerge(keeperID: keeperID, removeIDs: removeIDs.filter { id in !closed.contains { $0.assetIDs.contains(id) } })
    }

    /// The albums the keeper joins: each one a removed copy is in and the keeper isn't.
    public func albumsToJoin(_ albums: [PhotoAlbum]) -> [PhotoAlbum] {
        let removing = Set(removeIDs)
        return albums.filter { !$0.assetIDs.contains(keeperID) && !$0.assetIDs.isDisjoint(with: removing) }
    }
}

/// What a merge did to one set, kept in its receipt so it can be taken back.
public struct MergeOutcome: Sendable, Hashable, Codable {
    public var keeperID: String
    public var deletedIDs: Set<String>
    /// The keeper was made a favorite because a copy was one. A merge never sets it: a
    /// favorite copy is never removed, so there is no favorite to move.
    public var favoriteAdded = false
    /// Albums the keeper was added to.
    public var albumIDsAdded: [String] = []
    /// Albums the keeper couldn't be added to, by title. A merge leaves it empty: a copy in
    /// such an album isn't removed (`CopyMerge.sparingAlbums`).
    public var albumsSkipped: [String] = []

    public init(keeperID: String, deletedIDs: Set<String>, favoriteAdded: Bool = false, albumIDsAdded: [String] = [], albumsSkipped: [String] = []) {
        self.keeperID = keeperID
        self.deletedIDs = deletedIDs
        self.favoriteAdded = favoriteAdded
        self.albumIDsAdded = albumIDsAdded
        self.albumsSkipped = albumsSkipped
    }
}

/// Photos the check never looks at, counted by the library.
public struct LibraryCoverage: Sendable, Hashable {
    /// Photos older than the chosen range.
    public var outsideRange = 0
    /// Photos in Shared Albums, which belong to whoever shared them.
    public var inSharedAlbums = 0

    public init(outsideRange: Int = 0, inSharedAlbums: Int = 0) {
        self.outsideRange = outsideRange
        self.inSharedAlbums = inSharedAlbums
    }
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

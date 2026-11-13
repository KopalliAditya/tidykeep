import Foundation

/// A folder the user chose with the system folder picker, remembered across launches.
///
/// The picker hands out a URL that only works until the app quits. The bookmark is what lets the
/// app open the same folder next time without asking again. The id stays the same when the
/// bookmark is refreshed, so files and held items can keep pointing at their folder.
public struct FolderRef: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    /// The folder's name as the Files app shows it, such as "Downloads".
    public var displayName: String
    /// Security-scoped bookmark data from `FolderAccess`.
    public var bookmark: Data

    public init(id: UUID = UUID(), displayName: String, bookmark: Data) {
        self.id = id
        self.displayName = displayName
        self.bookmark = bookmark
    }
}

/// Turns picked folders into bookmarks and back, and opens their security scope.
///
/// Every read or move inside a chosen folder must happen while its scope is open. Opening is
/// counted by the system, so nesting `withAccess` calls for the same folder is fine.
public enum FolderAccess: Sendable {
    /// Makes a bookmark for a folder the picker just returned.
    public static func makeRef(for url: URL) throws -> FolderRef {
        try withAccess(to: url) {
            FolderRef(displayName: FileFacts.displayName(of: url), bookmark: try bookmark(for: url))
        }
    }

    /// A new bookmark for the same folder, keeping its id. Call it when `resolve` says the
    /// bookmark is stale (the folder was renamed or moved), while the resolved URL still works.
    public static func refreshed(_ ref: FolderRef, url: URL) throws -> FolderRef {
        try withAccess(to: url) {
            FolderRef(id: ref.id, displayName: FileFacts.displayName(of: url), bookmark: try bookmark(for: url))
        }
    }

    /// The folder's current URL. When `isStale` is true the URL works now, but the caller should
    /// save `refreshed(_:url:)` so it keeps working.
    ///
    /// Throws `FilesError.folderUnavailable` when the folder is gone or no longer allowed, so
    /// the user can be asked to choose it again.
    public static func resolve(_ ref: FolderRef) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: ref.bookmark,
                options: resolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return (url, isStale)
        } catch {
            throw FilesError.folderUnavailable(name: ref.displayName)
        }
    }

    /// Runs `body` with the folder's security scope open. A plain URL (one that isn't
    /// security-scoped, as in tests) just runs the body.
    public static func withAccess<T>(to url: URL, _ body: () throws -> T) rethrows -> T {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    /// Runs async work with several folders open at once. The finders read files by path, so
    /// the app wraps a whole check (scan, then hashing) in this.
    public static func withAccess<T>(
        to urls: [URL],
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let started = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { for url in started { url.stopAccessingSecurityScopedResource() } }
        return try await body()
    }

    // macOS needs the security-scope flag for a bookmark to reopen a sandboxed folder. On iOS
    // the picker's URL already carries the scope, and a minimal bookmark is what Apple asks for.
    #if os(macOS)
    private static let creationOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let resolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    private static let creationOptions: URL.BookmarkCreationOptions = [.minimalBookmark]
    private static let resolutionOptions: URL.BookmarkResolutionOptions = []
    #endif

    private static func bookmark(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(options: creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            throw FilesError.unreadable(path: FileFacts.path(of: url))
        }
    }
}

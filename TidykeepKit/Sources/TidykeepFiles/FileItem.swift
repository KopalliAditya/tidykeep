import Foundation

/// One file found in a chosen folder.
public struct FileItem: Codable, Hashable, Identifiable, Sendable {
    /// The standardized path ("." and ".." removed; "/private" kept, unlike
    /// `standardizedFileURL`, whose answer depends on whether the file still exists). The
    /// scanner builds it from the folder's real path, so overlapping folders give one id.
    public let id: String
    public let url: URL
    public let name: String
    /// Space on disk (`totalFileAllocatedSize`, or the length when that's unknown): the size the
    /// app shows for the file, and the one Large Files sorts by.
    ///
    /// It isn't always what deleting the file gives back. An APFS clone shares its blocks with
    /// the file it was copied from, so both show the full size; see `unsharedBytes`.
    public let bytes: Int64
    /// The part of `bytes` only this file uses, which is what deleting it alone gives back.
    /// Equal to `bytes` for a file that has never shared blocks with a clone. Space claims
    /// ("in extra copies", "is free again") add up this, never `bytes`.
    public let unsharedBytes: Int64
    /// The content length (`fileSize`). Duplicates are grouped by this: two copies have the same
    /// length even when they take up different space on disk.
    public let logicalBytes: Int64
    public let modified: Date
    public let created: Date?
    /// The `FolderRef` it was found through.
    public let folderID: UUID
    /// Path inside that folder, such as "Trips/2024/map.pdf".
    public let relativePath: String
    /// Device and inode. Hard links share one, so they count as one file: removing a link
    /// gives no space back.
    public let identity: FileIdentity?

    public init(
        url: URL,
        bytes: Int64,
        logicalBytes: Int64? = nil,
        unsharedBytes: Int64? = nil,
        modified: Date,
        created: Date? = nil,
        folderID: UUID,
        relativePath: String,
        identity: FileIdentity? = nil
    ) {
        self.url = url
        self.id = FileFacts.path(of: url.standardized)
        self.name = url.lastPathComponent
        self.bytes = bytes
        self.logicalBytes = logicalBytes ?? bytes
        self.unsharedBytes = unsharedBytes ?? bytes
        self.modified = modified
        self.created = created
        self.folderID = folderID
        self.relativePath = relativePath
        self.identity = identity
    }

    /// The folders between the chosen folder and the file, such as "Trips/2024". Empty for a
    /// file at the top.
    public var parentPath: String {
        let parts = relativePath.split(separator: "/")
        return parts.dropLast().joined(separator: "/")
    }
}

/// Which file on which volume, independent of its name.
public struct FileIdentity: Codable, Hashable, Sendable {
    public let device: Int64
    public let inode: UInt64

    public init(device: Int64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

/// Why a file wasn't checked. These feed the Coverage sheet, so the user can see what was left out.
///
/// `CodingKeyRepresentable` makes `FileInventory.skipped` save as a plain JSON object
/// (`{"iCloudOnly": 3}`) rather than a list of alternating keys and counts.
public enum FileSkipReason: String, Codable, CaseIterable, CodingKeyRepresentable, Sendable {
    /// Its content is only in iCloud. Checking it would download it, which the app never does.
    case iCloudOnly
    /// The system wouldn't let the app read it, or it vanished or changed during the check.
    case unreadable
}

/// What one check of the chosen folders found.
public struct FileInventory: Codable, Hashable, Sendable {
    public var items: [FileItem]
    /// Files left out, by reason. Reasons with nothing skipped are absent.
    public var skipped: [FileSkipReason: Int]
    /// Chosen folders (`FolderRef.id`) that couldn't be opened at all, in the order given. An
    /// unopenable folder looks the same as an empty one, so the UI must say so ("Can't open
    /// Downloads anymore") and offer to choose it again, never "All tidy".
    public var unavailableFolderIDs: [UUID]

    public init(items: [FileItem] = [], skipped: [FileSkipReason: Int] = [:], unavailableFolderIDs: [UUID] = []) {
        self.items = items
        self.skipped = skipped
        self.unavailableFolderIDs = unavailableFolderIDs
    }

    /// Files checked, for "Checked 2,814 files".
    public var checkedCount: Int { items.count }

    /// Files left out, for "· 212 skipped".
    public var skippedCount: Int { skipped.values.reduce(0, +) }
}

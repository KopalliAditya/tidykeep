import Foundation

/// A file the user moved to "Held by Tidykeep", and where it came from.
public struct HoldingItem: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    /// The file's name before it was held. The held copy may be "name 2" after a clash.
    public let name: String
    /// The chosen folder it lives in. Both paths below are inside that folder.
    public let folderID: UUID
    /// Where Put back returns it, such as "Trips/2024/map.pdf".
    public let originalRelativePath: String
    /// Where it is now, such as "Held by Tidykeep/map.pdf".
    public let heldRelativePath: String
    /// Space deleting it gives back, read when it was held (`FileItem.unsharedBytes`), for
    /// "3 files · 1.2 GB" and "1.2 GB is free again".
    public let bytes: Int64
    public let movedAt: Date
    /// What the held file looked like right after the move: which file it is on disk (a rename
    /// keeps that), its length and its modification date. Put back, delete and reconcile act only
    /// on a file that still matches, so another file the user drops in under the same name is
    /// left alone. Nil in a row made without them, which can't be checked.
    public let heldIdentity: FileIdentity?
    public let heldLength: Int64?
    public let heldModified: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        folderID: UUID,
        originalRelativePath: String,
        heldRelativePath: String,
        bytes: Int64,
        movedAt: Date,
        heldIdentity: FileIdentity? = nil,
        heldLength: Int64? = nil,
        heldModified: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.folderID = folderID
        self.originalRelativePath = originalRelativePath
        self.heldRelativePath = heldRelativePath
        self.bytes = bytes
        self.movedAt = movedAt
        self.heldIdentity = heldIdentity
        self.heldLength = heldLength
        self.heldModified = heldModified
    }

    /// The folder it came from inside the chosen folder, such as "Trips/2024". Empty for the top.
    public var originalFolderPath: String {
        originalRelativePath.split(separator: "/").dropLast().joined(separator: "/")
    }

    /// The same row with the held file's identity as read after the move. Some volumes (FAT
    /// drives) number a file by where its entry sits, so a rename can change it.
    func withHeldIdentity(_ identity: FileIdentity) -> HoldingItem {
        HoldingItem(
            id: id, name: name, folderID: folderID, originalRelativePath: originalRelativePath,
            heldRelativePath: heldRelativePath, bytes: bytes, movedAt: movedAt,
            heldIdentity: identity, heldLength: heldLength, heldModified: heldModified
        )
    }
}

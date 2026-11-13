import Foundation

/// Files with the same content, byte for byte. One is kept; the rest are extra copies.
public struct DuplicateFileSet: Codable, Hashable, Identifiable, Sendable {
    /// The SHA-256 of the content, in hex. It names the content, not the copies, so it stays
    /// the same across checks while the content does.
    public let id: String
    /// Every copy, the suggested keeper first, then in keeping order.
    public let items: [FileItem]
    public let keeperID: String
    /// Space that moving the copies other than the keeper out (and emptying Holding) gives
    /// back: their `unsharedBytes`. A clone of the keeper shares its blocks and adds next to
    /// nothing, so this can be far less than the copies' sizes; it never claims more than the
    /// disk will free.
    public let extraBytes: Int64

    /// A set keeping `keeperID`, which must be one of `items`.
    public init(id: String, items: [FileItem], keeperID: String) {
        self.id = id
        self.items = items
        self.keeperID = keeperID
        self.extraBytes = items.filter { $0.id != keeperID }.reduce(0) { $0 + $1.unsharedBytes }
    }

    public var keeper: FileItem? { items.first { $0.id == keeperID } }

    /// The copies the set suggests moving to Holding.
    public var extras: [FileItem] { items.filter { $0.id != keeperID } }

    /// The same set keeping a copy the user picked. Ignored when the id isn't in the set.
    public func keeping(_ id: String) -> DuplicateFileSet {
        guard items.contains(where: { $0.id == id }) else { return self }
        return DuplicateFileSet(id: self.id, items: items, keeperID: id)
    }
}

/// What one duplicate check found.
public struct DuplicateFileReport: Codable, Hashable, Sendable {
    /// Sets of two or more copies, the most extra space first.
    public var sets: [DuplicateFileSet]
    /// Files that couldn't be compared, by reason, for the Coverage sheet. A copy among them
    /// is in no set. Reasons with nothing skipped are absent.
    public var skipped: [FileSkipReason: Int]

    public init(sets: [DuplicateFileSet] = [], skipped: [FileSkipReason: Int] = [:]) {
        self.sets = sets
        self.skipped = skipped
    }

    /// Files left out, for "· 3 skipped".
    public var skippedCount: Int { skipped.values.reduce(0, +) }
}

import Foundation

/// What Tidykeep never suggests removing, beyond the rules that always apply: favorites and
/// edited photos are always kept, hidden photos are never looked at, and My Card is only ever
/// the card that stays.
///
/// A rule change applies to what's on screen straight away; nothing is removed because of one.
public struct ProtectionRules: Sendable, Hashable, Codable {
    /// Albums the user chose: every photo in them is kept.
    public var albumIDs: Set<String>
    /// Screenshots the user filed into an album were worth keeping once.
    public var keepScreenshotsInAlbums: Bool
    /// Files changed this recently are hidden from Large Files and Duplicate Files: they are
    /// probably still in use. Nil shows everything.
    public var hideFilesChangedWithinDays: Int?

    public init(albumIDs: Set<String> = [], keepScreenshotsInAlbums: Bool = true, hideFilesChangedWithinDays: Int? = 7) {
        self.albumIDs = albumIDs
        self.keepScreenshotsInAlbums = keepScreenshotsInAlbums
        self.hideFilesChangedWithinDays = hideFilesChangedWithinDays
    }

    /// Missing fields get their defaults, so rules saved by an older version still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        albumIDs = try c.decodeIfPresent(Set<String>.self, forKey: .albumIDs) ?? []
        keepScreenshotsInAlbums = try c.decodeIfPresent(Bool.self, forKey: .keepScreenshotsInAlbums) ?? true
        hideFilesChangedWithinDays = try c.decodeIfPresent(Int.self, forKey: .hideFilesChangedWithinDays) ?? 7
    }

    private enum CodingKeys: String, CodingKey {
        case albumIDs, keepScreenshotsInAlbums, hideFilesChangedWithinDays
    }
}

/// Why something wasn't looked at or offered. The same five reasons everywhere, so people
/// learn them (the Coverage sheet lists them).
public enum SkipReason: String, Sendable, Codable, CaseIterable, Identifiable {
    /// Only in iCloud. Tidykeep never downloads.
    case iCloudOnly
    case unreadable
    /// In a shared album: not the user's to remove.
    case sharedAlbum
    /// Outside the date range or size threshold the user chose.
    case outsideRange
    /// Kept safe by a protection rule.
    case keptByRule

    public var id: String { rawValue }
}

/// What one check looked at: how many items, and how many it skipped and why.
public struct Coverage: Sendable, Hashable, Codable {
    public var checked: Int
    public var skipped: [SkipReason: Int]

    public init(checked: Int = 0, skipped: [SkipReason: Int] = [:]) {
        self.checked = checked
        self.skipped = skipped
    }

    public var totalSkipped: Int { skipped.values.reduce(0, +) }

    public mutating func skip(_ reason: SkipReason, _ count: Int = 1) {
        guard count > 0 else { return }
        skipped[reason, default: 0] += count
    }
}

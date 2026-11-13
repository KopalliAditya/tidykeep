import Foundation

/// Which photos the user keeps. By default a group keeps its keeper plus any protected
/// photos (favorites, edits, documents) and suggests removing the rest. The user's changes are
/// stored per photo, so they survive a rescan that reshapes the groups.
public struct ReviewDecisions: Sendable, Hashable, Codable {
    /// Photo ID → keep it?
    public private(set) var overrides: [String: Bool] = [:]

    public init() {}

    public func keeps(_ id: String, in group: PhotoGroup) -> Bool {
        let kept = keptIDs(in: group)
        return kept.contains(id)
    }

    public func keptIDs(in group: PhotoGroup) -> Set<String> {
        var kept = Set(group.members.filter { member in
            group.isProtected(member.id) || (overrides[member.id] ?? (member.id == group.keeper.id))
        }.map(\.id))
        // A group always keeps at least one photo, whatever the overrides say.
        if kept.isEmpty { kept.insert(group.keeper.id) }
        return kept
    }

    /// Suggested removals, best-ranked first.
    public func removals(in group: PhotoGroup) -> [AssetMeta] {
        let kept = keptIDs(in: group)
        return group.members.filter { !kept.contains($0.id) }
    }

    public enum Refusal: Error, Equatable {
        /// Favorites, edited photos and documents are never removed from here.
        case protected
        /// Every group keeps at least one photo.
        case lastKept
    }

    /// Marks a photo kept or removed. Returns the reason when the change isn't allowed.
    @discardableResult
    public mutating func setKeep(_ keep: Bool, _ id: String, in group: PhotoGroup) -> Refusal? {
        guard let member = group.member(id) else { return nil }
        if !keep {
            if group.isProtected(member.id) { return .protected }
            let kept = keptIDs(in: group)
            if kept == [id] { return .lastKept }
        }
        overrides[id] = keep
        return nil
    }

    /// Keeps this one photo (plus protected ones) and removes the others.
    public mutating func keepOnly(_ id: String, in group: PhotoGroup) {
        for member in group.members {
            overrides[member.id] = member.id == id
        }
    }

    /// Marks photos kept, such as what's left of a group after the rest were removed, so a
    /// later scan that groups them differently doesn't suggest removing them.
    public mutating func pin(_ ids: some Sequence<String>) {
        for id in ids { overrides[id] = true }
    }

    /// Forgets choices for photos that no longer exist.
    public mutating func forget(_ ids: some Sequence<String>) {
        for id in ids { overrides[id] = nil }
    }
}

/// What persists between launches besides the analysis cache.
public struct ReviewLedger: Sendable, Hashable, Codable {
    /// Groups the user chose to keep whole ("Keep all"). A group with a new photo has a
    /// new fingerprint, so it comes back.
    public var dismissedGroups: Set<String> = []
    public var decisions = ReviewDecisions()
    /// Shown in Settings. Never leaves the device.
    public var photosRemoved = 0
    public var lastScan: Date?
    /// Videos the user chose to keep from Big Videos. They aren't listed again.
    public var keptVideoIDs: Set<String> = []

    public init() {}

    /// Missing fields get their defaults, so a file from an older version still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dismissedGroups = try c.decodeIfPresent(Set<String>.self, forKey: .dismissedGroups) ?? []
        decisions = try c.decodeIfPresent(ReviewDecisions.self, forKey: .decisions) ?? ReviewDecisions()
        photosRemoved = try c.decodeIfPresent(Int.self, forKey: .photosRemoved) ?? 0
        lastScan = try c.decodeIfPresent(Date.self, forKey: .lastScan)
        keptVideoIDs = try c.decodeIfPresent(Set<String>.self, forKey: .keptVideoIDs) ?? []
    }
}

import Foundation

/// Photos of one moment, or copies of one picture, best first.
public struct PhotoGroup: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable, Hashable {
        /// A series, or near-identical frames of one moment. Ranked by `ShotScorer`.
        case similar
        /// Copies of one picture spread over time: re-saves, edits saved as new photos,
        /// screenshots of it. Ordered by `LibraryGroups.keepsBefore`.
        case copies
    }

    /// Stable across launches for the same set of photos (see `Fingerprint`).
    public let id: String
    public let kind: Kind
    /// Best first.
    public let members: [AssetMeta]
    public let ranking: Ranking
    /// Members Vision judges document-like: receipts, pages, screenshots. Shots of different
    /// pages look alike to the feature print, so these are never offered for removal.
    public let documentIDs: Set<String>
    /// Members the user's rules keep, such as photos in an album they protect.
    public private(set) var ruleIDs: Set<String> = []

    public init(members: [(meta: AssetMeta, signals: FrameSignals)]) {
        let ranking = ShotScorer.rank(members)
        let byID = Dictionary(uniqueKeysWithValues: members.map { ($0.meta.id, $0.meta) })
        self.id = Fingerprint.of(members.map(\.meta.id))
        self.kind = .similar
        self.ranking = ranking
        self.members = ranking.orderedIDs.compactMap { byID[$0] }
        self.documentIDs = Set(members.filter(\.signals.isUtility).map(\.meta.id))
    }

    /// A copy set, keeper first, in the order given (`LibraryGroups.keepsBefore`). The scores
    /// are still worked out so the detail screen can say how the copies differ, but they
    /// don't change the order: for copies, detail and the user's own marks decide.
    public init(copies members: [(meta: AssetMeta, signals: FrameSignals)]) {
        let scores = Dictionary(uniqueKeysWithValues: ShotScorer.rank(members).scores.map { ($0.id, $0) })
        self.id = Fingerprint.of(members.map(\.meta.id))
        self.kind = .copies
        self.members = members.map(\.meta)
        self.ranking = Ranking(
            scores: members.compactMap { scores[$0.meta.id] },
            keeperID: members.first?.meta.id ?? "",
            reasons: [],
            isCloseCall: false
        )
        self.documentIDs = Set(members.filter(\.signals.isUtility).map(\.meta.id))
    }

    /// The same group with the user's rules applied: `kept` are photos the rules always keep.
    public func applying(keptByRules kept: Set<String>) -> PhotoGroup {
        var group = self
        group.ruleIDs = Set(members.map(\.id)).intersection(kept)
        return group
    }

    public var keeper: AssetMeta { members[0] }
    public var startDate: Date { members.map(\.creationDate).min() ?? keeper.creationDate }

    public func member(_ id: String) -> AssetMeta? { members.first { $0.id == id } }

    /// Always kept: a favorite, an edited photo, a document, or kept by the user's rules.
    public func isProtected(_ id: String) -> Bool {
        documentIDs.contains(id) || ruleIDs.contains(id) || member(id)?.isProtected == true
    }

    /// Nothing here could be removed, so there's nothing to review.
    public var isFullyProtected: Bool { members.allSatisfy { isProtected($0.id) } }

    /// Something besides the keeper could go. A group where every other photo is always kept
    /// would only ever say "keep all", so it isn't shown.
    public var hasSuggestions: Bool { members.dropFirst().contains { !isProtected($0.id) } }

    /// The second-best photo when the top two are too close to call.
    public var runnerUp: AssetMeta? { ranking.isCloseCall && members.count > 1 ? members[1] : nil }

    /// Members in the order they were taken, the order the review screen shows them in.
    public var inCaptureOrder: [AssetMeta] {
        members.sorted { $0.creationDate != $1.creationDate ? $0.creationDate < $1.creationDate : $0.id < $1.id }
    }

    /// Position in capture order, 1-based, for VoiceOver ("photo 3 of 6").
    public func captureIndex(of id: String) -> Int? {
        inCaptureOrder.firstIndex { $0.id == id }.map { $0 + 1 }
    }
}

/// FNV-1a over sorted IDs. Swift's `Hasher` is seeded per process, so it can't be persisted.
public enum Fingerprint {
    public static func of(_ ids: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in ids.sorted().joined(separator: "\u{1F}").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}

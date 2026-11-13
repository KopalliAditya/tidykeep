import Foundation

/// One series of near-identical photos, ranked.
public struct PhotoGroup: Sendable, Hashable, Identifiable {
    /// Stable across launches for the same set of photos (see `Fingerprint`).
    public let id: String
    /// Best first.
    public let members: [AssetMeta]
    public let ranking: Ranking
    /// Members Vision judges document-like: receipts, pages, screenshots. Shots of different
    /// pages look alike to the feature print, so these are never offered for removal.
    public let documentIDs: Set<String>

    public init(members: [(meta: AssetMeta, signals: FrameSignals)]) {
        let ranking = ShotScorer.rank(members)
        let byID = Dictionary(uniqueKeysWithValues: members.map { ($0.meta.id, $0.meta) })
        self.id = Fingerprint.of(members.map(\.meta.id))
        self.ranking = ranking
        self.members = ranking.orderedIDs.compactMap { byID[$0] }
        self.documentIDs = Set(members.filter(\.signals.isUtility).map(\.meta.id))
    }

    public var keeper: AssetMeta { members[0] }
    public var startDate: Date { members.map(\.creationDate).min() ?? keeper.creationDate }

    public func member(_ id: String) -> AssetMeta? { members.first { $0.id == id } }

    /// Always kept: a favorite, an edited photo, or a document.
    public func isProtected(_ id: String) -> Bool {
        documentIDs.contains(id) || member(id)?.isProtected == true
    }

    /// Nothing here could be removed, so there's nothing to review.
    public var isFullyProtected: Bool { members.allSatisfy { isProtected($0.id) } }

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

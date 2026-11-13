/// Why cards were put together. The list sections follow these.
public enum MatchReason: String, Sendable, Codable, Hashable, CaseIterable {
    case sameName
    case samePhone
    case sameEmail
}

/// Cards that look like the same person.
public struct ContactDuplicateGroup: Sendable, Codable, Hashable, Identifiable {
    /// Built from the sorted card IDs, so the same cards give the same group on every scan
    /// and a group the user kept apart can be recognized when it comes back.
    public let id: String
    /// The keeper first, then the others in the order the cards were given.
    public let cardIDs: [String]
    public let reasons: Set<MatchReason>
    public let keeperID: String
    /// The cards live in different accounts. Shown for information only: merging across
    /// accounts would move data between them, so the app never does it.
    public let isCrossAccount: Bool

    public init(cardIDs: [String], reasons: Set<MatchReason>, keeperID: String, isCrossAccount: Bool) {
        self.id = Self.id(for: cardIDs)
        self.cardIDs = cardIDs
        self.reasons = reasons
        self.keeperID = keeperID
        self.isCrossAccount = isCrossAccount
    }

    /// The group ID for these cards, whatever their order.
    public static func id(for cardIDs: [String]) -> String {
        cardIDs.sorted().joined(separator: "|")
    }

    /// The cards other than the keeper.
    public var otherIDs: [String] {
        cardIDs.filter { $0 != keeperID }
    }
}

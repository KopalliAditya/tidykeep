/// What the user picked on the merge screen for fields that hold one value.
public struct MergeChoices: Sendable, Codable, Hashable {
    /// The card whose name (prefix, given, middle and family name and suffix) the merged card
    /// takes. A card with no person name gives way to the first card that has one, so a merge
    /// never drops the only name.
    public var nameFrom: String
    /// The card whose photo the merged card takes. Nil keeps the keeper's photo, or the first
    /// photo among the cards when the keeper has none, so a merge never drops the only photo.
    public var photoFrom: String?

    public init(nameFrom: String, photoFrom: String? = nil) {
        self.nameFrom = nameFrom
        self.photoFrom = photoFrom
    }
}

/// A merge worked out in full before anything is saved: the preview shows it, the store
/// applies it, and History keeps it so the merge can be undone.
public struct MergePlan: Sendable, Codable, Hashable {
    /// The card that stays. It keeps its identifier, its note and its links from other apps.
    public var keeperID: String
    /// The cards deleted by the merge, in the order they were given.
    public var removedIDs: [String]
    /// The keeper as it was. Undo puts these values back in place.
    public var keeperBefore: ContactCard
    /// The removed cards as the preview saw them, in `removedIDs` order. A store refuses the
    /// merge when one of them changed since, because the merged card wouldn't hold the change.
    public var removedBefore: [ContactCard]
    /// The keeper after the merge.
    public var merged: ContactCard
    /// Where each value of the merged card came from, by `MergeField` key, for the
    /// "from card 2" captions.
    public var fieldSources: [String: String]
    /// Values the merged card takes from the other cards, added or chosen over the keeper's.
    public var addedFieldCount: Int
    /// The card whose photo replaces the keeper's, when it isn't the keeper's own. Only then
    /// does a store read image data.
    public var photoFromID: String?

    /// What to back up before applying: the keeper (for its photo) and every removed card.
    public var backupIDs: [String] { [keeperID] + removedIDs }
}

extension MergePlan {
    /// Missing fields get their defaults, so a plan History saved in an older version still
    /// loads for its undo.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            keeperID: try c.decode(String.self, forKey: .keeperID),
            removedIDs: try c.decode([String].self, forKey: .removedIDs),
            keeperBefore: try c.decode(ContactCard.self, forKey: .keeperBefore),
            removedBefore: try c.decodeIfPresent([ContactCard].self, forKey: .removedBefore) ?? [],
            merged: try c.decode(ContactCard.self, forKey: .merged),
            fieldSources: try c.decodeIfPresent([String: String].self, forKey: .fieldSources) ?? [:],
            addedFieldCount: try c.decodeIfPresent(Int.self, forKey: .addedFieldCount) ?? 0,
            photoFromID: try c.decodeIfPresent(String.self, forKey: .photoFromID)
        )
    }

    /// The removed card as the preview saw it.
    func removedCardBefore(_ id: String) -> ContactCard? {
        removedBefore.first { $0.id == id }
    }
}

/// Keys of `MergePlan.fieldSources`. Multi-value fields are keyed by their index in the
/// merged card.
public enum MergeField {
    public static let name = "name"
    public static let phoneticName = "phoneticName"
    public static let previousFamilyName = "previousFamilyName"
    public static let nickname = "nickname"
    public static let organization = "organization"
    public static let department = "department"
    public static let jobTitle = "jobTitle"
    public static let phoneticOrganization = "phoneticOrganization"
    public static let birthday = "birthday"
    public static let nonGregorianBirthday = "nonGregorianBirthday"
    public static let photo = "photo"

    public static func phone(_ index: Int) -> String { "phones.\(index)" }
    public static func email(_ index: Int) -> String { "emails.\(index)" }
    public static func postalAddress(_ index: Int) -> String { "postalAddresses.\(index)" }
    public static func url(_ index: Int) -> String { "urls.\(index)" }
    public static func date(_ index: Int) -> String { "dates.\(index)" }
    public static func relation(_ index: Int) -> String { "relations.\(index)" }
    public static func socialProfile(_ index: Int) -> String { "socialProfiles.\(index)" }
    public static func instantMessage(_ index: Int) -> String { "instantMessages.\(index)" }
}

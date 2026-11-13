import Foundation

/// Turns names, phone numbers and emails into keys that compare equal when they mean the same
/// thing. Two cards match when they share a key.
///
/// There is no country table. Comparing the last 10 digits makes "+1 415 555 0123",
/// "(415) 555-0123" and "001 415 555 0123" the same number, and also drops the national "0" of
/// most 10-digit numbers abroad ("020 7946 0958" and "+44 20 7946 0958"). Numbers written with
/// two different country codes are kept apart on top of the key (see `PhoneNumber`), because
/// "+91 92512 34567" and "+1 925 123 4567" share their last 10 digits. Numbers shorter than 7
/// digits are short codes and service numbers, which say nothing about who a card is.
public enum ContactNormalizer {
    /// Digits compared from the end of a number.
    public static let phoneDigitsCompared = 10
    /// Fewer digits than this is a short code, not a person's number.
    public static let phoneMinimumDigits = 7

    /// The number's key, or nil when it is too short to identify anyone.
    ///
    /// What follows the number is part of the key ("4155550100X234"), so two direct lines on
    /// one switchboard don't match, and neither does a direct line and the switchboard itself.
    /// The way an extension is written doesn't matter: "x12", "ext. 12" and "Ext 12" agree.
    public static func phoneKey(_ raw: String) -> String? {
        PhoneNumber(raw).matchKey
    }

    /// Whether two phone values are one number, so a merge may keep just one of them.
    ///
    /// Stricter than `phoneKey`: short codes are compared whole ("*86" and "#86" differ), as are
    /// vanity numbers ("1-800-FLOWERS" and "1-800-CONTACTS"), and different country codes
    /// differ. A merge that wrongly calls two numbers one deletes a number, so when in doubt
    /// they are two.
    public static func samePhoneNumber(_ a: String, _ b: String) -> Bool {
        PhoneNumber(a).isSame(as: PhoneNumber(b))
    }

    /// The address trimmed and lowercased, or nil when it isn't an address at all.
    public static func emailKey(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("mailto:") { text.removeFirst("mailto:".count) }
        guard let at = text.firstIndex(of: "@"), at != text.startIndex,
              text.index(after: at) != text.endIndex else { return nil }
        return text
    }

    /// The card's name as a key, or nil when the name is too thin to match on.
    ///
    /// Given, middle and family names are folded (case, accents, full-width letters) and split
    /// into words, and the words are sorted, so "Kopalli Aditya" in one field matches
    /// "Aditya" + "Kopalli". A one-word name never matches on its own: "Mom" and "Mom" are
    /// often two people. The suffix is part of the key, so "John Smith Sr." and
    /// "John Smith Jr." don't match; the prefix isn't ("Dr. Ann Lee" is Ann Lee).
    ///
    /// A card with no person name keys on its organization and department instead, so two
    /// departments of one company ("Kaiser", Pharmacy and Advice Nurse) don't match.
    public static func nameKey(_ card: ContactCard) -> String? {
        let words = nameWords(card)
        // A slash can't appear in a word, so it only ever separates the parts of a key.
        func with(_ extra: String, _ key: String) -> String {
            let more = Self.words(extra)
            return more.isEmpty ? key : key + " /" + more.joined(separator: " ")
        }
        if words.isEmpty {
            let organization = Self.words(card.organization)
            // The colon can't appear in a word, so an organization never collides with a person.
            guard !organization.isEmpty else { return nil }
            return with(card.department, "org:" + organization.joined(separator: " "))
        }
        guard words.count >= 2 else { return nil }
        return with(card.nameSuffix, words.sorted().joined(separator: " "))
    }

    /// Whether the two cards are named as two different people, so a phone number or email
    /// they share doesn't make them one: a family's landline, a couple's shared inbox, a father
    /// and son on one number.
    ///
    /// Both names need two words or more. They name different people when their first words
    /// differ and neither name holds all the other's words ("Ann Lee" and "Ben Lee", but not
    /// "Aditya Kopalli" and "Aditya K Kopalli"), or when both have a suffix and the suffixes
    /// differ. A first word that begins the other ("Adi" and "Aditya", "J" and "John") is a
    /// short form, not another person. The cost is that "Bob Smith" and "Robert Smith" sharing
    /// a number aren't suggested; a wrong merge would delete a person's card, a missed one
    /// costs nothing.
    static func namesDiffer(_ a: ContactCard, _ b: ContactCard) -> Bool {
        PersonName(a).differs(from: PersonName(b))
    }

    /// A card's name in the words the finder compares, worked out once per card.
    struct PersonName {
        let words: [String]
        let suffix: [String]

        init(_ card: ContactCard) {
            words = ContactNormalizer.nameWords(card)
            suffix = ContactNormalizer.words(card.nameSuffix)
        }

        /// See `namesDiffer`.
        func differs(from other: PersonName) -> Bool {
            guard words.count >= 2, other.words.count >= 2 else { return false }
            if !suffix.isEmpty, !other.suffix.isEmpty, suffix != other.suffix { return true }
            let (first, otherFirst) = (words[0], other.words[0])
            if first.hasPrefix(otherFirst) || otherFirst.hasPrefix(first) { return false }
            let (mine, theirs) = (Set(words), Set(other.words))
            return !mine.isSubset(of: theirs) && !theirs.isSubset(of: mine)
        }
    }

    /// The words of the given, middle and family names, in that order.
    static func nameWords(_ card: ContactCard) -> [String] {
        words(card.givenName) + words(card.middleName) + words(card.familyName)
    }

    /// Lowercase words with accents and width folded away. Apostrophes join ("O'Brien" is
    /// "obrien"); any other punctuation separates ("Smith-Jones" is "smith jones").
    static func words(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .filter { !"'\u{2019}\u{02BC}".contains($0) }
        return folded.split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    /// Folded words joined by spaces, for comparing free text such as address lines.
    static func folded(_ text: String) -> String {
        words(text).joined(separator: " ")
    }
}

import Foundation

/// A phone number taken apart, so two numbers can be compared by what gets dialed rather than
/// by how they are written.
///
/// "+1 (415) 555-0123 ext. 12" is the country code "1", the digits "4155550123" and the
/// suffix "X12". Anything after the number (an extension, pauses, the letters of a vanity
/// number) is kept, because it reaches a different phone: two coworkers' direct lines on one
/// switchboard differ only there.
struct PhoneNumber: Hashable {
    /// Letters and symbols written before the first digit ("tel", "*"), uppercased.
    let lead: String
    /// Every digit of the number itself, with an international "00" dropped.
    let digits: String
    /// Written with "+" or "00", so `digits` start with a country code.
    let hasCountryCode: Bool
    /// What follows the number, spacing and punctuation dropped and letters uppercased:
    /// "X234" for an extension (however "ext" is spelled), ",,77" for pauses, "FLOWERS" for a
    /// vanity number. Empty for a plain number.
    let suffix: String
    /// The whole value with only spacing and punctuation dropped. Numbers too short to take
    /// apart ("*86", "#86", "911") compare by this, so no symbol or letter is ignored.
    let compact: String

    init(_ raw: String) {
        // "+44 (0)20 …": the "(0)" is the trunk prefix, dialed only from inside the country.
        let text = raw.folding(options: .widthInsensitive, locale: nil)
            .replacingOccurrences(of: "(0)", with: "")
        var lead = ""
        var digits = ""
        var hasCountryCode = false
        var rest = Substring()
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if ch.isASCII, ch.isNumber {
                digits.append(ch)
            } else if ch == "+", digits.isEmpty {
                hasCountryCode = true
            } else if Self.isMeaningful(ch), !ch.isNumber {
                // Before the first digit it's a label or a dialing code; after it, the number
                // has ended and the rest is its suffix.
                if !digits.isEmpty {
                    rest = text[index...]
                    break
                }
                lead.append(ch)
            }
            index = text.index(after: index)
        }
        // "00" is the international prefix most of the world dials instead of "+".
        if !hasCountryCode, digits.hasPrefix("00") {
            digits.removeFirst(2)
            hasCountryCode = true
        }
        self.lead = lead.uppercased()
        self.digits = digits
        self.hasCountryCode = hasCountryCode
        self.suffix = Self.normalizedSuffix(rest)
        self.compact = text.filter { Self.isMeaningful($0) || $0 == "+" }.uppercased()
    }

    /// Enough digits to be a person's number rather than a short code.
    var isFullNumber: Bool {
        digits.count >= ContactNormalizer.phoneMinimumDigits
    }

    /// The last digits, which are the same whether the number is written with its country
    /// code, with a national "0" or "1", or with neither.
    var national: String {
        String(digits.suffix(ContactNormalizer.phoneDigitsCompared))
    }

    /// The key the duplicate finder matches on (see `ContactNormalizer.phoneKey`).
    var matchKey: String? {
        isFullNumber ? national + suffix : nil
    }

    /// The country code the number was written with, when it can be told apart from the
    /// national digits. Nil when the number was written without one.
    var countryCode: String? {
        guard hasCountryCode, digits.count > ContactNormalizer.phoneDigitsCompared else { return nil }
        return String(digits.dropLast(ContactNormalizer.phoneDigitsCompared))
    }

    /// Whether the two could be one number: their national digits agree and they weren't
    /// written with different country codes. A number written without one could be either.
    func sameCountry(as other: PhoneNumber) -> Bool {
        guard let mine = countryCode, let theirs = other.countryCode else { return true }
        return mine == theirs
    }

    /// Whether the two values are certainly one number, so a merge may keep only one of them.
    /// Every letter, extension and pause counts; only formatting and the way the country is
    /// written don't.
    func isSame(as other: PhoneNumber) -> Bool {
        guard isFullNumber, other.isFullNumber else { return compact == other.compact }
        return national == other.national && suffix == other.suffix && lead == other.lead
            && sameCountry(as: other)
    }

    /// Letters, digits and the dialing symbols. Everything else is spacing and punctuation.
    private static func isMeaningful(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber || ",;#*".contains(ch)
    }

    private static func normalizedSuffix(_ rest: Substring) -> String {
        var suffix = rest.filter(isMeaningful).uppercased()
        for word in ["EXTENSION", "EXTN", "EXT"] where suffix.hasPrefix(word) {
            suffix = "X" + suffix.dropFirst(word.count)
            break
        }
        return suffix
    }
}

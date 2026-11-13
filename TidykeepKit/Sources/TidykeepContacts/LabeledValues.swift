import Foundation

// The values of a card's multi-value fields, each with its raw Contacts label.
//
// `label` is the raw label (`_$!<Mobile>!$_`, or text the user typed), kept as is so a merge
// writes back exactly what was there. The UI turns it into words. Every type here holds every
// part Contacts stores, so writing one back loses nothing.

/// One value of a text field: a phone number, an email address, a web address, or the name in
/// a relation ("Sister: Ana").
public struct LabeledValue: Sendable, Codable, Hashable {
    public var label: String?
    public var value: String

    public init(label: String? = nil, value: String) {
        self.label = label
        self.value = value
    }
}

/// A postal address.
public struct LabeledPostal: Sendable, Codable, Hashable {
    public var label: String?
    public var street: String
    public var subLocality: String
    public var city: String
    public var subAdministrativeArea: String
    public var state: String
    public var postalCode: String
    public var country: String
    public var isoCountryCode: String

    public init(
        label: String? = nil, street: String = "", subLocality: String = "", city: String = "",
        subAdministrativeArea: String = "", state: String = "", postalCode: String = "",
        country: String = "", isoCountryCode: String = ""
    ) {
        self.label = label
        self.street = street
        self.subLocality = subLocality
        self.city = city
        self.subAdministrativeArea = subAdministrativeArea
        self.state = state
        self.postalCode = postalCode
        self.country = country
        self.isoCountryCode = isoCountryCode
    }

    /// The parts a person reads, in order. The country code is left out: it only says which
    /// format the rest is in.
    var parts: [String] {
        [street, subLocality, city, subAdministrativeArea, state, postalCode, country]
    }

    /// Every part is blank. Such an address adds nothing to a merge.
    public var isEmpty: Bool {
        parts.allSatisfy(\.isBlank)
    }
}

/// A labeled date, such as an anniversary. Year (when known), month and day.
public struct LabeledDate: Sendable, Codable, Hashable {
    public var label: String?
    public var date: DateComponents

    public init(label: String? = nil, date: DateComponents) {
        self.label = label
        self.date = date
    }
}

/// A social profile. Contacts fills in only some of the parts, depending on the service.
public struct LabeledSocialProfile: Sendable, Codable, Hashable {
    public var label: String?
    public var service: String
    public var username: String
    public var userIdentifier: String
    public var urlString: String

    public init(
        label: String? = nil, service: String = "", username: String = "",
        userIdentifier: String = "", urlString: String = ""
    ) {
        self.label = label
        self.service = service
        self.username = username
        self.userIdentifier = userIdentifier
        self.urlString = urlString
    }

    /// Every part is blank. Such a profile adds nothing to a merge.
    public var isEmpty: Bool {
        [username, userIdentifier, urlString].allSatisfy(\.isBlank)
    }
}

/// An instant message address.
public struct LabeledInstantMessage: Sendable, Codable, Hashable {
    public var label: String?
    public var service: String
    public var username: String

    public init(label: String? = nil, service: String = "", username: String) {
        self.label = label
        self.service = service
        self.username = username
    }
}

/// A day in a calendar other than the Gregorian one: a Hebrew, Islamic or Chinese birthday.
///
/// The calendar is kept by name rather than as a `Calendar`, because a `Calendar` also carries
/// a time zone and locale, which would make the same birthday compare unequal after a trip
/// abroad.
public struct CalendarDate: Sendable, Codable, Hashable {
    /// The calendar's identifier as Contacts names it, such as "hebrew" or "chinese".
    public var calendar: String
    public var era: Int?
    public var year: Int?
    public var month: Int?
    public var day: Int?
    /// Lunisolar calendars repeat a month in some years; this says it's the repeated one.
    public var isLeapMonth: Bool

    public init(
        calendar: String, era: Int? = nil, year: Int? = nil, month: Int? = nil, day: Int? = nil,
        isLeapMonth: Bool = false
    ) {
        self.calendar = calendar
        self.era = era
        self.year = year
        self.month = month
        self.day = day
        self.isLeapMonth = isLeapMonth
    }
}

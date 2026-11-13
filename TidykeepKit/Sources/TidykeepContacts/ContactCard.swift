import Foundation

/// A contact card as the duplicate finder and the merge see it: every field Contacts lets the
/// app read and write, so a merge can carry all of them over and an undo can put all of them
/// back.
///
/// Notes are never among them. Reading a note needs an entitlement the app doesn't have, so a
/// merge can't carry notes over and the UI warns before every merge. The photo is only a flag
/// here; its data is large, so the stores handle it on their own.
public struct ContactCard: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    /// The account the card lives in. Cards only merge within one.
    public var containerID: String
    public var containerName: String
    /// My Card. It is only ever the keeper, never removed.
    public var isMe: Bool
    /// "Dr.", "Ms."
    public var namePrefix: String
    public var givenName: String
    public var middleName: String
    public var familyName: String
    /// "Jr.", "III". It tells a father and son of the same name apart.
    public var nameSuffix: String
    public var previousFamilyName: String
    public var nickname: String
    /// How the name is said, for names whose spelling doesn't show it (Japanese names, mostly).
    public var phoneticGivenName: String
    public var phoneticMiddleName: String
    public var phoneticFamilyName: String
    public var organization: String
    public var department: String
    public var jobTitle: String
    public var phoneticOrganization: String
    public var phones: [LabeledValue]
    public var emails: [LabeledValue]
    public var postalAddresses: [LabeledPostal]
    public var urls: [LabeledValue]
    /// Anniversaries and other labeled dates.
    public var dates: [LabeledDate]
    /// Related people by name, labeled with how they're related ("Sister: Ana").
    public var relations: [LabeledValue]
    public var socialProfiles: [LabeledSocialProfile]
    public var instantMessages: [LabeledInstantMessage]
    /// Year (when known), month and day.
    public var birthday: DateComponents?
    public var nonGregorianBirthday: CalendarDate?
    public var hasImage: Bool

    public init(
        id: String, containerID: String = "", containerName: String = "", isMe: Bool = false,
        namePrefix: String = "", givenName: String = "", middleName: String = "",
        familyName: String = "", nameSuffix: String = "", previousFamilyName: String = "",
        nickname: String = "", phoneticGivenName: String = "", phoneticMiddleName: String = "",
        phoneticFamilyName: String = "", organization: String = "", department: String = "",
        jobTitle: String = "", phoneticOrganization: String = "",
        phones: [LabeledValue] = [], emails: [LabeledValue] = [],
        postalAddresses: [LabeledPostal] = [], urls: [LabeledValue] = [],
        dates: [LabeledDate] = [], relations: [LabeledValue] = [],
        socialProfiles: [LabeledSocialProfile] = [], instantMessages: [LabeledInstantMessage] = [],
        birthday: DateComponents? = nil, nonGregorianBirthday: CalendarDate? = nil,
        hasImage: Bool = false
    ) {
        self.id = id
        self.containerID = containerID
        self.containerName = containerName
        self.isMe = isMe
        self.namePrefix = namePrefix
        self.givenName = givenName
        self.middleName = middleName
        self.familyName = familyName
        self.nameSuffix = nameSuffix
        self.previousFamilyName = previousFamilyName
        self.nickname = nickname
        self.phoneticGivenName = phoneticGivenName
        self.phoneticMiddleName = phoneticMiddleName
        self.phoneticFamilyName = phoneticFamilyName
        self.organization = organization
        self.department = department
        self.jobTitle = jobTitle
        self.phoneticOrganization = phoneticOrganization
        self.phones = phones
        self.emails = emails
        self.postalAddresses = postalAddresses
        self.urls = urls
        self.dates = dates
        self.relations = relations
        self.socialProfiles = socialProfiles
        self.instantMessages = instantMessages
        self.birthday = birthday
        self.nonGregorianBirthday = nonGregorianBirthday
        self.hasImage = hasImage
    }

    /// The name as written, prefix and suffix included ("John Smith Jr."), falling back to the
    /// organization. Empty when the card has neither; the UI picks the words for that.
    public var displayName: String {
        let name = personName
        guard !name.isEmpty else { return organization.trimmingCharacters(in: .whitespaces) }
        return [namePrefix, name, nameSuffix]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// How many values the card holds. The card with the most is the default keeper, because
    /// keeping it changes the least.
    public var detailCount: Int {
        let singles = [
            namePrefix, givenName, middleName, familyName, nameSuffix, previousFamilyName, nickname,
            phoneticGivenName, phoneticMiddleName, phoneticFamilyName, organization, department,
            jobTitle, phoneticOrganization,
        ].filter { !$0.isBlank }.count
        let lists = phones.count + emails.count + postalAddresses.count + urls.count + dates.count
            + relations.count + socialProfiles.count + instantMessages.count
        let others = [birthday != nil, nonGregorianBirthday != nil, hasImage].filter { $0 }.count
        return singles + lists + others
    }

    /// Given, middle and family name, without the organization fallback of `displayName`.
    var personName: String {
        [givenName, middleName, familyName].filter { !$0.isBlank }.joined(separator: " ")
    }

    /// Missing fields get their defaults, so a plan saved by an older version still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) throws -> String {
            try c.decodeIfPresent(String.self, forKey: key) ?? ""
        }
        func list<T: Decodable>(_ key: CodingKeys) throws -> [T] {
            try c.decodeIfPresent([T].self, forKey: key) ?? []
        }
        id = try c.decode(String.self, forKey: .id)
        containerID = try text(.containerID)
        containerName = try text(.containerName)
        isMe = try c.decodeIfPresent(Bool.self, forKey: .isMe) ?? false
        namePrefix = try text(.namePrefix)
        givenName = try text(.givenName)
        middleName = try text(.middleName)
        familyName = try text(.familyName)
        nameSuffix = try text(.nameSuffix)
        previousFamilyName = try text(.previousFamilyName)
        nickname = try text(.nickname)
        phoneticGivenName = try text(.phoneticGivenName)
        phoneticMiddleName = try text(.phoneticMiddleName)
        phoneticFamilyName = try text(.phoneticFamilyName)
        organization = try text(.organization)
        department = try text(.department)
        jobTitle = try text(.jobTitle)
        phoneticOrganization = try text(.phoneticOrganization)
        phones = try list(.phones)
        emails = try list(.emails)
        postalAddresses = try list(.postalAddresses)
        urls = try list(.urls)
        dates = try list(.dates)
        relations = try list(.relations)
        socialProfiles = try list(.socialProfiles)
        instantMessages = try list(.instantMessages)
        birthday = try c.decodeIfPresent(DateComponents.self, forKey: .birthday)
        nonGregorianBirthday = try c.decodeIfPresent(CalendarDate.self, forKey: .nonGregorianBirthday)
        hasImage = try c.decodeIfPresent(Bool.self, forKey: .hasImage) ?? false
    }
}

extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

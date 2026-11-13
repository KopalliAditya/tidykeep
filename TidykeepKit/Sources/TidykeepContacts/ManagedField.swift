import Foundation

/// The fields a merge sets on the keeper and an undo puts back: every field of the card. The
/// photo isn't one of them: it is image data the card model doesn't hold, so the stores handle
/// it on their own.
enum ManagedField: String, CaseIterable, Sendable {
    /// Prefix, given, middle and family name and suffix together: a name is chosen as a whole.
    case name
    /// How the name is said. It belongs to one name, so it is chosen as a whole too.
    case phoneticName
    case previousFamilyName
    case nickname
    case organization
    case department
    case jobTitle
    case phoneticOrganization
    case phones
    case emails
    case postalAddresses
    case urls
    case dates
    case relations
    case socialProfiles
    case instantMessages
    case birthday
    case nonGregorianBirthday
}

extension ContactCard {
    func same(_ field: ManagedField, as other: ContactCard) -> Bool {
        switch field {
        case .name:
            namePrefix == other.namePrefix && givenName == other.givenName
                && middleName == other.middleName && familyName == other.familyName
                && nameSuffix == other.nameSuffix
        case .phoneticName:
            phoneticGivenName == other.phoneticGivenName
                && phoneticMiddleName == other.phoneticMiddleName
                && phoneticFamilyName == other.phoneticFamilyName
        case .previousFamilyName: previousFamilyName == other.previousFamilyName
        case .nickname: nickname == other.nickname
        case .organization: organization == other.organization
        case .department: department == other.department
        case .jobTitle: jobTitle == other.jobTitle
        case .phoneticOrganization: phoneticOrganization == other.phoneticOrganization
        case .phones: phones == other.phones
        case .emails: emails == other.emails
        case .postalAddresses:
            // Contacts may fill in the country code on save, so it doesn't count as a change.
            postalAddresses.map(\.comparable) == other.postalAddresses.map(\.comparable)
        case .urls: urls == other.urls
        case .dates: dates == other.dates
        case .relations: relations == other.relations
        case .socialProfiles: socialProfiles == other.socialProfiles
        case .instantMessages: instantMessages == other.instantMessages
        case .birthday: birthday == other.birthday
        case .nonGregorianBirthday: nonGregorianBirthday == other.nonGregorianBirthday
        }
    }

    mutating func copy(_ field: ManagedField, from other: ContactCard) {
        switch field {
        case .name:
            namePrefix = other.namePrefix
            givenName = other.givenName
            middleName = other.middleName
            familyName = other.familyName
            nameSuffix = other.nameSuffix
        case .phoneticName:
            phoneticGivenName = other.phoneticGivenName
            phoneticMiddleName = other.phoneticMiddleName
            phoneticFamilyName = other.phoneticFamilyName
        case .previousFamilyName: previousFamilyName = other.previousFamilyName
        case .nickname: nickname = other.nickname
        case .organization: organization = other.organization
        case .department: department = other.department
        case .jobTitle: jobTitle = other.jobTitle
        case .phoneticOrganization: phoneticOrganization = other.phoneticOrganization
        case .phones: phones = other.phones
        case .emails: emails = other.emails
        case .postalAddresses: postalAddresses = other.postalAddresses
        case .urls: urls = other.urls
        case .dates: dates = other.dates
        case .relations: relations = other.relations
        case .socialProfiles: socialProfiles = other.socialProfiles
        case .instantMessages: instantMessages = other.instantMessages
        case .birthday: birthday = other.birthday
        case .nonGregorianBirthday: nonGregorianBirthday = other.nonGregorianBirthday
        }
    }

    /// Whether every managed field matches. Identity, account and photo aren't compared.
    func hasSameDetails(as other: ContactCard) -> Bool {
        ManagedField.allCases.allSatisfy { same($0, as: other) }
    }

    /// Whether the card is still as the merge preview saw it: the same details, account and
    /// photo. A merge worked out from an older look would drop what changed since.
    func matchesPreview(_ before: ContactCard) -> Bool {
        containerID == before.containerID && hasImage == before.hasImage && hasSameDetails(as: before)
    }

    /// This card with the other card's managed fields.
    func withDetails(of other: ContactCard) -> ContactCard {
        var copy = self
        for field in ManagedField.allCases { copy.copy(field, from: other) }
        return copy
    }
}

extension LabeledPostal {
    /// The address as `same` compares it: without the country code, which Contacts may fill in.
    var comparable: [String?] {
        [label] + parts.map(Optional.some)
    }
}

import Contacts
import Foundation

/// The Contacts keys Tidykeep reads. `CNContactNoteKey` is never among them: reading a note
/// needs an entitlement the app doesn't have, and a contact fetched without it is saved
/// without touching its note.
enum ContactKeys {
    /// The fields a merge sets and an undo restores: every field of `ContactCard`.
    static let managed: [String] = [
        CNContactNamePrefixKey, CNContactGivenNameKey, CNContactMiddleNameKey,
        CNContactFamilyNameKey, CNContactNameSuffixKey, CNContactPreviousFamilyNameKey,
        CNContactNicknameKey, CNContactPhoneticGivenNameKey, CNContactPhoneticMiddleNameKey,
        CNContactPhoneticFamilyNameKey, CNContactOrganizationNameKey, CNContactDepartmentNameKey,
        CNContactJobTitleKey, CNContactPhoneticOrganizationNameKey, CNContactPhoneNumbersKey,
        CNContactEmailAddressesKey, CNContactPostalAddressesKey, CNContactUrlAddressesKey,
        CNContactDatesKey, CNContactRelationsKey, CNContactSocialProfilesKey,
        CNContactInstantMessageAddressesKey, CNContactBirthdayKey, CNContactNonGregorianBirthdayKey,
        CNContactImageDataAvailableKey,
    ]
    /// What a scan reads: everything but image data, which is large and only needed for a
    /// backup or a photo merge. The card type (person or company) is read so a backup can
    /// re-create it.
    static let read = managed + [CNContactTypeKey]
    /// What a backup reads.
    static let backup = read + [CNContactImageDataKey]

    static func descriptors(_ keys: [String]) -> [CNKeyDescriptor] {
        keys.map { $0 as NSString }
    }
}

extension ContactCard {
    /// The card for a contact fetched with at least the `ContactKeys.managed` keys.
    init(_ contact: CNContact, id: String, containerID: String, containerName: String, isMe: Bool) {
        let hasImage = contact.isKeyAvailable(CNContactImageDataKey)
            ? contact.imageData != nil
            : contact.imageDataAvailable
        self.init(
            id: id, containerID: containerID, containerName: containerName, isMe: isMe,
            namePrefix: contact.namePrefix, givenName: contact.givenName,
            middleName: contact.middleName, familyName: contact.familyName,
            nameSuffix: contact.nameSuffix, previousFamilyName: contact.previousFamilyName,
            nickname: contact.nickname, phoneticGivenName: contact.phoneticGivenName,
            phoneticMiddleName: contact.phoneticMiddleName,
            phoneticFamilyName: contact.phoneticFamilyName,
            organization: contact.organizationName, department: contact.departmentName,
            jobTitle: contact.jobTitle, phoneticOrganization: contact.phoneticOrganizationName,
            phones: contact.phoneNumbers.map(LabeledValue.init),
            emails: contact.emailAddresses.map(LabeledValue.init),
            postalAddresses: contact.postalAddresses.map(LabeledPostal.init),
            urls: contact.urlAddresses.map(LabeledValue.init),
            dates: contact.dates.map(LabeledDate.init),
            relations: contact.contactRelations.map(LabeledValue.init),
            socialProfiles: contact.socialProfiles.map(LabeledSocialProfile.init),
            instantMessages: contact.instantMessageAddresses.map(LabeledInstantMessage.init),
            birthday: Self.day(contact.birthday),
            nonGregorianBirthday: contact.nonGregorianBirthday.flatMap(CalendarDate.init),
            hasImage: hasImage
        )
    }

    /// Sets these fields on `contact`. Only the fields named are touched, so a save changes
    /// nothing else; the image and note are never touched here.
    ///
    /// A multi-value field keeps every labeled value `contact` already has that is still
    /// wanted, as the same object (see `reconciled`), so a merge only adds values and an undo
    /// only takes away the added ones.
    func write(_ fields: [ManagedField] = ManagedField.allCases, to contact: CNMutableContact) {
        for field in fields {
            switch field {
            case .name:
                contact.namePrefix = namePrefix
                contact.givenName = givenName
                contact.middleName = middleName
                contact.familyName = familyName
                contact.nameSuffix = nameSuffix
            case .phoneticName:
                contact.phoneticGivenName = phoneticGivenName
                contact.phoneticMiddleName = phoneticMiddleName
                contact.phoneticFamilyName = phoneticFamilyName
            case .previousFamilyName: contact.previousFamilyName = previousFamilyName
            case .nickname: contact.nickname = nickname
            case .organization: contact.organizationName = organization
            case .department: contact.departmentName = department
            case .jobTitle: contact.jobTitle = jobTitle
            case .phoneticOrganization: contact.phoneticOrganizationName = phoneticOrganization
            case .phones:
                contact.phoneNumbers = Self.reconciled(contact.phoneNumbers, to: phones, read: LabeledValue.init) {
                    CNLabeledValue(label: $0.label, value: CNPhoneNumber(stringValue: $0.value))
                }
            case .emails:
                contact.emailAddresses = Self.reconciled(contact.emailAddresses, to: emails, read: LabeledValue.init) {
                    CNLabeledValue(label: $0.label, value: $0.value as NSString)
                }
            case .postalAddresses:
                contact.postalAddresses = Self.reconciled(
                    contact.postalAddresses, to: postalAddresses, read: LabeledPostal.init,
                    // Contacts may fill in the country code on save; that isn't another address.
                    same: { $0.comparable == $1.comparable }
                ) {
                    CNLabeledValue(label: $0.label, value: $0.postalAddress)
                }
            case .urls:
                contact.urlAddresses = Self.reconciled(contact.urlAddresses, to: urls, read: LabeledValue.init) {
                    CNLabeledValue(label: $0.label, value: $0.value as NSString)
                }
            case .dates:
                contact.dates = Self.reconciled(contact.dates, to: dates, read: LabeledDate.init) {
                    CNLabeledValue(label: $0.label, value: $0.date as NSDateComponents)
                }
            case .relations:
                contact.contactRelations = Self.reconciled(contact.contactRelations, to: relations, read: LabeledValue.init) {
                    CNLabeledValue(label: $0.label, value: CNContactRelation(name: $0.value))
                }
            case .socialProfiles:
                contact.socialProfiles = Self.reconciled(contact.socialProfiles, to: socialProfiles, read: LabeledSocialProfile.init) {
                    CNLabeledValue(label: $0.label, value: $0.socialProfile)
                }
            case .instantMessages:
                contact.instantMessageAddresses = Self.reconciled(contact.instantMessageAddresses, to: instantMessages, read: LabeledInstantMessage.init) {
                    CNLabeledValue(label: $0.label, value: CNInstantMessageAddress(username: $0.username, service: $0.service))
                }
            case .birthday: contact.birthday = birthday
            case .nonGregorianBirthday: contact.nonGregorianBirthday = nonGregorianBirthday?.dateComponents
            }
        }
    }

    /// The labeled values for `wanted`, in its order, reusing each of `current` that already
    /// holds one of them.
    ///
    /// A reused value keeps its identifier, which the system points at (a Phone favorite, an
    /// emergency contact's number), and for a phone number the country Contacts stored with it.
    /// Only values that aren't there yet are made new.
    static func reconciled<Value, Item>(
        _ current: [CNLabeledValue<Value>], to wanted: [Item], read: (CNLabeledValue<Value>) -> Item,
        same: (Item, Item) -> Bool, make: (Item) -> CNLabeledValue<Value>
    ) -> [CNLabeledValue<Value>] {
        var unused = current.map { (labeled: $0, item: read($0)) }
        return wanted.map { item in
            if let i = unused.firstIndex(where: { same($0.item, item) }) {
                return unused.remove(at: i).labeled
            }
            return make(item)
        }
    }

    static func reconciled<Value, Item: Equatable>(
        _ current: [CNLabeledValue<Value>], to wanted: [Item], read: (CNLabeledValue<Value>) -> Item,
        make: (Item) -> CNLabeledValue<Value>
    ) -> [CNLabeledValue<Value>] {
        reconciled(current, to: wanted, read: read, same: ==, make: make)
    }

    /// The fields in which the two cards differ.
    func fields(differingFrom other: ContactCard) -> [ManagedField] {
        ManagedField.allCases.filter { !same($0, as: other) }
    }

    /// A new contact with this card's fields and photo, for a vCard backup or a re-created card.
    func newContact(imageData: Data?, isOrganization: Bool = false) -> CNMutableContact {
        let contact = CNMutableContact()
        write(to: contact)
        contact.contactType = isOrganization ? .organization : .person
        contact.imageData = imageData
        return contact
    }

    /// Contacts and vCards write a missing label as an empty one; both mean "no label".
    static func label(_ label: String?) -> String? {
        guard let label, !label.isEmpty else { return nil }
        return label
    }

    /// Year, month and day only. A store adds its calendar and time zone, which would make the
    /// same birthday compare unequal after a round trip.
    static func day(_ components: DateComponents?) -> DateComponents? {
        guard let components else { return nil }
        return DateComponents(year: components.year, month: components.month, day: components.day)
    }
}


extension LabeledValue {
    init(_ labeled: CNLabeledValue<CNPhoneNumber>) {
        self.init(label: ContactCard.label(labeled.label), value: labeled.value.stringValue)
    }

    init(_ labeled: CNLabeledValue<NSString>) {
        self.init(label: ContactCard.label(labeled.label), value: labeled.value as String)
    }

    init(_ labeled: CNLabeledValue<CNContactRelation>) {
        self.init(label: ContactCard.label(labeled.label), value: labeled.value.name)
    }
}

extension LabeledPostal {
    init(_ labeled: CNLabeledValue<CNPostalAddress>) {
        let a = labeled.value
        self.init(
            label: ContactCard.label(labeled.label), street: a.street, subLocality: a.subLocality,
            city: a.city, subAdministrativeArea: a.subAdministrativeArea, state: a.state,
            postalCode: a.postalCode, country: a.country, isoCountryCode: a.isoCountryCode
        )
    }

    var postalAddress: CNPostalAddress {
        let a = CNMutablePostalAddress()
        a.street = street
        a.subLocality = subLocality
        a.city = city
        a.subAdministrativeArea = subAdministrativeArea
        a.state = state
        a.postalCode = postalCode
        a.country = country
        a.isoCountryCode = isoCountryCode
        return a
    }
}

extension LabeledDate {
    init(_ labeled: CNLabeledValue<NSDateComponents>) {
        self.init(
            label: ContactCard.label(labeled.label),
            date: ContactCard.day(labeled.value as DateComponents) ?? DateComponents())
    }
}

extension LabeledSocialProfile {
    init(_ labeled: CNLabeledValue<CNSocialProfile>) {
        let p = labeled.value
        self.init(
            label: ContactCard.label(labeled.label), service: p.service, username: p.username,
            userIdentifier: p.userIdentifier, urlString: p.urlString)
    }

    var socialProfile: CNSocialProfile {
        func part(_ text: String) -> String? { text.isEmpty ? nil : text }
        return CNSocialProfile(
            urlString: part(urlString), username: part(username),
            userIdentifier: part(userIdentifier), service: part(service))
    }
}

extension LabeledInstantMessage {
    init(_ labeled: CNLabeledValue<CNInstantMessageAddress>) {
        self.init(
            label: ContactCard.label(labeled.label), service: labeled.value.service,
            username: labeled.value.username)
    }
}

extension CalendarDate {
    /// Nil for components without a calendar, which name no day at all.
    init?(_ components: DateComponents) {
        guard let calendar = components.calendar else { return nil }
        self.init(
            calendar: (calendar as NSCalendar).calendarIdentifier.rawValue, era: components.era,
            year: components.year, month: components.month, day: components.day,
            isLeapMonth: components.isLeapMonth ?? false)
    }

    /// Nil when this system doesn't know the calendar.
    var dateComponents: DateComponents? {
        guard let calendar = NSCalendar(calendarIdentifier: NSCalendar.Identifier(rawValue: calendar)) else { return nil }
        var components = DateComponents()
        components.calendar = calendar as Calendar
        components.era = era
        components.year = year
        components.month = month
        components.day = day
        if isLeapMonth { components.isLeapMonth = true }
        return components
    }
}

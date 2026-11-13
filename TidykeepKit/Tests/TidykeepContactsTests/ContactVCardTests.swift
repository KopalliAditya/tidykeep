import Contacts
import Foundation
import Testing
@testable import TidykeepContacts

/// Backups are written from contacts built in memory. Nothing here opens an address book.
@Suite struct ContactVCardTests {
    /// A card with every field filled, including the ones Apple's vCard reader loses.
    let everyField = ContactCard(
        id: "ABC-1:ABPerson", namePrefix: "Dr.", givenName: "José", middleName: "M",
        familyName: "Núñez", nameSuffix: "Jr.", previousFamilyName: "García", nickname: "Pepe",
        phoneticGivenName: "Hosay", phoneticMiddleName: "Em", phoneticFamilyName: "Noonyez",
        organization: "Acme", department: "Tools", jobTitle: "Lead", phoneticOrganization: "Akmee",
        phones: [
            LabeledValue(label: CNLabelPhoneNumberMobile, value: "+1 (415) 555-0123"),
            LabeledValue(label: "pager, sort of", value: "650 555 0199 x12"),
        ],
        emails: [LabeledValue(label: CNLabelWork, value: "jose@example.com")],
        postalAddresses: [LabeledPostal(
            label: CNLabelHome, street: "1 Main St\nApt 2", subLocality: "Old Town", city: "Livermore",
            subAdministrativeArea: "Alameda", state: "CA", postalCode: "94550", country: "USA",
            isoCountryCode: "us")],
        urls: [LabeledValue(value: "example.com"), LabeledValue(label: CNLabelURLAddressHomePage, value: "jose.example")],
        dates: [LabeledDate(label: CNLabelDateAnniversary, date: DateComponents(year: 2020, month: 6, day: 1))],
        relations: [LabeledValue(label: CNLabelContactRelationSister, value: "Ana")],
        socialProfiles: [LabeledSocialProfile(
            label: "Profile", service: "Mastodon", username: "jose", userIdentifier: "42",
            urlString: "x.example/ann")],
        instantMessages: [LabeledInstantMessage(label: CNLabelHome, service: "Skype", username: "jose.n")],
        birthday: DateComponents(year: 1990, month: 3, day: 4),
        nonGregorianBirthday: CalendarDate(calendar: "chinese", era: 78, year: 7, month: 2, day: 8),
        hasImage: true)

    @Test func everyFieldSurvivesTheRoundTrip() throws {
        let entry = ContactBackupEntry(
            id: everyField.id, card: everyField, imageData: jpegA, isOrganization: true, groupIDs: ["family", "work"])
        let data = try ContactVCard.data([entry])
        let back = try #require(try ContactVCard.entries(in: data)[everyField.id])
        #expect(back == entry)
    }

    @Test func aCardSurvivesItsOwnContact() throws {
        let contact = everyField.newContact(imageData: jpegA, isOrganization: true)
        #expect(contact.contactType == .organization)
        let back = ContactCard(contact, id: everyField.id, containerID: "", containerName: "", isMe: false)
        #expect(back == everyField)
    }

    /// Backups written before the record line was added are read from their vCard text.
    @Test func aBackupWithoutRecordsIsReadFromItsText() throws {
        let card = ContactCard(
            id: "z", givenName: "Ann", middleName: "B", familyName: "Lee",
            phones: [LabeledValue(label: "_$!<Work>!$_", value: "555 1234")],
            birthday: DateComponents(month: 7, day: 1), hasImage: true)
        let data = try ContactVCard.data([ContactBackupEntry(id: "z", card: card, imageData: jpegB)])
        let text = try #require(String(data: data, encoding: .utf8))
        var lines: [String] = []
        var skipping = false
        for line in text.components(separatedBy: "\r\n") {
            if line.hasPrefix(" "), skipping { continue }
            skipping = line.hasPrefix(ContactVCard.recordProperty)
            if !skipping { lines.append(line) }
        }
        let old = Data(lines.joined(separator: "\r\n").utf8)
        #expect(!(String(data: old, encoding: .utf8) ?? "").contains(ContactVCard.recordProperty))
        let back = try #require(try ContactVCard.entries(in: old)["z"])
        #expect(back.card == card)
        #expect(back.imageData == jpegB)
        #expect(back.groupIDs.isEmpty)
    }

    @Test func theFileIsAPlainVCardWithoutNotes() throws {
        let data = try ContactVCard.data([
            ContactBackupEntry(id: "a", card: everyField, imageData: jpegA),
            ContactBackupEntry(id: "b", card: ContactCard(id: "b", givenName: "Ann", familyName: "Lee"), imageData: nil),
        ])
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.uppercased().contains("\nNOTE"))
        #expect(text.contains("X-TIDYKEEP-ID:a"))
        // Every line is folded to 75 bytes, so other apps can import it.
        #expect(text.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 75 })
        // Apple's own reader takes the whole file, extra lines and all.
        let plain = try CNContactVCardSerialization.contacts(with: data)
        #expect(plain.map(\.givenName) == ["José", "Ann"])
        #expect(plain.first?.imageData == jpegA)
    }

    @Test func entriesAreFoundByOriginalIdentifier() throws {
        let cards = (1...3).map { ContactCard(id: "id-\($0):ABPerson", givenName: "Card", familyName: "\($0)") }
        let data = try ContactVCard.data(cards.map { ContactBackupEntry(id: $0.id, card: $0, imageData: nil) })
        let back = try ContactVCard.entries(in: data)
        #expect(Set(back.keys) == Set(cards.map(\.id)))
        #expect(back["id-2:ABPerson"]?.card.familyName == "2")
    }

    @Test func otherFilesAreRefused() throws {
        #expect(throws: ContactStoreError.unreadableBackup) {
            try ContactVCard.entries(in: Data([0xFF, 0xFE, 0x00, 0xD8]))
        }
        // A vCard without identifiers names no cards.
        let foreign = try CNContactVCardSerialization.data(with: [everyField.newContact(imageData: nil)])
        #expect(try ContactVCard.entries(in: foreign).isEmpty)
        // A damaged record isn't silently read as a thinner card.
        let data = try ContactVCard.data([ContactBackupEntry(id: "a", card: everyField, imageData: nil)])
        let text = try #require(String(data: data, encoding: .utf8))
        let damaged = text.replacingOccurrences(of: ContactVCard.recordProperty + ":", with: ContactVCard.recordProperty + ":!!")
        #expect(throws: ContactStoreError.unreadableBackup) {
            try ContactVCard.entries(in: Data(damaged.utf8))
        }
    }

    /// A write reuses each labeled value that is still wanted, so its identifier (which a Phone
    /// favorite points at) and the country Contacts stored with a number survive a merge.
    @Test func writesKeepTheValuesAlreadyThere() {
        let contact = CNMutableContact()
        contact.phoneNumbers = [
            CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "415 555 0123")),
            CNLabeledValue(label: CNLabelWork, value: CNPhoneNumber(stringValue: "650 555 0199")),
        ]
        contact.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: "a@example.com" as NSString)]
        let before = contact.phoneNumbers.map(\.identifier)
        let emailBefore = contact.emailAddresses.map(\.identifier)

        var card = ContactCard(contact, id: "a", containerID: "", containerName: "", isMe: false)
        card.phones.append(LabeledValue(value: "408 555 0111"))
        card.emails.append(LabeledValue(value: "b@example.com"))
        card.write([.phones, .emails], to: contact)
        #expect(Array(contact.phoneNumbers.map(\.identifier).prefix(2)) == before)
        #expect(contact.phoneNumbers.count == 3)
        #expect(!before.contains(contact.phoneNumbers[2].identifier))
        #expect(contact.emailAddresses.first?.identifier == emailBefore.first)

        // Taking a value away (an undo) leaves the rest as they were.
        card.phones = [card.phones[1]]
        card.write([.phones], to: contact)
        #expect(contact.phoneNumbers.map(\.identifier) == [before[1]])
    }

    @Test func theStoresNeverReadNotes() {
        #expect(!SystemContactStore.keysRead.contains(CNContactNoteKey))
        #expect(!ContactKeys.read.contains(CNContactNoteKey))
        #expect(!ContactKeys.managed.contains(CNContactNoteKey))
    }

    @Test func accessMapsFromContacts() {
        #expect(SystemContactStore.access(.authorized) == .full)
        #expect(SystemContactStore.access(.denied) == .denied)
        #expect(SystemContactStore.access(.restricted) == .restricted)
        #expect(SystemContactStore.access(.notDetermined) == .notDetermined)
    }
}

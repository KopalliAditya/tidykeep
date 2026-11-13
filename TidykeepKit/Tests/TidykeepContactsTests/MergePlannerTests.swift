import Foundation
import Testing
import TidykeepContacts

@Suite struct MergePlannerTests {
    let keeper = ContactCard(
        id: "k", containerID: "phone", givenName: "Aditya", familyName: "Kopalli",
        organization: "Acme",
        phones: [LabeledValue(label: "_$!<Mobile>!$_", value: "+1 415 555 0123")],
        emails: [LabeledValue(label: "_$!<Home>!$_", value: "Aditya@Example.com")]
    )
    let other = ContactCard(
        id: "o", containerID: "phone", givenName: "Adi", familyName: "Kopalli", nickname: "AK",
        organization: "Globex", jobTitle: "Engineer",
        phones: [
            LabeledValue(label: "_$!<Home>!$_", value: "(415) 555-0123"),
            LabeledValue(label: "_$!<Work>!$_", value: "650 555 0199"),
        ],
        emails: [LabeledValue(label: "_$!<Work>!$_", value: "aditya@example.com ")],
        postalAddresses: [LabeledPostal(label: "_$!<Home>!$_", street: "1 Main St", city: "Livermore")],
        urls: [LabeledValue(label: "_$!<HomePage>!$_", value: "example.com")],
        birthday: DateComponents(year: 1994, month: 3, day: 4), hasImage: true
    )

    @Test func multiValueFieldsAreUnionedWithoutDuplicates() throws {
        let plan = try MergePlanner.plan(cards: [keeper, other], keeperID: "k", choices: MergeChoices(nameFrom: "k"))
        #expect(plan.merged.phones.map(\.value) == ["+1 415 555 0123", "650 555 0199"])
        #expect(plan.merged.emails.map(\.value) == ["Aditya@Example.com"])
        #expect(plan.merged.postalAddresses.count == 1)
        #expect(plan.merged.urls.map(\.value) == ["example.com"])
        #expect(plan.keeperID == "k")
        #expect(plan.removedIDs == ["o"])
        #expect(plan.keeperBefore == keeper)
    }

    @Test func equalValuesKeepTheKeepersLabel() throws {
        let plan = try MergePlanner.plan(cards: [keeper, other], keeperID: "k", choices: MergeChoices(nameFrom: "k"))
        #expect(plan.merged.phones.first?.label == "_$!<Mobile>!$_")
        #expect(plan.merged.emails.first?.label == "_$!<Home>!$_")
        #expect(plan.merged.phones.last?.label == "_$!<Work>!$_")
    }

    @Test func singleValuesComeFromTheKeeperAndFillItsGaps() throws {
        let plan = try MergePlanner.plan(cards: [keeper, other], keeperID: "k", choices: MergeChoices(nameFrom: "k"))
        #expect(plan.merged.givenName == "Aditya")
        // The keeper's organization stays, and its empty job title doesn't borrow another
        // company's title.
        #expect(plan.merged.organization == "Acme")
        #expect(plan.merged.jobTitle == "")
        #expect(plan.merged.nickname == "AK")
        #expect(plan.merged.birthday == DateComponents(year: 1994, month: 3, day: 4))
    }

    @Test func choicesAreHonored() throws {
        let plan = try MergePlanner.plan(
            cards: [keeper, other], keeperID: "k", choices: MergeChoices(nameFrom: "o", photoFrom: "o"))
        #expect(plan.merged.givenName == "Adi")
        #expect(plan.merged.id == "k")
        #expect(plan.merged.hasImage)
        #expect(plan.photoFromID == "o")
        #expect(plan.fieldSources[MergeField.name] == "o")
        #expect(plan.fieldSources[MergeField.photo] == "o")
    }

    @Test func theOnlyPhotoIsKeptWithoutAChoice() throws {
        let plan = try MergePlanner.plan(cards: [keeper, other], keeperID: "k", choices: MergeChoices(nameFrom: "k"))
        #expect(plan.merged.hasImage)
        #expect(plan.photoFromID == "o")
    }

    @Test func theKeepersOwnPhotoNeedsNoImageData() throws {
        var withPhoto = keeper
        withPhoto.hasImage = true
        let plan = try MergePlanner.plan(
            cards: [withPhoto, other], keeperID: "k", choices: MergeChoices(nameFrom: "k", photoFrom: "k"))
        #expect(plan.merged.hasImage)
        #expect(plan.photoFromID == nil)
        #expect(plan.fieldSources[MergeField.photo] == "k")
    }

    @Test func fieldSourcesSayWhereEachValueCameFrom() throws {
        let plan = try MergePlanner.plan(cards: [keeper, other], keeperID: "k", choices: MergeChoices(nameFrom: "k"))
        #expect(plan.fieldSources == [
            MergeField.name: "k",
            MergeField.organization: "k",
            MergeField.nickname: "o",
            MergeField.birthday: "o",
            MergeField.photo: "o",
            MergeField.phone(0): "k",
            MergeField.phone(1): "o",
            MergeField.email(0): "k",
            MergeField.postalAddress(0): "o",
            MergeField.url(0): "o",
        ])
        #expect(plan.addedFieldCount == 6)
    }

    @Test func myCardIsAlwaysTheKeeper() throws {
        var me = keeper
        me.isMe = true
        let plan = try MergePlanner.plan(cards: [me, other], keeperID: "o", choices: MergeChoices(nameFrom: "o"))
        #expect(plan.keeperID == "k")
        #expect(plan.removedIDs == ["o"])
        #expect(plan.merged.isMe)
    }

    @Test func cardsInOtherAccountsAreLeftOut() throws {
        var elsewhere = other
        elsewhere.containerID = "work"
        let plan = try MergePlanner.plan(cards: [keeper, elsewhere], keeperID: "k", choices: MergeChoices(nameFrom: "o"))
        #expect(plan.removedIDs.isEmpty)
        #expect(plan.merged == keeper)
        #expect(plan.addedFieldCount == 0)
    }

    @Test func urlsAndAddressesDedupeLoosely() throws {
        var a = keeper
        a.urls = [LabeledValue(label: nil, value: "example.com/")]
        a.postalAddresses = [LabeledPostal(street: "1 Main St", city: "Livermore")]
        var b = other
        b.urls = [LabeledValue(value: "WWW.Example.com"), LabeledValue(value: "other.org")]
        b.postalAddresses = [LabeledPostal(street: "1  main st", city: "LIVERMORE")]
        let plan = try MergePlanner.plan(cards: [a, b], keeperID: "k", choices: MergeChoices(nameFrom: "k"))
        #expect(plan.merged.urls.map(\.value) == ["example.com/", "other.org"])
        #expect(plan.merged.postalAddresses.count == 1)
    }

    @Test func plansSurviveCoding() throws {
        let plan = try MergePlanner.plan(
            cards: [keeper, other], keeperID: "k", choices: MergeChoices(nameFrom: "o", photoFrom: "o"))
        let data = try JSONEncoder().encode(plan)
        #expect(try JSONDecoder().decode(MergePlan.self, from: data) == plan)
    }

    @Test func oldCardsDecodeWithDefaults() throws {
        let json = Data(#"{"id":"x","givenName":"Ann"}"#.utf8)
        let decoded = try JSONDecoder().decode(ContactCard.self, from: json)
        #expect(decoded == ContactCard(id: "x", givenName: "Ann"))
    }

    @Test func numbersThatDialDifferentPhonesAreAllKept() throws {
        let a = card("a", given: "Ann", family: "Lee", phones: ["415 555 0100 x12", "*86", "+91 92512 34567"])
        let b = card("b", given: "Ann", family: "Lee", phones: [
            "415-555-0100 x13", "415 555 0100", "#86", "+1 925 123 4567", "1-800-FLOWERS", "1-800-CONTACTS",
            "(415) 555-0100 ext. 12",
        ])
        let plan = try MergePlanner.plan(cards: [a, b], keeperID: "a", choices: MergeChoices(nameFrom: "a"))
        #expect(plan.merged.phones.map(\.value) == [
            "415 555 0100 x12", "*86", "+91 92512 34567",
            "415-555-0100 x13", "415 555 0100", "#86", "+1 925 123 4567", "1-800-FLOWERS", "1-800-CONTACTS",
        ])
    }

    @Test func aNamelessChosenCardGivesWayToANamedOne() throws {
        let company = card("k", org: "Acme", phones: ["415 555 0123"])
        let person = card("p", given: "Ann", family: "Lee", suffix: "Jr.")
        let plan = try MergePlanner.plan(cards: [company, person], keeperID: "k", choices: MergeChoices(nameFrom: "k"))
        #expect(plan.merged.givenName == "Ann")
        #expect(plan.merged.familyName == "Lee")
        #expect(plan.merged.nameSuffix == "Jr.")
        #expect(plan.merged.organization == "Acme")
        #expect(plan.fieldSources[MergeField.name] == "p")
    }

    @Test func everyFieldOfTheRemovedCardsIsKept() throws {
        var a = card("a", given: "Ann", family: "Lee")
        a.relations = [LabeledValue(label: "_$!<Sister>!$_", value: "Ana")]
        a.socialProfiles = [LabeledSocialProfile(service: "Mastodon", username: "ann")]
        var b = card("b", given: "Ann", family: "Lee")
        b.previousFamilyName = "Ray"
        b.phoneticGivenName = "An"
        b.phoneticFamilyName = "Lee"
        b.dates = [LabeledDate(label: "_$!<Anniversary>!$_", date: DateComponents(year: 2020, month: 6, day: 1))]
        b.relations = [
            LabeledValue(label: "_$!<Sister>!$_", value: "ana"),
            LabeledValue(label: "_$!<Mother>!$_", value: "Ana"),
        ]
        b.socialProfiles = [
            LabeledSocialProfile(service: "mastodon", username: "Ann"),
            LabeledSocialProfile(service: "Bluesky", urlString: "x.example/ann"),
        ]
        b.instantMessages = [LabeledInstantMessage(service: "Skype", username: "ann.lee")]
        b.nonGregorianBirthday = CalendarDate(calendar: "hebrew", year: 5750, month: 7, day: 1)
        let plan = try MergePlanner.plan(cards: [a, b], keeperID: "a", choices: MergeChoices(nameFrom: "a"))
        let m = plan.merged
        #expect(m.previousFamilyName == "Ray")
        #expect(m.phoneticGivenName == "An" && m.phoneticFamilyName == "Lee")
        #expect(m.dates == b.dates)
        #expect(m.relations == [a.relations[0], b.relations[1]])
        #expect(m.socialProfiles == [a.socialProfiles[0], b.socialProfiles[1]])
        #expect(m.instantMessages == b.instantMessages)
        #expect(m.nonGregorianBirthday == b.nonGregorianBirthday)
        #expect(plan.removedBefore == [b])
        #expect(plan.fieldSources[MergeField.relation(1)] == "b")
        #expect(plan.fieldSources[MergeField.nonGregorianBirthday] == "b")
    }

    @Test func howANameIsSaidStaysWithThatName() throws {
        let a = card("a", given: "Ann", family: "Lee")
        var b = card("b", given: "Annie", family: "Lee")
        b.phoneticGivenName = "Ah-nee"
        let plan = try MergePlanner.plan(cards: [a, b], keeperID: "a", choices: MergeChoices(nameFrom: "a"))
        #expect(plan.merged.phoneticGivenName == "")
        let chosen = try MergePlanner.plan(cards: [a, b], keeperID: "a", choices: MergeChoices(nameFrom: "b"))
        #expect(chosen.merged.phoneticGivenName == "Ah-nee")
    }

    @Test func aBirthdayTakesItsYearFromAnotherCard() throws {
        let a = card("a", given: "Ann", family: "Lee", birthday: DateComponents(month: 3, day: 4))
        let b = card("b", given: "Ann", family: "Lee", birthday: DateComponents(year: 1994, month: 3, day: 4))
        let plan = try MergePlanner.plan(cards: [a, b], keeperID: "a", choices: MergeChoices(nameFrom: "a"))
        #expect(plan.merged.birthday == DateComponents(year: 1994, month: 3, day: 4))
        #expect(plan.fieldSources[MergeField.birthday] == "b")
        // Another day is another birthday: the keeper's stays.
        let c = card("c", given: "Ann", family: "Lee", birthday: DateComponents(year: 1994, month: 3, day: 5))
        let other = try MergePlanner.plan(cards: [a, c], keeperID: "a", choices: MergeChoices(nameFrom: "a"))
        #expect(other.merged.birthday == DateComponents(month: 3, day: 4))
    }

    @Test func aJobTitleComesOnlyFromTheSameOrganization() throws {
        let a = card("a", given: "Ann", family: "Lee", org: "Acme")
        let b = card("b", given: "Ann", family: "Lee", org: "ACME", department: "Tools", title: "Engineer")
        let plan = try MergePlanner.plan(cards: [a, b], keeperID: "a", choices: MergeChoices(nameFrom: "a"))
        #expect(plan.merged.organization == "Acme")
        #expect(plan.merged.jobTitle == "Engineer")
        #expect(plan.merged.department == "Tools")
        #expect(plan.fieldSources[MergeField.jobTitle] == "b")
    }

    @Test func noCardsAtAllThrows() {
        #expect(throws: ContactStoreError.cardNotFound(id: "k")) {
            try MergePlanner.plan(cards: [], keeperID: "k", choices: MergeChoices(nameFrom: "k"))
        }
    }

    @Test func plansSavedBeforeRemovedCardsWereKeptStillLoad() throws {
        let plan = try MergePlanner.plan(cards: [keeper, other], keeperID: "k", choices: MergeChoices(nameFrom: "k"))
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        object["removedBefore"] = nil
        let old = try JSONDecoder().decode(MergePlan.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.removedBefore.isEmpty)
        #expect(old.merged == plan.merged)
    }
}

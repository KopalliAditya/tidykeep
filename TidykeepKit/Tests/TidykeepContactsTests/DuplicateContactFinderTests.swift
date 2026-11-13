import Testing
import TidykeepContacts

@Suite struct DuplicateContactFinderTests {
    @Test func sameName() {
        let found = DuplicateContactFinder.find([
            card("a", given: "Aditya", family: "Kopalli", phones: ["415 555 0123"]),
            card("b", given: "aditya", family: "KOPALLI"),
            card("c", given: "Someone", family: "Else"),
        ])
        #expect(found.mergeable.count == 1)
        #expect(found.mergeable.first?.cardIDs == ["a", "b"])
        #expect(found.mergeable.first?.reasons == [.sameName])
        #expect(found.mergeable.first?.isCrossAccount == false)
        #expect(found.crossAccount.isEmpty)
    }

    @Test func samePhone() {
        let found = DuplicateContactFinder.find([
            card("a", given: "Bob", phones: ["+1 (415) 555-0123"]),
            card("b", given: "Robert", family: "Smith", phones: ["415.555.0123"]),
        ])
        #expect(found.mergeable.map(\.reasons) == [[.samePhone]])
    }

    @Test func sameEmail() {
        let found = DuplicateContactFinder.find([
            card("a", given: "Bob", emails: ["Bob@Example.com"]),
            card("b", given: "Robert", family: "Smith", emails: [" bob@example.com"]),
        ])
        #expect(found.mergeable.map(\.reasons) == [[.sameEmail]])
    }

    @Test func linksChainIntoOneGroup() {
        let found = DuplicateContactFinder.find([
            card("a", given: "Bob", phones: ["415 555 0123"]),
            card("b", given: "Robert", phones: ["(415) 555-0123"], emails: ["bob@example.com"]),
            card("c", given: "R", emails: ["BOB@example.com"]),
            card("d", given: "Dana", phones: ["650 555 0199"]),
        ])
        #expect(found.mergeable.count == 1)
        #expect(Set(found.mergeable[0].cardIDs) == ["a", "b", "c"])
        #expect(found.mergeable[0].reasons == [.samePhone, .sameEmail])
    }

    @Test func switchboardNumbersLinkNothing() {
        let office = "+1 800 555 0100"
        let found = DuplicateContactFinder.find([
            card("a", given: "Ann", family: "Lee", phones: [office]),
            card("b", given: "Ben", family: "Ray", phones: ["800-555-0100"]),
            card("c", given: "Cy", family: "Fox", phones: ["(800) 555 0100"]),
        ])
        #expect(found.mergeable.isEmpty)
        #expect(found.crossAccount.isEmpty)
    }

    @Test func switchboardCardsStillMatchByName() {
        let office = "+1 800 555 0100"
        let found = DuplicateContactFinder.find([
            card("a", given: "Ann", family: "Lee", phones: [office]),
            card("b", given: "Ann", family: "Lee", phones: [office]),
            card("c", given: "Cy", family: "Fox", phones: [office]),
        ])
        #expect(found.mergeable.count == 1)
        #expect(found.mergeable[0].cardIDs.sorted() == ["a", "b"])
        #expect(found.mergeable[0].reasons == [.sameName])
    }

    @Test func sharedInboxesLinkNothing() {
        let found = DuplicateContactFinder.find([
            card("a", given: "Ann", family: "Lee", emails: ["info@acme.example"]),
            card("b", given: "Ben", family: "Ray", emails: ["INFO@acme.example"]),
            card("c", given: "Cy", family: "Fox", emails: ["info@acme.example "]),
        ])
        #expect(found.mergeable.isEmpty)
    }

    @Test func twoCardsSharingANumberAreStillLinked() {
        let found = DuplicateContactFinder.find([
            card("a", given: "Ann", family: "Lee", phones: ["+1 800 555 0100"]),
            card("b", given: "A", phones: ["800-555-0100"]),
            card("c", given: "Cy", family: "Fox", phones: ["(800) 555 0199"]),
        ])
        #expect(found.mergeable.map { Set($0.cardIDs) } == [["a", "b"]])
    }

    @Test func aNumberListedTwiceOnOneCardCountsOnce() {
        let found = DuplicateContactFinder.find([
            card("a", given: "Ann", phones: ["415 555 0123", "+1 415 555 0123"]),
            card("b", given: "Annie", phones: ["4155550123"]),
        ])
        #expect(found.mergeable.map(\.reasons) == [[.samePhone]])
    }

    @Test func otherAccountsAreInfoOnly() {
        let found = DuplicateContactFinder.find([
            card("a", in: "phone", given: "Aditya", family: "Kopalli"),
            card("b", in: "work", given: "Aditya", family: "Kopalli"),
        ])
        #expect(found.mergeable.isEmpty)
        #expect(found.crossAccount.count == 1)
        #expect(found.crossAccount[0].isCrossAccount)
        #expect(Set(found.crossAccount[0].cardIDs) == ["a", "b"])
        #expect(found.crossAccount[0].reasons == [.sameName])
    }

    @Test func aGroupSpanningAccountsMergesOnlyWithinOne() {
        let found = DuplicateContactFinder.find([
            card("a", in: "phone", given: "Aditya", family: "Kopalli"),
            card("b", in: "phone", given: "Aditya", family: "Kopalli"),
            card("c", in: "work", given: "Aditya", family: "Kopalli"),
        ])
        #expect(found.mergeable.map { Set($0.cardIDs) } == [["a", "b"]])
        #expect(found.crossAccount.map { Set($0.cardIDs) } == [["a", "b", "c"]])
    }

    @Test func myCardIsTheKeeper() {
        let found = DuplicateContactFinder.find([
            card("a", given: "Aditya", family: "Kopalli", phones: ["415 555 0123", "650 555 0199"], emails: ["a@b.co"]),
            card("z", isMe: true, given: "Aditya", family: "Kopalli"),
        ])
        #expect(found.mergeable.first?.keeperID == "z")
        #expect(found.mergeable.first?.cardIDs == ["z", "a"])
    }

    @Test func keeperHasTheMostDetailsThenTheSmallestID() {
        let rich = DuplicateContactFinder.find([
            card("a", given: "Ann", family: "Lee"),
            card("b", given: "Ann", family: "Lee", phones: ["415 555 0123"]),
        ])
        #expect(rich.mergeable.first?.keeperID == "b")
        let tie = DuplicateContactFinder.find([
            card("m", given: "Ann", family: "Lee"),
            card("k", given: "Ann", family: "Lee"),
        ])
        #expect(tie.mergeable.first?.keeperID == "k")
        #expect(tie.mergeable.first?.cardIDs == ["k", "m"])
    }

    @Test func groupIDsAreStable() {
        let cards = [
            card("b", given: "Ann", family: "Lee"),
            card("a", given: "Ann", family: "Lee"),
            card("c", given: "Ann", family: "Lee"),
        ]
        let forward = DuplicateContactFinder.find(cards).mergeable.map(\.id)
        let backward = DuplicateContactFinder.find(cards.reversed()).mergeable.map(\.id)
        #expect(forward == backward)
        #expect(forward == [ContactDuplicateGroup.id(for: ["c", "a", "b"])])
    }

    @Test func oneWordNamesDoNotMatchOnTheirOwn() {
        let found = DuplicateContactFinder.find([card("a", given: "Mom"), card("b", given: "Mom")])
        #expect(found.mergeable.isEmpty)
    }

    @Test func fatherAndSonAreTwoPeople() {
        let found = DuplicateContactFinder.find([
            card("a", given: "John", family: "Smith", suffix: "Sr.", phones: ["415 555 0123"]),
            card("b", given: "John", family: "Smith", suffix: "Jr.", phones: ["(415) 555-0123"]),
        ])
        #expect(found.mergeable.isEmpty)
        #expect(found.crossAccount.isEmpty)
    }

    @Test func coworkersOnOneSwitchboardAreTwoPeople() {
        let lines = DuplicateContactFinder.find([
            card("a", given: "Ann", phones: ["+1 415 555 0100 ext. 12"]),
            card("b", given: "Ben", phones: ["415-555-0100 x13"]),
        ])
        #expect(lines.mergeable.isEmpty)
        // A direct line isn't the switchboard either.
        let switchboard = DuplicateContactFinder.find([
            card("a", given: "Ann", phones: ["+1 415 555 0100 ext. 12"]),
            card("c", given: "Acme", phones: ["415 555 0100"]),
        ])
        #expect(switchboard.mergeable.isEmpty)
        // The same extension written two ways is still one line.
        let same = DuplicateContactFinder.find([
            card("a", given: "Ann", phones: ["+1 415 555 0100 ext. 12"]),
            card("b", given: "A", phones: ["415-555-0100 x12"]),
        ])
        #expect(same.mergeable.map(\.reasons) == [[.samePhone]])
    }

    @Test func aSharedLandlineOrInboxDoesNotMakeACoupleOnePerson() {
        let found = DuplicateContactFinder.find([
            card("a", given: "Ann", family: "Lee", phones: ["415 555 0123"], emails: ["lees@example.com"]),
            card("b", given: "Ben", family: "Lee", phones: ["415.555.0123"], emails: ["Lees@example.com"]),
        ])
        #expect(found.mergeable.isEmpty)
        #expect(found.crossAccount.isEmpty)
    }

    @Test func shortFormsOfANameAreStillLinked() {
        let found = DuplicateContactFinder.find([
            card("a", given: "Aditya", family: "Kopalli", phones: ["415 555 0123"]),
            card("b", given: "Adi", family: "Kopalli", phones: ["(415) 555-0123"]),
            card("c", given: "J", family: "Smith", emails: ["js@example.com"]),
            card("d", given: "John", middle: "Q", family: "Smith", emails: ["JS@example.com"]),
        ])
        #expect(found.mergeable.map { Set($0.cardIDs) } == [["a", "b"], ["c", "d"]])
    }

    @Test func aChainNeverJoinsTwoDifferentPeople() {
        // Ann–"A." by phone and "A."–Ben by email would chain Ann and Ben into one group.
        let found = DuplicateContactFinder.find([
            card("a", given: "Ann", family: "Lee", phones: ["415 555 0123"]),
            card("b", given: "A.", phones: ["415 555 0123"], emails: ["lee@example.com"]),
            card("c", given: "Ben", family: "Lee", emails: ["lee@example.com"]),
        ])
        #expect(found.mergeable.map { Set($0.cardIDs) } == [["a", "b"]])
    }

    @Test func differentCountryCodesAreDifferentNumbers() {
        let found = DuplicateContactFinder.find([
            card("a", given: "Raj", phones: ["+91 92512 34567"]),
            card("b", given: "Sam", phones: ["+1 925 123 4567"]),
        ])
        #expect(found.mergeable.isEmpty)
        // A number without a code could be either, so it matches neither.
        let three = DuplicateContactFinder.find([
            card("a", given: "Raj", phones: ["+91 92512 34567"]),
            card("b", given: "Sam", phones: ["+1 925 123 4567"]),
            card("c", given: "Kim", phones: ["925 123 4567"]),
        ])
        #expect(three.mergeable.isEmpty)
        let national = DuplicateContactFinder.find([
            card("b", given: "Sam", phones: ["+1 925 123 4567"]),
            card("c", given: "S", phones: ["(925) 123-4567"]),
        ])
        #expect(national.mergeable.map(\.reasons) == [[.samePhone]])
    }

    @Test func departmentsOfOneCompanyAreNotDuplicates() {
        let found = DuplicateContactFinder.find([
            card("a", org: "Kaiser", department: "Pharmacy", phones: ["800 555 0101"]),
            card("b", org: "Kaiser", department: "Advice Nurse", phones: ["800 555 0102"]),
        ])
        #expect(found.mergeable.isEmpty)
        let same = DuplicateContactFinder.find([
            card("a", org: "Kaiser", department: "Pharmacy"),
            card("b", org: "KAISER", department: "pharmacy"),
        ])
        #expect(same.mergeable.map(\.reasons) == [[.sameName]])
    }
}

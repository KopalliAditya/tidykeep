import Foundation
import Testing
import TidykeepContacts

@Suite struct InMemoryContactStoreTests {
    let keeper = ContactCard(
        id: "k", containerID: "phone", containerName: "Phone", givenName: "Aditya", familyName: "Kopalli",
        organization: "Acme",
        phones: [LabeledValue(label: "_$!<Mobile>!$_", value: "+1 415 555 0123")],
        emails: [LabeledValue(label: "_$!<Home>!$_", value: "aditya@example.com")],
        hasImage: true
    )
    let second = ContactCard(
        id: "s", containerID: "phone", containerName: "Phone", givenName: "Adi", familyName: "Kopalli",
        nickname: "AK", jobTitle: "Engineer",
        phones: [
            LabeledValue(label: "_$!<Home>!$_", value: "(415) 555-0123"),
            LabeledValue(label: "_$!<Work>!$_", value: "650 555 0199"),
        ],
        postalAddresses: [LabeledPostal(
            label: "_$!<Home>!$_", street: "1 Main St\nApt 2", subLocality: "Old Town", city: "Livermore",
            subAdministrativeArea: "Alameda", state: "CA", postalCode: "94550", country: "USA",
            isoCountryCode: "us")],
        urls: [LabeledValue(label: "_$!<HomePage>!$_", value: "example.com")],
        dates: [LabeledDate(label: "_$!<Anniversary>!$_", date: DateComponents(year: 2020, month: 6, day: 1))],
        relations: [LabeledValue(label: "_$!<Sister>!$_", value: "Ana")],
        socialProfiles: [LabeledSocialProfile(service: "Mastodon", username: "adi", urlString: "x.example/adi")],
        instantMessages: [LabeledInstantMessage(service: "Skype", username: "adi.k")],
        birthday: DateComponents(year: 1994, month: 3, day: 4),
        nonGregorianBirthday: CalendarDate(calendar: "chinese", era: 78, year: 11, month: 1, day: 23), hasImage: true
    )
    let third = ContactCard(
        id: "t", containerID: "phone", containerName: "Phone", givenName: "Aditya", familyName: "Kopalli",
        emails: [LabeledValue(label: "my own label", value: "ak@work.example")],
        birthday: DateComponents(month: 12, day: 25)
    )
    let bystander = ContactCard(id: "x", containerID: "phone", givenName: "Dana", familyName: "Ray")

    func store() -> InMemoryContactStore {
        InMemoryContactStore(cards: [keeper, second, third, bystander], images: ["k": jpegA, "s": jpegB])
    }

    func plan(photoFrom: String? = "s") throws -> MergePlan {
        try MergePlanner.plan(
            cards: [keeper, second, third], keeperID: "k", choices: MergeChoices(nameFrom: "k", photoFrom: photoFrom))
    }

    @Test func applyThenUndoRestoresTheCardsExactly() async throws {
        let store = store()
        let plan = try plan()
        let backup = try await store.backup(ids: plan.backupIDs)
        try await store.apply(plan)

        let merged = await store.cards()
        #expect(merged.map(\.id) == ["k", "x"])
        #expect(merged.first == plan.merged)
        #expect(await store.imageData(for: "k") == jpegB)

        let restoredIDs = try await store.undo(plan, backup: backup)
        #expect(restoredIDs.count == 2)
        let after = await store.cards()
        // The keeper is reverted in place: same identifier, same fields.
        #expect(after.first { $0.id == "k" } == keeper)
        #expect(await store.imageData(for: "k") == jpegA)
        #expect(after.first { $0.id == "x" } == bystander)
        // The removed cards come back as new cards with their old fields.
        let restored = restoredIDs.compactMap { id in after.first { $0.id == id } }
        #expect(restored == [renamed(second, to: restoredIDs[0]), renamed(third, to: restoredIDs[1])])
        #expect(await store.imageData(for: restoredIDs[0]) == jpegB)
        #expect(await store.imageData(for: restoredIDs[1]) == nil)
        #expect(!restoredIDs.contains("s") && !restoredIDs.contains("t"))
    }

    @Test func undoKeepsLaterEditsTheMergeDidNotTouch() async throws {
        let store = store()
        let plan = try plan()
        let backup = try await store.backup(ids: plan.backupIDs)
        try await store.apply(plan)
        // The merge left the job title alone (the keeper's organization came with none).
        var edited = try #require(await store.cards().first { $0.id == "k" })
        edited.familyName = "K."
        edited.jobTitle = "Lead"
        await store.update(edited)
        _ = try await store.undo(plan, backup: backup)
        let keeperNow = try #require(await store.cards().first { $0.id == "k" })
        #expect(keeperNow.familyName == "K.")
        #expect(keeperNow.jobTitle == "Lead")
        #expect(keeperNow.phones == keeper.phones)
        #expect(keeperNow.nickname == "")
    }

    @Test func undoAsksBeforeOverwritingAConflictingEdit() async throws {
        let store = store()
        let plan = try plan()
        let backup = try await store.backup(ids: plan.backupIDs)
        try await store.apply(plan)
        var edited = try #require(await store.cards().first { $0.id == "k" })
        edited.phones.append(LabeledValue(value: "408 555 0111"))
        await store.update(edited)

        await #expect(throws: ContactStoreError.keeperChangedSinceMerge(fields: ["phones"])) {
            try await store.undo(plan, backup: backup)
        }
        // Nothing changed: the removed cards are still gone.
        #expect(await store.cards().count == 2)

        _ = try await store.undo(plan, backup: backup, overwritingLaterEdits: true)
        #expect(await store.cards().first { $0.id == "k" } == keeper)
        #expect(await store.cards().count == 4)
    }

    @Test func undoRecreatesADeletedKeeperOnlyWhenAsked() async throws {
        let store = InMemoryContactStore(cards: [keeper, second], images: ["k": jpegA, "s": jpegB])
        let plan = try MergePlanner.plan(cards: [keeper, second], keeperID: "k", choices: MergeChoices(nameFrom: "k"))
        let backup = try await store.backup(ids: plan.backupIDs)
        try await store.apply(plan)
        let fresh = InMemoryContactStore(cards: [], images: [:])
        await #expect(throws: ContactStoreError.keeperMissing) {
            try await fresh.undo(plan, backup: backup)
        }
        let ids = try await fresh.undo(plan, backup: backup, overwritingLaterEdits: true)
        let cards = await fresh.cards()
        #expect(cards == [renamed(keeper, to: ids[0]), renamed(second, to: ids[1])])
    }

    @Test func applyRefusesAStalePreview() async throws {
        let store = store()
        let plan = try plan()
        var edited = keeper
        edited.nickname = "New"
        await store.update(edited)
        await #expect(throws: ContactStoreError.changedSincePreview(id: "k")) {
            try await store.apply(plan)
        }
        #expect(await store.cards().count == 4)
    }

    @Test func applyRefusesAnotherAccount() async throws {
        let store = store()
        let plan = try plan()
        var moved = third
        moved.containerID = "work"
        await store.update(moved)
        await #expect(throws: ContactStoreError.crossAccount(id: "t")) {
            try await store.apply(plan)
        }
        #expect(await store.cards().count == 4)
    }

    @Test func applyNeverRemovesMyCard() async throws {
        let store = store()
        let plan = try plan()
        // The third card became My Card after the preview was made.
        var me = third
        me.isMe = true
        await store.update(me)
        await #expect(throws: ContactStoreError.myCardNotKeeper(id: "t")) {
            try await store.apply(plan)
        }
        #expect(await store.cards().count == 4)
    }

    @Test func anyStoreUndoesTheSameWay() async throws {
        let store: any ContactStoring = store()
        let plan = try plan(photoFrom: nil)
        let backup = try await store.backup(ids: plan.backupIDs)
        try await store.apply(plan)
        let ids = try await store.undo(plan, backup: backup)
        let cards = try await store.fetchCards()
        #expect(cards.first { $0.id == "k" } == keeper)
        #expect(ids.compactMap { id in cards.first { $0.id == id } }
            == [renamed(second, to: ids[0]), renamed(third, to: ids[1])])
    }

    @Test func applyRefusesAGoneCard() async throws {
        let store = InMemoryContactStore(cards: [keeper, second])
        await #expect(throws: ContactStoreError.cardNotFound(id: "t")) {
            try await store.apply(try plan())
        }
    }

    @Test func undoNeedsTheRemovedCardsInTheBackup() async throws {
        let store = store()
        let plan = try plan()
        let partial = try await store.backup(ids: ["k", "s"])
        try await store.apply(plan)
        await #expect(throws: ContactStoreError.backupMissingCards(["t"])) {
            try await store.undo(plan, backup: partial)
        }
    }

    @Test func undoWithoutAMergeIsRefused() async throws {
        let store = store()
        let plan = try plan()
        let backup = try await store.backup(ids: plan.backupIDs)
        await #expect(throws: ContactStoreError.notMerged) {
            try await store.undo(plan, backup: backup)
        }
    }

    @Test func accessIsChecked() async throws {
        let denied = InMemoryContactStore(cards: [keeper], access: .denied)
        await #expect(throws: ContactStoreError.notAuthorized) { try await denied.fetchCards() }
        #expect(try await denied.requestAccess() == .denied)

        let undecided = InMemoryContactStore(cards: [keeper], access: .notDetermined)
        #expect(undecided.authorization() == .notDetermined)
        #expect(try await undecided.requestAccess() == .full)
        #expect(try await undecided.fetchCards() == [keeper])
    }

    @Test func findPlanApplyEndToEnd() async throws {
        let store = store()
        let found = DuplicateContactFinder.find(try await store.fetchCards())
        let group = try #require(found.mergeable.first)
        #expect(Set(group.cardIDs) == ["k", "s", "t"])
        let cards = try await store.fetchCards().filter { group.cardIDs.contains($0.id) }
        let plan = try MergePlanner.plan(cards: cards, keeperID: group.keeperID, choices: MergeChoices(nameFrom: group.keeperID))
        try await store.apply(plan)
        #expect(DuplicateContactFinder.find(try await store.fetchCards()).mergeable.isEmpty)
    }

    @Test func applyRefusesARemovedCardChangedSinceThePreview() async throws {
        let store = store()
        let plan = try plan()
        // A number synced to the second card after the preview would be deleted with it.
        var edited = second
        edited.phones.append(LabeledValue(value: "408 555 0111"))
        await store.update(edited)
        await #expect(throws: ContactStoreError.changedSincePreview(id: "s")) {
            try await store.apply(plan)
        }
        #expect(await store.cards().count == 4)
    }

    @Test func applyRefusesWhenThePhotoToTakeIsGone() async throws {
        let store = store()
        let plan = try plan(photoFrom: "s")
        var edited = second
        edited.hasImage = false
        await store.update(edited)
        await #expect(throws: ContactStoreError.changedSincePreview(id: "s")) {
            try await store.apply(plan)
        }
        #expect(await store.imageData(for: "k") == jpegA)
    }

    @Test func groupsCarryOverAndComeBack() async throws {
        let store = InMemoryContactStore(
            cards: [keeper, second, third, bystander], images: ["k": jpegA, "s": jpegB],
            groups: ["family": ["s", "x"], "work": ["k", "t"], "club": ["s"]])
        let plan = try plan()
        let backup = try await store.backup(ids: plan.backupIDs)
        try await store.apply(plan)
        // The person stays in Family after the merge.
        #expect(await store.groupIDs(of: "k") == ["club", "family", "work"])
        #expect(await store.groupIDs(of: "s").isEmpty)

        let ids = try await store.undo(plan, backup: backup)
        // The keeper leaves only the groups the merge added it to.
        #expect(await store.groupIDs(of: "k") == ["work"])
        #expect(await store.groupIDs(of: ids[0]) == ["club", "family"])
        #expect(await store.groupIDs(of: ids[1]) == ["work"])
        #expect(await store.groupIDs(of: "x") == ["family"])
    }

    @Test func aKeeperNoLongerSharedIsNotReCreated() async throws {
        let store = store()
        let plan = try plan()
        let backup = try await store.backup(ids: plan.backupIDs)
        try await store.apply(plan)
        // With limited access, a card the app can't see may well still exist.
        let limited = InMemoryContactStore(cards: [bystander], access: .limited)
        await #expect(throws: ContactStoreError.keeperNotVisible) {
            try await limited.undo(plan, backup: backup, overwritingLaterEdits: true)
        }
        #expect(await limited.cards() == [bystander])
    }
}

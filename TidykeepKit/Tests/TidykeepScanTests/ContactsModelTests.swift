import Foundation
import Testing
import TidykeepContacts
import TidykeepCore
import TidykeepFolderSource
@testable import TidykeepUI
import TidykeepVision

/// The contacts model against an address book in memory: access, the check, merge with its
/// backup and receipt, undo, the simulator's sample cards and reset.
@MainActor @Suite struct ContactsModelTests {
    let data = temporaryDirectory("contacts-\(UUID().uuidString)")

    static let jordan = ContactCard(
        id: "j1", containerID: "icloud", containerName: "iCloud", givenName: "Jordan", familyName: "Rivera",
        phones: [LabeledValue(label: "_$!<Mobile>!$_", value: "+1 415 555 0134")])
    static let jordanWork = ContactCard(
        id: "j2", containerID: "icloud", containerName: "iCloud", givenName: "Jordan", familyName: "Rivera",
        phones: [LabeledValue(label: "_$!<Work>!$_", value: "(415) 555-0134")],
        emails: [LabeledValue(label: "_$!<Work>!$_", value: "jordan@rivera.example")])
    static let dana = ContactCard(id: "d", containerID: "icloud", containerName: "iCloud", givenName: "Dana", familyName: "Ray")

    func model(_ store: InMemoryContactStore, directory: URL? = nil) -> (ContactsModel, History, Notices) {
        let history = History(directory: directory)
        let notices = Notices()
        let model = ContactsModel(
            directory: directory, preferences: Preferences(defaults: freshDefaults()), history: history,
            notices: notices, store: store)
        return (model, history, notices)
    }

    func pair() -> InMemoryContactStore {
        InMemoryContactStore(cards: [Self.jordan, Self.jordanWork, Self.dana])
    }

    func jordans(_ store: InMemoryContactStore) async -> [ContactCard] {
        await store.cards().filter(ContactsModel.isSample)
    }

    // MARK: Access

    @Test func accessMapsLimitedToAllowedAndRestrictedToOff() async {
        #expect(ContactsModel.access(.notDetermined) == .notDetermined)
        #expect(ContactsModel.access(.full) == .allowed)
        #expect(ContactsModel.access(.limited) == .allowed)
        #expect(ContactsModel.access(.denied) == .denied)
        #expect(ContactsModel.access(.restricted) == .denied)

        let (limited, _, _) = model(InMemoryContactStore(cards: [Self.jordan, Self.jordanWork], access: .limited))
        await limited.start()
        #expect(limited.access == .allowed)
        #expect(limited.isLimited)
        #expect(limited.duplicateGroupCount == 1)

        let (restricted, _, _) = model(InMemoryContactStore(cards: [Self.jordan, Self.jordanWork], access: .restricted))
        await restricted.start()
        #expect(restricted.access == .denied)
        #expect(restricted.groups.isEmpty)
    }

    @Test func startNeverAsksAndContinueDoes() async {
        let store = InMemoryContactStore(cards: [Self.jordan, Self.jordanWork], access: .notDetermined)
        let (model, _, _) = model(store)
        await model.start()
        #expect(model.access == .notDetermined)
        #expect(store.authorization() == .notDetermined)
        #expect(model.groups.isEmpty)

        await model.requestAccess()
        #expect(model.access == .allowed)
        #expect(model.duplicateGroupCount == 1)
    }

    // MARK: Checking

    @Test func scanFindsThePair() async throws {
        let (model, _, _) = model(pair())
        await model.start()
        #expect(model.hasChecked)
        #expect(!model.isScanning)
        #expect(model.checkedCount == 3)
        #expect(model.duplicateGroupCount == 1)
        #expect(model.extraCardCount == 1)
        let group = try #require(model.groups.first)
        #expect(Set(group.cardIDs) == ["j1", "j2"])
        #expect(group.reasons.contains(.samePhone))
        #expect(group.reasons.contains(.sameName))
        #expect(model.name(of: group) == "Jordan Rivera")
        #expect(model.accounts(of: group) == ["iCloud"])
        #expect(Copy.Contacts.reasons(group.reasons) == "Same phone · Same name")
    }

    @Test func crossAccountGroupsAreShownButNotMergeable() async throws {
        var gmail = Self.jordanWork
        gmail.containerID = "gmail"
        gmail.containerName = "Gmail"
        let store = InMemoryContactStore(cards: [Self.jordan, gmail])
        let (model, history, _) = model(store)
        await model.start()
        #expect(model.groups.isEmpty)
        #expect(model.duplicateGroupCount == 0)
        let cross = try #require(model.crossAccountGroups.first)
        #expect(cross.isCrossAccount)
        #expect(Set(model.accounts(of: cross)) == ["iCloud", "Gmail"])

        let merged = await model.merge(cross.id, keeperID: cross.keeperID, choices: MergeChoices(nameFrom: cross.keeperID))
        #expect(!merged)
        #expect(history.receipts.isEmpty)
        #expect(await store.cards().count == 2)
    }

    // MARK: Merging

    @Test func mergeBacksUpRecordsAndNotices() async throws {
        let store = pair()
        let (model, history, notices) = model(store, directory: data)
        await model.start()
        let group = try #require(model.groups.first)

        let merged = await model.merge(group.id, keeperID: group.keeperID, choices: MergeChoices(nameFrom: group.keeperID))
        #expect(merged)

        let receipt = try #require(history.receipts.first)
        #expect(receipt.kind == .contactsMerged)
        #expect(receipt.status == .done)
        #expect(receipt.requested == 2)
        #expect(receipt.title == "Jordan Rivera")
        #expect(Copy.Receipts.sentence(receipt) == "Merged 2 cards into Jordan Rivera")
        let record = try JSONDecoder().decode(ContactMergeRecord.self, from: try #require(receipt.payload))
        #expect(record.plan.keeperID == group.keeperID)
        #expect(receipt.itemIDs == record.plan.removedIDs)
        let backup = data.appendingPathComponent("ContactBackups/\(record.backupID.uuidString).vcf")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(model.backupCount == 1)

        let text = try #require(notices.text)
        #expect(text.hasPrefix("Merged 2 cards"))
        #expect(notices.current?.undo != nil)

        #expect(model.extraCardCount == 0)
        #expect(model.groups.isEmpty)
        let left = await jordans(store)
        #expect(left.count == 1)
        #expect(left.first?.emails.map(\.value) == ["jordan@rivera.example"])
    }

    @Test func undoRestoresBothCards() async throws {
        let store = pair()
        let (model, history, notices) = model(store, directory: data)
        await model.start()
        let group = try #require(model.groups.first)
        await model.merge(group.id, keeperID: group.keeperID, choices: MergeChoices(nameFrom: group.keeperID))
        let receipt = try #require(history.receipts.first)

        await model.undo(receipt)

        #expect(await jordans(store).count == 2)
        #expect(history.receipt(receipt.id)?.status == .undone)
        #expect(notices.text == "Undone. Jordan Rivera is back to 2 cards.")
        await model.start()
        #expect(model.duplicateGroupCount == 1)

        // A second undo of the same receipt does nothing.
        await model.undo(try #require(history.receipt(receipt.id)))
        #expect(await jordans(store).count == 2)
    }

    @Test func undoAsksBeforeReplacingLaterEdits() async throws {
        let store = pair()
        let (model, history, notices) = model(store, directory: data)
        await model.start()
        let group = try #require(model.groups.first)
        // Card j1 stays and gains j2's email, so a later email edit conflicts with the undo.
        await model.merge(group.id, keeperID: "j1", choices: MergeChoices(nameFrom: "j1"))
        let receipt = try #require(history.receipts.first)

        var edited = try #require(await store.cards().first { $0.id == "j1" })
        edited.emails = [LabeledValue(value: "new@rivera.example")]
        await store.update(edited)

        await model.undo(receipt)
        #expect(notices.text == Copy.Contacts.keeperEdited("Jordan Rivera"))
        #expect(notices.current?.undo?.title == Copy.Contacts.undoAnyway)
        #expect(history.receipt(receipt.id)?.status == .done)
        #expect(await jordans(store).count == 1)
        let noted = try JSONDecoder().decode(ContactMergeRecord.self, from: try #require(history.receipt(receipt.id)?.payload))
        #expect(noted.undoProblem == .keeperEdited)

        await notices.current?.undo?.action()
        #expect(history.receipt(receipt.id)?.status == .undone)
        #expect(await jordans(store).count == 2)
    }

    @Test func aChangedCardStopsTheMergeAndChangesNothing() async throws {
        let store = pair()
        let (model, history, _) = model(store, directory: data)
        await model.start()
        let group = try #require(model.groups.first)
        var changed = try #require(await store.cards().first { $0.id == group.otherIDs.first })
        changed.phones.append(LabeledValue(value: "650 555 0101"))
        await store.update(changed)

        let merged = await model.merge(group.id, keeperID: group.keeperID, choices: MergeChoices(nameFrom: group.keeperID))
        #expect(!merged)
        #expect(model.problems[group.id] == .changed)
        #expect(history.receipts.isEmpty)
        #expect(model.backupCount == 0)
        #expect(await jordans(store).count == 2)

        model.checkAgain(group.id)
        await model.start()
        #expect(model.problems[group.id] == nil)
        #expect(model.duplicateGroupCount == 1)
    }

    @Test func undoWithoutItsBackupSaysSo() async throws {
        let store = pair()
        let (model, history, notices) = model(store, directory: data)
        await model.start()
        let group = try #require(model.groups.first)
        await model.merge(group.id, keeperID: group.keeperID, choices: MergeChoices(nameFrom: group.keeperID))
        model.deleteBackups()
        #expect(model.backupCount == 0)

        await model.undo(try #require(history.receipts.first))
        #expect(notices.text == Copy.Contacts.backupGone)
        #expect(history.receipts.first?.status == .done)
        #expect(await jordans(store).count == 1)
    }

    @Test func stillThereSaysWhetherTheMergeHappened() async throws {
        let store = pair()
        let (model, history, _) = model(store)
        await model.start()
        let notSaved = history.begin(.contactsMerged, requested: 2, itemIDs: ["j2"], title: "Jordan Rivera")
        #expect(await model.stillThere(try #require(history.receipt(notSaved))) == 2)
        let saved = history.begin(.contactsMerged, requested: 2, itemIDs: ["gone"], title: "Jordan Rivera")
        #expect(await model.stillThere(try #require(history.receipt(saved))) == 0)
    }

    // MARK: Keeping apart

    @Test func keptApartGroupsStayHiddenUntilSuggestedAgain() async throws {
        let (model, _, notices) = model(pair(), directory: data)
        await model.start()
        let group = try #require(model.groups.first)
        model.keepApart(group.id)
        #expect(model.duplicateGroupCount == 0)
        #expect(notices.text == Copy.Contacts.keptBoth)

        let (again, _, _) = self.model(pair(), directory: data)
        await again.start()
        #expect(again.groups.isEmpty)
        again.suggestAgain()
        #expect(again.duplicateGroupCount == 1)
    }

    // MARK: Sample cards

    @Test func seedSampleTopsUpToTwoAndIsIdempotent() async throws {
        let store = InMemoryContactStore(cards: [Self.dana])
        let (model, _, _) = model(store)
        model.seedSample()
        await model.start()
        #expect(await jordans(store).count == 2)
        #expect(model.duplicateGroupCount == 1)

        model.seedSample()
        model.seedSample()
        await model.start()
        #expect(await jordans(store).count == 2)
        #expect(await store.cards().count == 3)

        // After a merge leaves one, the next launch adds one back.
        let group = try #require(model.groups.first)
        await model.merge(group.id, keeperID: group.keeperID, choices: MergeChoices(nameFrom: group.keeperID))
        #expect(await jordans(store).count == 1)
        model.seedSample()
        await model.start()
        #expect(await jordans(store).count == 2)
    }

    @Test func seedSampleWaitsForAccess() async {
        let denied = InMemoryContactStore(access: .denied)
        let (off, _, _) = model(denied)
        off.seedSample()
        await off.start()
        #expect(await denied.cards().isEmpty)

        let undecided = InMemoryContactStore(access: .notDetermined)
        let (model, _, _) = model(undecided)
        model.seedSample()
        await model.start()
        #expect(await undecided.cards().isEmpty)
        await model.requestAccess()
        #expect(await jordans(undecided).count == 2)
        #expect(model.duplicateGroupCount == 1)
    }

    // MARK: Reset

    @Test func resetClearsBackupsButNeverCards() async throws {
        let store = pair()
        let defaults = freshDefaults()
        let photos = temporaryDirectory("contacts-photos-\(UUID().uuidString)")
        let first = AppState(photoSource: FolderPhotoSource(folder: photos), analyzer: VisionFrameAnalyzer(), directory: data, defaults: defaults, contactStore: store)
        await first.contacts.start()
        let group = try #require(first.contacts.groups.first)
        first.contacts.keepApart(group.id)
        first.contacts.suggestAgain()
        await first.contacts.merge(group.id, keeperID: group.keeperID, choices: MergeChoices(nameFrom: group.keeperID))
        #expect(first.contacts.backupCount == 1)
        let cardsBefore = await store.cards()

        defaults.set(true, forKey: "TKResetState")
        let second = AppState(photoSource: FolderPhotoSource(folder: photos), analyzer: VisionFrameAnalyzer(), directory: data, defaults: defaults, contactStore: store)
        #expect(second.contacts.backupCount == 0)
        #expect(second.history.receipts.isEmpty)
        #expect(await store.cards() == cardsBefore)
    }

    // MARK: Words

    @Test func labelsAndSentencesReadPlainly() {
        #expect(Copy.Contacts.label("_$!<Mobile>!$_") == "mobile")
        #expect(Copy.Contacts.label("_$!<HomeFAX>!$_") == "home fax")
        #expect(Copy.Contacts.label("_$!<SomethingNew>!$_") == "something new")
        #expect(Copy.Contacts.label("Grandma's") == "Grandma's")
        #expect(Copy.Contacts.label(nil) == nil)
        #expect(Copy.Contacts.why([.sameName, .samePhone]) == "Same phone number and same name.")
        #expect(Copy.Contacts.notesCaveat([1]) == "Notes can't be checked. If card 2 has notes, copy them first.")
        #expect(Copy.Contacts.confirmTitle([1, 2]) == "Notes on cards 2 and 3 can't be checked")
        #expect(Copy.Contacts.mergeButton(2) == "Merge 2 cards")
        #expect(Copy.Contacts.merged(2, into: "Jordan Rivera") == "Merged 2 cards into Jordan Rivera.")
        #expect(Copy.Contacts.initials(Self.jordan) == "JR")
        let address = LabeledPostal(street: "1 Main St\nApt 2", city: "Livermore", state: "CA", postalCode: "94550")
        #expect(Copy.Contacts.address(address) == "1 Main St, Apt 2, Livermore, CA 94550")
    }
}

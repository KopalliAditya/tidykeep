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

    var backups: ContactBackupStore {
        ContactBackupStore(directory: data.appendingPathComponent("ContactBackups", isDirectory: true))
    }

    /// Every file in the backups folder, by name.
    func backupFileNames() -> [String] {
        let names = try? FileManager.default.contentsOfDirectory(atPath: backups.directory.path(percentEncoded: false))
        return (names ?? []).sorted()
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
        #expect(restricted.isRestricted)
        #expect(restricted.groups.isEmpty)
        #expect(Copy.Contacts.accessValue(restricted.access, limited: false, restricted: true) == "Restricted")

        let (denied, _, _) = model(InMemoryContactStore(access: .denied))
        await denied.start()
        #expect(!denied.isRestricted)
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
        let backup = data.appendingPathComponent("ContactBackups/\(record.backupID.uuidString).vcf")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        // The plan is saved next to the backup, not in the receipt.
        let plan = try backups.loadPlan(id: record.backupID)
        #expect(plan.keeperID == group.keeperID)
        #expect(receipt.itemIDs == plan.removedIDs)
        #expect(backupFileNames() == ["\(record.backupID.uuidString).plan.json", "\(record.backupID.uuidString).vcf"])
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

    @Test func receiptsHoldTheNameAndCardIDsOnly() async throws {
        let store = pair()
        let (model, history, _) = model(store, directory: data)
        await model.start()
        let group = try #require(model.groups.first)
        await model.merge(group.id, keeperID: "j1", choices: MergeChoices(nameFrom: "j1"))

        let receipt = try #require(history.receipts.first)
        let payload = try #require(receipt.payload)
        let fields = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(Set(fields.keys) == ["backupID", "groupID"])
        #expect(fields["groupID"] as? String == "j1|j2")
        #expect(receipt.title == "Jordan Rivera")
        #expect(receipt.itemIDs == ["j2"])
        // Nothing of the cards' details is in History's file, nor in the payloads it holds as
        // base64, which a plain search of the file can't see into.
        let file = try Data(contentsOf: data.appendingPathComponent("history.json"))
        let saved = String(decoding: file, as: UTF8.self)
        let payloads = try JSONDecoder().decode(ReceiptLog.self, from: file).receipts.compactMap(\.payload)
        #expect(payloads == [payload])
        for text in [saved] + payloads.map({ String(decoding: $0, as: UTF8.self) }) {
            for detail in ["415 555 0134", "(415) 555-0134", "rivera.example", "Mobile", "givenName", "phones", "emails", "keeperBefore", "\"Jordan\""] {
                #expect(!text.contains(detail), "history.json holds \(detail)")
            }
        }
        #expect(saved.contains("Jordan Rivera"))
    }

    @Test func anOldReceiptWithThePlanInsideDoesntCrashUndo() async throws {
        let store = pair()
        let (model, history, notices) = model(store, directory: data)
        await model.start()
        let group = try #require(model.groups.first)
        await model.merge(group.id, keeperID: "j1", choices: MergeChoices(nameFrom: "j1"))
        let receipt = try #require(history.receipts.first)
        let record = try JSONDecoder().decode(ContactMergeRecord.self, from: try #require(receipt.payload))

        // As a build before the plan moved next to the backup left it: the plan in the
        // receipt, and only the vCard in the folder.
        struct OldRecord: Encodable {
            var plan: MergePlan
            var backupID: UUID
            var groupID: String
        }
        let old = OldRecord(plan: try backups.loadPlan(id: record.backupID), backupID: record.backupID, groupID: record.groupID)
        try FileManager.default.removeItem(at: backups.planURL(record.backupID))
        history.update(receipt.id) { $0.payload = try? JSONEncoder().encode(old) }
        let decoded = try JSONDecoder().decode(ContactMergeRecord.self, from: try #require(history.receipt(receipt.id)?.payload))
        #expect(decoded.backupID == record.backupID)

        await model.undo(try #require(history.receipt(receipt.id)))
        #expect(notices.text == Copy.Contacts.backupGone)
        #expect(history.receipt(receipt.id)?.status == .done)
        #expect(await jordans(store).count == 1)
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

    @Test func undoAfterARelaunchReadsThePlanFromBesideTheBackup() async throws {
        let store = pair()
        let (model, history, _) = model(store, directory: data)
        await model.start()
        let group = try #require(model.groups.first)
        await model.merge(group.id, keeperID: "j1", choices: MergeChoices(nameFrom: "j1"))
        let id = try #require(history.receipts.first?.id)

        let (later, laterHistory, notices) = self.model(store, directory: data)
        await later.start()
        #expect(later.backupCount == 1)
        await later.undo(try #require(laterHistory.receipt(id)))
        #expect(notices.text == "Undone. Jordan Rivera is back to 2 cards.")
        #expect(laterHistory.receipt(id)?.status == .undone)
        let back = await jordans(store)
        #expect(back.count == 2)
        #expect(back.contains { $0.id == "j1" && $0.emails.isEmpty })
    }

    @Test func undoWithoutItsPlanSaysSo() async throws {
        let store = pair()
        let (model, history, notices) = model(store, directory: data)
        await model.start()
        let group = try #require(model.groups.first)
        await model.merge(group.id, keeperID: group.keeperID, choices: MergeChoices(nameFrom: group.keeperID))
        let receipt = try #require(history.receipts.first)
        let record = try JSONDecoder().decode(ContactMergeRecord.self, from: try #require(receipt.payload))
        try FileManager.default.removeItem(at: backups.planURL(record.backupID))

        await model.undo(receipt)
        #expect(notices.text == Copy.Contacts.backupGone)
        #expect(history.receipts.first?.status == .done)
        #expect(await jordans(store).count == 1)
    }

    @Test func undoAsksBeforeReplacingAPhotoSetAfterTheMerge() async throws {
        let photo = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 0xB2, count: 300))
        var withPhoto = Self.jordanWork
        withPhoto.hasImage = true
        let store = InMemoryContactStore(cards: [Self.jordan, withPhoto], images: ["j2": photo])
        let (model, history, _) = model(store, directory: data)
        await model.start()
        let group = try #require(model.groups.first)
        await model.merge(group.id, keeperID: "j1", choices: MergeChoices(nameFrom: "j1", photoFrom: "j2"))
        #expect(await store.imageData(for: "j1") == photo)
        let receipt = try #require(history.receipts.first)

        let later = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 0xC3, count: 300))
        await store.setImageData(later, for: "j1")
        await model.undo(receipt)
        let conflict = try #require(model.pendingUndoConflict)
        #expect(conflict.text == Copy.Contacts.keeperEdited("Jordan Rivera"))
        #expect(await store.imageData(for: "j1") == later)
        #expect(await jordans(store).count == 1)

        await model.confirmUndo(conflict)
        #expect(history.receipt(receipt.id)?.status == .undone)
        #expect(await store.imageData(for: "j1") == nil)
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
        let conflict = try #require(model.pendingUndoConflict)
        #expect(conflict.receiptID == receipt.id)
        #expect(conflict.text == Copy.Contacts.keeperEdited("Jordan Rivera"))
        #expect(conflict.button == Copy.Contacts.undoAnyway)
        #expect(history.receipt(receipt.id)?.status == .done)
        #expect(await jordans(store).count == 1)
        let noted = try JSONDecoder().decode(ContactMergeRecord.self, from: try #require(history.receipt(receipt.id)?.payload))
        #expect(noted.undoProblem == .keeperEdited)

        // Cancel leaves the merge as it is; Undo in History asks again.
        model.cancelPendingUndo()
        #expect(model.pendingUndoConflict == nil)
        #expect(history.receipt(receipt.id)?.status == .done)
        await model.undo(try #require(history.receipt(receipt.id)))
        let again = try #require(model.pendingUndoConflict)

        await model.confirmUndo(again)
        #expect(model.pendingUndoConflict == nil)
        #expect(history.receipt(receipt.id)?.status == .undone)
        #expect(await jordans(store).count == 2)
    }

    @Test func aFailedCheckSaysSoAndCanBeTriedAgain() async {
        let store = FlakyContactStore(InMemoryContactStore(cards: [Self.jordan, Self.jordanWork]))
        store.failsToRead = true
        let history = History(directory: nil)
        let model = ContactsModel(
            directory: nil, preferences: Preferences(defaults: freshDefaults()), history: history,
            notices: Notices(), store: store)
        await model.start()
        #expect(model.scanFailed)
        #expect(!model.hasChecked)
        #expect(!model.isScanning)

        store.failsToRead = false
        await model.checkAgainAndWait()
        #expect(!model.scanFailed)
        #expect(model.hasChecked)
        #expect(model.duplicateGroupCount == 1)
    }

    @Test func backupsWithoutAReceiptAreDeleted() async throws {
        let store = pair()
        let (model, history, _) = model(store, directory: data)
        await model.start()
        let group = try #require(model.groups.first)
        await model.merge(group.id, keeperID: group.keeperID, choices: MergeChoices(nameFrom: group.keeperID))
        #expect(model.backupCount == 1)

        let kept = backupFileNames()
        #expect(kept.count == 2)

        // A backup and its plan left by a merge cut off before it was recorded, and a plan
        // left on its own.
        let plan = try backups.loadPlan(id: try #require(backups.savedIDs().first))
        let cutOff = UUID()
        _ = try backups.save(Data("BEGIN:VCARD\nEND:VCARD\n".utf8), id: cutOff)
        try backups.savePlan(plan, id: cutOff)
        try backups.savePlan(plan, id: UUID())
        let (later, _, _) = self.model(store, directory: data)
        #expect(later.backupCount == 2)
        await later.start()
        #expect(later.backupCount == 1)
        #expect(backupFileNames() == kept)

        // Clearing History leaves nothing to undo with, so its backups go too.
        history.clear()
        let (cleared, _, _) = self.model(store, directory: data)
        await cleared.start()
        #expect(cleared.backupCount == 0)
        #expect(backupFileNames().isEmpty)
    }

    @Test func deleteBackupsTakesThePlansToo() async throws {
        let store = InMemoryContactStore(cards: [Self.jordan, Self.jordanWork, Self.dana, ContactCard(
            id: "d2", containerID: "icloud", containerName: "iCloud", givenName: "Dana", familyName: "Ray")])
        let (model, _, _) = model(store, directory: data)
        await model.start()
        #expect(model.groups.count == 2)
        for group in model.groups {
            await model.merge(group.id, keeperID: group.keeperID, choices: MergeChoices(nameFrom: group.keeperID))
        }
        #expect(model.backupCount == 2)
        #expect(backupFileNames().count == 4)

        model.deleteBackups()
        #expect(model.backupCount == 0)
        #expect(backupFileNames().isEmpty)
    }

    @Test func aReceiptThatCantBeSavedStopsTheMergeBeforeAnythingChanges() async throws {
        // A folder where History's file should be, so saving it fails.
        let blocked = data.appendingPathComponent("history.json", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: blocked.appendingPathComponent("inside"))
        let store = pair()
        let (model, history, _) = model(store, directory: data)
        await model.start()
        let group = try #require(model.groups.first)

        let merged = await model.merge(group.id, keeperID: group.keeperID, choices: MergeChoices(nameFrom: group.keeperID))
        #expect(!merged)
        #expect(model.problems[group.id] == .backupFailed)
        #expect(history.receipts.isEmpty)
        #expect(model.backupCount == 0)
        #expect(backupFileNames().isEmpty)
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
        #expect(backupFileNames().isEmpty)

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
        #expect(notices.text == "Kept both cards. They won't be suggested again.")

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

    @Test func clearingHistoryDeletesBackupsRightAway() async throws {
        let store = pair()
        let photos = temporaryDirectory("contacts-photos-\(UUID().uuidString)")
        let state = AppState(photoSource: FolderPhotoSource(folder: photos), analyzer: VisionFrameAnalyzer(), directory: data, defaults: freshDefaults(), contactStore: store)
        await state.contacts.start()
        let group = try #require(state.contacts.groups.first)
        await state.contacts.merge(group.id, keeperID: group.keeperID, choices: MergeChoices(nameFrom: group.keeperID))
        #expect(state.contacts.backupCount == 1)
        let cardsBefore = await store.cards()

        state.clearHistory()
        #expect(state.contacts.backupCount == 0)
        #expect(await store.cards() == cardsBefore)
    }

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
        #expect(Copy.Contacts.keepApart(2) == "Keep both")
        #expect(Copy.Contacts.keepApart(3) == "Keep all 3")
        #expect(Copy.Contacts.keptApart(3) == "Kept all 3 cards. They won't be suggested again.")
        #expect(Copy.Contacts.limited(12) == "Checking the 12 contacts you shared.")
        #expect(Copy.Contacts.rowLabel("Maya Cohen", cards: 2, reasons: [.samePhone], accounts: ["iCloud", "Gmail"], mergeable: false)
            == "Maya Cohen, 2 cards, Same phone, iCloud · Gmail, In different accounts, can't be merged")
        #expect(Copy.Contacts.merged(2, into: "Jordan Rivera") == "Merged 2 cards into Jordan Rivera.")
        #expect(Copy.Contacts.initials(Self.jordan) == "JR")
        let address = LabeledPostal(street: "1 Main St\nApt 2", city: "Livermore", state: "CA", postalCode: "94550")
        #expect(Copy.Contacts.address(address) == "1 Main St, Apt 2, Livermore, CA 94550")
    }
}

/// An address book that can be told to fail reading, for the check's error state.
final class FlakyContactStore: ContactStoring, @unchecked Sendable {
    private let base: InMemoryContactStore
    private let lock = NSLock()
    private var _failsToRead = false
    var failsToRead: Bool {
        get { lock.withLock { _failsToRead } }
        set { lock.withLock { _failsToRead = newValue } }
    }

    init(_ base: InMemoryContactStore) { self.base = base }

    struct ReadFailed: Error {}

    func authorization() -> ContactAccess { base.authorization() }
    func requestAccess() async throws -> ContactAccess { try await base.requestAccess() }
    func fetchCards() async throws -> [ContactCard] {
        if failsToRead { throw ReadFailed() }
        return try await base.fetchCards()
    }
    func backup(ids: [String]) async throws -> Data { try await base.backup(ids: ids) }
    func apply(_ plan: MergePlan) async throws { try await base.apply(plan) }
    func undo(_ plan: MergePlan, backup: Data, overwritingLaterEdits: Bool) async throws -> [String] {
        try await base.undo(plan, backup: backup, overwritingLaterEdits: overwritingLaterEdits)
    }
    func add(_ card: ContactCard) async throws -> String { try await base.add(card) }
}

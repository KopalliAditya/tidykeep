// TidykeepContacts against the real Contacts framework, inside the app, on a simulator.
//
// Only the simulator's own address book is used, and only cards this file makes: two cards
// with a family name nobody else has ("TidykeepCI" and a random suffix) and a number no
// seed uses. They are found, backed up, merged, undone and deleted again. The simulator's
// sample cards and the two "Jordan Rivera" cards the UI tests seed are never touched.
//
// Compiled for the simulator only, so it can never change the address book on a device.
#if targetEnvironment(simulator)
import Contacts
import Foundation
import Testing

#if canImport(TidykeepContacts)
import TidykeepContacts
#endif

@Suite(
    "Contacts on the simulator's address book",
    .serialized,
    .enabled(if: TestEnvironment.contactsAuthorized, "needs contacts access, granted by CI with simctl privacy")
)
struct ContactsIntegrationTests {
    /// Unique to this run, so the cards can't be mistaken for anyone else's.
    let familyName = "TidykeepCI" + UUID().uuidString.prefix(8).lowercased()
    /// The same mobile number on both cards. Not the UI tests' Jordan Rivera number.
    let phone = "+1 415 555 0199"

    @Test func cardsCanBeAddedFoundAndRemoved() throws {
        let store = CNContactStore()
        defer { Self.remove(familyName: familyName, from: store) }

        try Self.add(givenName: "Casey", familyName: familyName, phone: phone, to: store)
        try Self.add(givenName: "Casey", familyName: familyName, phone: phone, to: store)
        #expect(try Self.find(familyName: familyName, in: store).count == 2)

        Self.remove(familyName: familyName, from: store)
        #expect(try Self.find(familyName: familyName, in: store).isEmpty)
    }

    #if canImport(TidykeepContacts)
    /// The whole merge: the finder pairs the two cards, the backup holds both as vCards,
    /// the merge leaves one card, and undo brings the other back.
    @Test func twoCardsAreFoundMergedAndUndone() async throws {
        let raw = CNContactStore()
        defer { Self.remove(familyName: familyName, from: raw) }
        try Self.add(givenName: "Casey", familyName: familyName, phone: phone, to: raw)
        try Self.add(givenName: "Casey", familyName: familyName, phone: phone, to: raw)

        let store = SystemContactStore()
        #expect(store.authorization() == .full)

        let ours = try await cards(in: store)
        try #require(ours.count == 2, "Expected our 2 cards, found \(ours.count)")

        // Only our two cards go to the finder, so the simulator's other cards can't change
        // the answer.
        let found = DuplicateContactFinder.find(ours)
        #expect(found.crossAccount.isEmpty)
        let group = try #require(found.mergeable.first, "The two cards weren't matched")
        #expect(found.mergeable.count == 1)
        #expect(Set(group.cardIDs) == Set(ours.map(\.id)))
        #expect(!group.reasons.isEmpty)

        let plan = try MergePlanner.plan(
            cards: ours, keeperID: group.keeperID, choices: MergeChoices(nameFrom: group.keeperID)
        )
        #expect(plan.keeperID == group.keeperID)
        #expect(plan.removedIDs.count == 1)

        let backup = try await store.backup(ids: plan.backupIDs)
        let vCards = String(decoding: backup, as: UTF8.self)
        #expect(vCards.components(separatedBy: "BEGIN:VCARD").count - 1 == 2, "The backup doesn't hold both cards")
        #expect(vCards.contains(familyName))

        try await store.apply(plan)
        let merged = try await cards(in: store)
        #expect(merged.map(\.id) == [plan.keeperID], "After the merge: \(merged.map(\.id))")
        #expect(merged.first?.phones.count == 1, "The shared number was doubled")

        let recreated = try await store.undo(plan, backup: backup)
        #expect(recreated.count == 1, "Undo re-created \(recreated.count) cards")
        let restored = try await cards(in: store)
        #expect(restored.count == 2, "After undo: \(restored.count) cards")
        #expect(restored.contains { $0.id == plan.keeperID }, "Undo replaced the keeper instead of restoring it")
    }

    /// Our cards, as TidykeepContacts reads them.
    private func cards(in store: SystemContactStore) async throws -> [ContactCard] {
        try await store.fetchCards().filter { $0.familyName == familyName }
    }
    #endif

    // MARK: The address book, directly

    private static func add(givenName: String, familyName: String, phone: String, to store: CNContactStore) throws {
        let card = CNMutableContact()
        card.givenName = givenName
        card.familyName = familyName
        card.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: phone))]
        let request = CNSaveRequest()
        request.add(card, toContainerWithIdentifier: nil)
        try store.execute(request)
    }

    /// Every card with this family name, each on its own: two cards for one person may be
    /// linked into one unified contact, and the merge works on cards, not unified contacts.
    private static func find(familyName: String, in store: CNContactStore) throws -> [CNContact] {
        let fetch = CNContactFetchRequest(keysToFetch: [CNContactFamilyNameKey, CNContactIdentifierKey] as [CNKeyDescriptor])
        fetch.unifyResults = false
        fetch.predicate = CNContact.predicateForContacts(matchingName: familyName)
        var found: [CNContact] = []
        try store.enumerateContacts(with: fetch) { contact, _ in
            if contact.familyName == familyName { found.append(contact) }
        }
        return found
    }

    /// Deletes every card with this family name, unified or not. Best effort: it runs from
    /// `defer`, after a failure as well.
    private static func remove(familyName: String, from store: CNContactStore) {
        let fetch = CNContactFetchRequest(keysToFetch: [CNContactFamilyNameKey, CNContactIdentifierKey] as [CNKeyDescriptor])
        fetch.unifyResults = false
        fetch.predicate = CNContact.predicateForContacts(matchingName: familyName)
        let request = CNSaveRequest()
        var count = 0
        try? store.enumerateContacts(with: fetch) { contact, _ in
            guard contact.familyName == familyName, let card = contact.mutableCopy() as? CNMutableContact else { return }
            request.delete(card)
            count += 1
        }
        if count > 0 { try? store.execute(request) }
    }
}
#endif

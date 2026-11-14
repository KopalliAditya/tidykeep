import Contacts
import Foundation

/// The real address book, through `CNContactStore`.
///
/// Cards are read raw (linked cards are not unified), each with its account, because merges
/// happen inside one account. `CNContactNoteKey` is never fetched, so saving the keeper leaves
/// its note as it was. Work runs off the main actor; the store blocks while it reads and saves.
///
/// My Card can't be found on iOS, which has no API for it, so there `isMe` is always false.
public final class SystemContactStore: ContactStoring {
    /// Every key this store ever reads. The no-notes rule is checked against it.
    public static let keysRead: [String] = ContactKeys.backup

    public init() {}

    public func authorization() -> ContactAccess {
        Self.access(CNContactStore.authorizationStatus(for: .contacts))
    }

    @concurrent
    public func requestAccess() async throws -> ContactAccess {
        guard CNContactStore.authorizationStatus(for: .contacts) == .notDetermined else { return authorization() }
        _ = try await CNContactStore().requestAccess(for: .contacts)
        return authorization()
    }

    @concurrent
    public func fetchCards() async throws -> [ContactCard] {
        try Self.fetchAll()
    }

    @concurrent
    public func backup(ids: [String]) async throws -> Data {
        try Self.backupData(ids)
    }

    @concurrent
    public func apply(_ plan: MergePlan) async throws {
        try Self.applyNow(plan)
    }

    @concurrent
    public func undo(_ plan: MergePlan, backup: Data, overwritingLaterEdits: Bool) async throws -> [String] {
        try Self.undoNow(
            plan, backup: backup, overwritingLaterEdits: overwritingLaterEdits,
            limitedAccess: authorization() == .limited)
    }

    @concurrent
    public func add(_ card: ContactCard) async throws -> String {
        try Self.addNow(card)
    }

    static func access(_ status: CNAuthorizationStatus) -> ContactAccess {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .full
        #if os(iOS)
        case .limited: return .limited
        #endif
        @unknown default: return .denied
        }
    }

    // The Contacts objects below never leave these synchronous functions.

    private static func fetchAll() throws -> [ContactCard] {
        let store = CNContactStore()
        let meID = myCardID(store)
        var cards: [ContactCard] = []
        for container in try store.containers(matching: nil) {
            try Task.checkCancellation()
            let request = CNContactFetchRequest(keysToFetch: ContactKeys.descriptors(ContactKeys.read))
            request.predicate = CNContact.predicateForContactsInContainer(withIdentifier: container.identifier)
            request.unifyResults = false
            try store.enumerateContacts(with: request) { contact, stop in
                // A scan the user walked away from stops at the next card, not after 10,000.
                if Task.isCancelled {
                    stop.pointee = true
                    return
                }
                cards.append(ContactCard(
                    contact, id: contact.identifier, containerID: container.identifier,
                    containerName: container.name, isMe: contact.identifier == meID))
            }
        }
        try Task.checkCancellation()
        return cards
    }

    private static func backupData(_ ids: [String]) throws -> Data {
        let store = CNContactStore()
        let found = try fetch(store, ids: ids, keys: ContactKeys.backup)
        let groups = try groupIDs(store, of: Set(found.keys))
        let entries = ids.compactMap { id in
            found[id].map { contact in
                ContactBackupEntry(
                    id: id, card: ContactCard(contact, id: id, containerID: "", containerName: "", isMe: false),
                    imageData: contact.imageData, isOrganization: contact.contactType == .organization,
                    groupIDs: groups[id] ?? [])
            }
        }
        return try ContactVCard.data(entries)
    }

    private static func applyNow(_ plan: MergePlan) throws {
        let store = CNContactStore()
        let keys = ContactKeys.managed + (plan.photoFromID == nil ? [] : [CNContactImageDataKey])
        guard let keeper = try fetch(store, ids: [plan.keeperID], keys: keys)[plan.keeperID] else {
            throw ContactStoreError.cardNotFound(id: plan.keeperID)
        }
        let account = try containerID(store, of: plan.keeperID) ?? ""
        let current = card(keeper, account: account)
        guard current.matchesPreview(plan.keeperBefore) else {
            throw ContactStoreError.changedSincePreview(id: plan.keeperID)
        }
        // Each removed card must still be as the preview showed it: a number synced to it
        // since would otherwise be deleted with it, kept only in the backup.
        let removed = try fetch(store, ids: plan.removedIDs, keys: ContactKeys.managed)
        let meID = myCardID(store)
        for id in plan.removedIDs {
            guard let contact = removed[id] else { throw ContactStoreError.cardNotFound(id: id) }
            guard try containerID(store, of: id) == account else { throw ContactStoreError.crossAccount(id: id) }
            // The planner never removes My Card; this catches a plan made some other way.
            guard id != meID else { throw ContactStoreError.myCardNotKeeper(id: id) }
            guard let before = plan.removedCardBefore(id), card(contact, account: account).matchesPreview(before) else {
                throw ContactStoreError.changedSincePreview(id: id)
            }
        }

        let updated = mutable(keeper)
        plan.merged.write(plan.merged.fields(differingFrom: current), to: updated)
        if let source = plan.photoFromID {
            guard let photo = try fetch(store, ids: [source], keys: [CNContactImageDataKey])[source] else {
                throw ContactStoreError.cardNotFound(id: source)
            }
            // Gone since the preview: copying nothing would clear the keeper's own photo.
            guard let imageData = photo.imageData else { throw ContactStoreError.changedSincePreview(id: source) }
            updated.imageData = imageData
        }
        let save = CNSaveRequest()
        save.update(updated)
        // The keeper joins the removed cards' groups, so the person stays in "Family".
        let removedIDs = Set(plan.removedIDs)
        for group in try groups(store, in: account) {
            let members = try memberIDs(store, of: group.identifier)
            if !members.contains(plan.keeperID), !members.isDisjoint(with: removedIDs) {
                save.addMember(updated, to: group)
            }
        }
        for id in plan.removedIDs {
            if let contact = removed[id] { save.delete(mutable(contact)) }
        }
        try store.execute(save)
    }

    private static func undoNow(
        _ plan: MergePlan, backup: Data, overwritingLaterEdits: Bool, limitedAccess: Bool
    ) throws -> [String] {
        let saved = try ContactVCard.entries(in: backup)
        let missing = plan.removedIDs.filter { saved[$0] == nil }
        guard missing.isEmpty else { throw ContactStoreError.backupMissingCards(missing) }
        let savedKeeper = saved[plan.keeperID]
        if plan.photoFromID != nil, savedKeeper == nil {
            throw ContactStoreError.backupMissingCards([plan.keeperID])
        }
        let store = CNContactStore()
        guard try fetch(store, ids: plan.removedIDs, keys: [CNContactIdentifierKey]).isEmpty else {
            throw ContactStoreError.notMerged
        }
        let account = plan.keeperBefore.containerID
        let keys = ContactKeys.managed + (plan.photoFromID == nil ? [] : [CNContactImageDataKey])
        let fetchedKeeper = try fetch(store, ids: [plan.keeperID], keys: keys)[plan.keeperID]
        if MergeUndo.alreadyUndone(
            plan, keeper: fetchedKeeper.map { card($0, account: account) }, saved: saved,
            cards: try cards(store, in: account)) {
            throw ContactStoreError.notMerged
        }
        let groups = Dictionary(try groups(store, in: account).map { ($0.identifier, $0) }) { first, _ in first }
        let joined = MergeUndo.groupsJoined(plan, saved: saved)

        let save = CNSaveRequest()
        var created: [(contact: CNMutableContact, groupIDs: [String])] = []
        if let keeper = fetchedKeeper {
            let current = card(keeper, account: account)
            // The keeper's image data was fetched when the merge took another card's photo.
            let reverted = try MergeUndo.revertedKeeper(
                current: current, photo: plan.photoFromID == nil ? nil : keeper.imageData, plan: plan,
                saved: saved, overwritingLaterEdits: overwritingLaterEdits)
            let updated = mutable(keeper)
            reverted.card.write(reverted.card.fields(differingFrom: current), to: updated)
            if reverted.restoresPhoto { updated.imageData = savedKeeper?.imageData }
            save.update(updated)
            for id in joined.sorted() {
                guard let group = groups[id], try memberIDs(store, of: id).contains(plan.keeperID) else { continue }
                save.removeMember(updated, from: group)
            }
        } else if limitedAccess {
            // Most likely still there with the merged details, just no longer shared with the
            // app. Re-creating it would add a duplicate, so nothing changes until it is shared.
            throw ContactStoreError.keeperNotVisible
        } else if overwritingLaterEdits {
            let entry = savedKeeper ?? ContactBackupEntry(id: plan.keeperID, card: plan.keeperBefore, imageData: nil)
            created.append(restored(entry))
        } else {
            throw ContactStoreError.keeperMissing
        }
        for id in plan.removedIDs {
            if let entry = saved[id] { created.append(restored(entry)) }
        }
        for (contact, groupIDs) in created {
            save.add(contact, toContainerWithIdentifier: account)
            for id in groupIDs {
                if let group = groups[id] { save.addMember(contact, to: group) }
            }
        }
        try store.execute(save)
        return created.map(\.contact.identifier)
    }

    private static func addNow(_ card: ContactCard) throws -> String {
        let contact = card.newContact(imageData: nil)
        let save = CNSaveRequest()
        save.add(contact, toContainerWithIdentifier: nil)
        try CNContactStore().execute(save)
        return contact.identifier
    }

    /// A backed-up card as a new contact, with the groups to put it back in.
    private static func restored(_ entry: ContactBackupEntry) -> (contact: CNMutableContact, groupIDs: [String]) {
        (entry.card.newContact(imageData: entry.imageData, isOrganization: entry.isOrganization), entry.groupIDs)
    }

    /// Every card in an account, with the managed fields only.
    private static func cards(_ store: CNContactStore, in account: String) throws -> [ContactCard] {
        let request = CNContactFetchRequest(keysToFetch: ContactKeys.descriptors(ContactKeys.managed))
        if !account.isEmpty { request.predicate = CNContact.predicateForContactsInContainer(withIdentifier: account) }
        request.unifyResults = false
        var cards: [ContactCard] = []
        try store.enumerateContacts(with: request) { contact, _ in cards.append(card(contact, account: account)) }
        return cards
    }

    /// The groups in an account. Groups live in one account each.
    private static func groups(_ store: CNContactStore, in account: String) throws -> [CNGroup] {
        guard !account.isEmpty else { return [] }
        return try store.groups(matching: CNGroup.predicateForGroupsInContainer(withIdentifier: account))
    }

    /// The groups each of these cards is in, by card: one fetch per group.
    private static func groupIDs(_ store: CNContactStore, of ids: Set<String>) throws -> [String: [String]] {
        guard !ids.isEmpty else { return [:] }
        var result: [String: [String]] = [:]
        for group in try store.groups(matching: nil) {
            for id in try memberIDs(store, of: group.identifier) where ids.contains(id) {
                result[id, default: []].append(group.identifier)
            }
        }
        return result
    }

    private static func memberIDs(_ store: CNContactStore, of groupID: String) throws -> Set<String> {
        let request = CNContactFetchRequest(keysToFetch: ContactKeys.descriptors([CNContactIdentifierKey]))
        request.predicate = CNContact.predicateForContactsInGroup(withIdentifier: groupID)
        request.unifyResults = false
        var ids = Set<String>()
        try store.enumerateContacts(with: request) { contact, _ in ids.insert(contact.identifier) }
        return ids
    }

    /// Raw contacts by identifier. Missing ones are left out.
    private static func fetch(_ store: CNContactStore, ids: [String], keys: [String]) throws -> [String: CNContact] {
        guard !ids.isEmpty else { return [:] }
        let request = CNContactFetchRequest(keysToFetch: ContactKeys.descriptors(keys))
        request.predicate = CNContact.predicateForContacts(withIdentifiers: ids)
        request.unifyResults = false
        var found: [String: CNContact] = [:]
        try store.enumerateContacts(with: request) { contact, _ in found[contact.identifier] = contact }
        return found
    }

    private static func containerID(_ store: CNContactStore, of id: String) throws -> String? {
        try store.containers(matching: CNContainer.predicateForContainerOfContact(withIdentifier: id)).first?.identifier
    }

    /// A fetched card in `account`, for comparing with the plan. Only the managed fields,
    /// account and photo matter.
    private static func card(_ contact: CNContact, account: String) -> ContactCard {
        ContactCard(contact, id: contact.identifier, containerID: account, containerName: "", isMe: false)
    }

    private static func mutable(_ contact: CNContact) -> CNMutableContact {
        // A contact's mutable copy is always a CNMutableContact.
        contact.mutableCopy() as! CNMutableContact
    }

    private static func myCardID(_ store: CNContactStore) -> String? {
        #if os(macOS)
        return (try? store.unifiedMeContactWithKeys(toFetch: []))?.identifier
        #else
        return nil
        #endif
    }
}

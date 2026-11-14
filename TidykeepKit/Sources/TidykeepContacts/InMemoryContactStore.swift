import Foundation
import Synchronization

/// An address book in memory, for tests and the demo and screenshot mode.
///
/// It follows the rules of `SystemContactStore`: one account per merge, checks against the
/// preview, groups carried over, the keeper reverted in place, removed cards re-created from a
/// real vCard backup. The vCards are written from new contacts built in memory, so the user's
/// address book is never opened. Photos survive a backup only when the store was given their
/// image data.
public final class InMemoryContactStore: ContactStoring {
    private let book: Book
    private let access: Mutex<ContactAccess>

    /// - Parameter groups: The members of each group, by group identifier.
    public init(
        cards: [ContactCard] = [], images: [String: Data] = [:], groups: [String: Set<String>] = [:],
        access: ContactAccess = .full
    ) {
        book = Book(cards: cards, images: images, groups: groups)
        self.access = Mutex(access)
    }

    public func authorization() -> ContactAccess {
        access.withLock { $0 }
    }

    /// Grants full access when it hasn't been decided, as a user tapping Allow would.
    public func requestAccess() async throws -> ContactAccess {
        access.withLock { access in
            if access == .notDetermined { access = .full }
            return access
        }
    }

    public func fetchCards() async throws -> [ContactCard] {
        try checkAccess()
        return await book.cards
    }

    public func backup(ids: [String]) async throws -> Data {
        try checkAccess()
        return try await book.backup(ids)
    }

    public func apply(_ plan: MergePlan) async throws {
        try checkAccess()
        try await book.apply(plan)
    }

    public func undo(_ plan: MergePlan, backup: Data, overwritingLaterEdits: Bool) async throws -> [String] {
        try checkAccess()
        return try await book.undo(
            plan, backup: backup, overwritingLaterEdits: overwritingLaterEdits,
            limitedAccess: authorization() == .limited)
    }

    /// Adds the card with a new identifier in the first card's account (or "local"), as
    /// Contacts would in the default account.
    public func add(_ card: ContactCard) async throws -> String {
        try checkAccess()
        return await book.add(card)
    }

    /// Every card, whatever the access, for tests to look at.
    public func cards() async -> [ContactCard] {
        await book.cards
    }

    /// The card's photo, for tests to check that a merge and its undo moved the right one.
    public func imageData(for id: String) async -> Data? {
        await book.images[id]
    }

    /// The groups the card is in, sorted, for tests to check that a merge and its undo kept them.
    public func groupIDs(of id: String) async -> [String] {
        await book.groupIDs(of: id)
    }

    /// Replaces the card with the same identifier, or adds it: an edit made in another app.
    public func update(_ card: ContactCard) async {
        await book.update(card)
    }

    private func checkAccess() throws {
        guard authorization().canRead else { throw ContactStoreError.notAuthorized }
    }
}

/// The cards themselves. An actor, so each operation checks everything and then changes
/// everything with nothing in between, like one save request.
private actor Book {
    var cards: [ContactCard]
    var images: [String: Data]
    var groups: [String: Set<String>]

    init(cards: [ContactCard], images: [String: Data], groups: [String: Set<String>]) {
        self.cards = cards
        self.images = images
        self.groups = groups
    }

    func update(_ card: ContactCard) {
        if let i = cards.firstIndex(where: { $0.id == card.id }) {
            cards[i] = card
        } else {
            cards.append(card)
        }
    }

    func add(_ card: ContactCard) -> String {
        var card = card
        card.id = UUID().uuidString
        card.containerID = cards.first?.containerID ?? "local"
        card.containerName = cards.first?.containerName ?? ""
        card.isMe = false
        card.hasImage = false
        cards.append(card)
        return card.id
    }

    func groupIDs(of id: String) -> [String] {
        groups.keys.filter { groups[$0]?.contains(id) == true }.sorted()
    }

    func backup(_ ids: [String]) throws -> Data {
        let entries = ids.compactMap { id in
            card(id).map { ContactBackupEntry(id: id, card: $0, imageData: images[id], groupIDs: groupIDs(of: id)) }
        }
        return try ContactVCard.data(entries)
    }

    func apply(_ plan: MergePlan) throws {
        guard let keeper = card(plan.keeperID) else { throw ContactStoreError.cardNotFound(id: plan.keeperID) }
        guard keeper.matchesPreview(plan.keeperBefore) else {
            throw ContactStoreError.changedSincePreview(id: keeper.id)
        }
        for id in plan.removedIDs {
            guard let removed = card(id) else { throw ContactStoreError.cardNotFound(id: id) }
            guard removed.containerID == keeper.containerID else { throw ContactStoreError.crossAccount(id: id) }
            guard !removed.isMe else { throw ContactStoreError.myCardNotKeeper(id: id) }
            guard let before = plan.removedCardBefore(id), removed.matchesPreview(before) else {
                throw ContactStoreError.changedSincePreview(id: id)
            }
        }
        var merged = keeper.withDetails(of: plan.merged)
        if let source = plan.photoFromID {
            guard let photoCard = card(source) else { throw ContactStoreError.cardNotFound(id: source) }
            // Gone since the preview: copying nothing would clear the keeper's own photo.
            guard photoCard.hasImage else { throw ContactStoreError.changedSincePreview(id: source) }
            merged.hasImage = true
            images[keeper.id] = images[source]
        }
        replace(merged)
        let removed = Set(plan.removedIDs)
        for (group, members) in groups {
            var members = members
            if !members.isDisjoint(with: removed) { members.insert(keeper.id) }
            groups[group] = members.subtracting(removed)
        }
        cards.removeAll { removed.contains($0.id) }
        for id in removed { images[id] = nil }
    }

    func undo(_ plan: MergePlan, backup: Data, overwritingLaterEdits: Bool, limitedAccess: Bool) throws -> [String] {
        let saved = try ContactVCard.entries(in: backup)
        let missing = plan.removedIDs.filter { saved[$0] == nil }
        guard missing.isEmpty else { throw ContactStoreError.backupMissingCards(missing) }
        let savedKeeper = saved[plan.keeperID]
        if plan.photoFromID != nil, savedKeeper == nil {
            throw ContactStoreError.backupMissingCards([plan.keeperID])
        }
        guard plan.removedIDs.allSatisfy({ card($0) == nil }) else { throw ContactStoreError.notMerged }

        // Work everything out first, so a refusal changes nothing.
        var keeper: ContactCard?
        var recreate: [(card: ContactCard, image: Data?, groupIDs: [String])] = []
        if let current = card(plan.keeperID) {
            var reverted = try MergeUndo.revertedKeeper(
                current: current, plan: plan, overwritingLaterEdits: overwritingLaterEdits)
            if plan.photoFromID != nil { reverted.hasImage = savedKeeper?.imageData != nil }
            keeper = reverted
        } else if limitedAccess {
            // Most likely still there, just no longer shared with the app.
            throw ContactStoreError.keeperNotVisible
        } else if overwritingLaterEdits {
            let entry = savedKeeper ?? ContactBackupEntry(id: plan.keeperID, card: plan.keeperBefore, imageData: nil)
            recreate.append(restored(entry, plan))
        } else {
            throw ContactStoreError.keeperMissing
        }
        for id in plan.removedIDs {
            if let entry = saved[id] { recreate.append(restored(entry, plan)) }
        }

        if let keeper {
            replace(keeper)
            if plan.photoFromID != nil { images[keeper.id] = savedKeeper?.imageData }
            for group in MergeUndo.groupsJoined(plan, saved: saved) { groups[group]?.remove(keeper.id) }
        }
        for entry in recreate {
            cards.append(entry.card)
            images[entry.card.id] = entry.image
            // Groups deleted since stay deleted.
            for group in entry.groupIDs { groups[group]?.insert(entry.card.id) }
        }
        return recreate.map(\.card.id)
    }

    /// A backed-up card as a new card in the keeper's account: a fresh identifier, no one's
    /// My Card, and a photo only when the backup holds one.
    private func restored(_ entry: ContactBackupEntry, _ plan: MergePlan) -> (card: ContactCard, image: Data?, groupIDs: [String]) {
        var card = entry.card
        card.id = UUID().uuidString
        card.containerID = plan.keeperBefore.containerID
        card.containerName = plan.keeperBefore.containerName
        card.isMe = false
        card.hasImage = entry.imageData != nil
        return (card, entry.imageData, entry.groupIDs)
    }

    private func card(_ id: String) -> ContactCard? {
        cards.first { $0.id == id }
    }

    private func replace(_ card: ContactCard) {
        if let i = cards.firstIndex(where: { $0.id == card.id }) { cards[i] = card }
    }
}

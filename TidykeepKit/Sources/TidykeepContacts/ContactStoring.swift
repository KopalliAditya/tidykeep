import Foundation

/// How much of the address book the app may see.
public enum ContactAccess: String, Sendable, Codable, Hashable {
    case notDetermined
    /// The user shared some contacts. Duplicates are found among those only.
    case limited
    case full
    case denied
    /// Parental controls or a device profile block access; the user can't change it.
    case restricted

    /// Whether cards can be read at all.
    public var canRead: Bool { self == .full || self == .limited }
}

/// Why a store refused or failed. The cases the UI asks about say what to do next.
public enum ContactStoreError: Error, Sendable, Hashable {
    /// The app has no access to contacts.
    case notAuthorized
    /// A card in the plan is gone.
    case cardNotFound(id: String)
    /// A card changed after the preview was made. Plan again from fresh cards.
    case changedSincePreview(id: String)
    /// The plan reaches into another account. Merges stay within one.
    case crossAccount(id: String)
    /// The plan would delete My Card. My Card is only ever the keeper.
    case myCardNotKeeper(id: String)
    /// The merged card was edited since the merge in fields the undo would change, named as
    /// in `ManagedField`, or "photo" for a photo the merge took from another card. Ask, then
    /// undo with `overwritingLaterEdits` to put the old values back anyway.
    case keeperChangedSinceMerge(fields: [String])
    /// The merged card was deleted since. Undo with `overwritingLaterEdits` re-creates it from
    /// the backup as a new card, alongside the others.
    case keeperMissing
    /// The merged card can't be seen: the app has limited access and the card is no longer
    /// shared with it. It may well still exist, so undo doesn't offer to re-create it (that
    /// would make a new duplicate). Sharing the card with the app again lets undo go ahead.
    case keeperNotVisible
    /// The backup doesn't hold these cards, so they can't be restored.
    case backupMissingCards([String])
    /// The backup isn't a vCard this app wrote.
    case unreadableBackup
    /// The removed cards still exist: the merge never happened, or was already undone.
    case notMerged
}

/// The address book, real or in memory. Everything runs off the main actor.
///
/// A merge is: `backup(ids: plan.backupIDs)`, keep the data (see `ContactBackupStore`), then
/// `apply(plan)`. Undo hands both back. Notes are never read or written, so the keeper's note
/// survives the merge and its undo; notes on removed cards are lost, which the UI says first.
public protocol ContactStoring: Sendable {
    /// The current access, without asking.
    func authorization() -> ContactAccess
    /// Asks for access when it hasn't been decided; otherwise returns what was decided.
    func requestAccess() async throws -> ContactAccess
    /// Every card the app can see, each in its own account (linked cards are not unified).
    func fetchCards() async throws -> [ContactCard]
    /// A vCard of these cards, photos included, that `undo` can restore from. Cards that
    /// don't exist are left out.
    func backup(ids: [String]) async throws -> Data
    /// Updates the keeper and deletes the removed cards in one save, so a failure changes
    /// nothing. The keeper joins every group a removed card was in. Throws when a card is
    /// gone, in another account, or changed since the preview (the keeper or any removed card,
    /// including a photo the merge was to take).
    func apply(_ plan: MergePlan) async throws
    /// Undo that stops and asks when the merged card was edited since: the same as
    /// `undo(_:backup:overwritingLaterEdits:)` with `false`, which every store gets for free.
    func undo(_ plan: MergePlan, backup: Data) async throws -> [String]
    /// Puts the keeper's fields back in place (its note untouched) and re-creates the removed
    /// cards from the backup in the keeper's account, in their groups, in one save. The keeper
    /// leaves the groups the merge added it to. Fields edited since the merge are kept unless
    /// the undo would have to change them too; then it throws `keeperChangedSinceMerge` unless
    /// `overwritingLaterEdits` is set. The same goes for a photo changed since a merge that took
    /// another card's photo. A keeper that can't be found throws `keeperMissing`, or
    /// `keeperNotVisible` with limited access.
    ///
    /// Returns the identifiers of the re-created cards (a re-created keeper first): new cards,
    /// since identifiers can't be reused, so links from other apps don't come back. Call it
    /// once per merge; History marks the merge undone, because a second call would re-create
    /// the cards again.
    func undo(_ plan: MergePlan, backup: Data, overwritingLaterEdits: Bool) async throws -> [String]
    /// Saves the card as a new card in the default account and returns its identifier. The
    /// card's own identifier, account and photo flag are ignored. The simulator's sample cards
    /// for UI tests come in this way.
    func add(_ card: ContactCard) async throws -> String
}

extension ContactStoring {
    public func undo(_ plan: MergePlan, backup: Data) async throws -> [String] {
        try await undo(plan, backup: backup, overwritingLaterEdits: false)
    }
}

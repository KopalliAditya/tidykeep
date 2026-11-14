import Foundation

/// Works out what the keeper looks like after an undo, given how it looks now.
///
/// The keeper is reverted in place rather than deleted and re-created, because it may hold a
/// note the app can't read. Each managed field is compared three ways, before the merge, right
/// after it, and now:
/// - unchanged since the merge: the old value goes back;
/// - the merge didn't touch it but the user edited it later: the edit stays;
/// - the merge changed it and the user edited it later: that is a conflict, and the user is
///   asked before the edit is overwritten.
///
/// The photo, when the merge took another card's, is compared the same way by its bytes.
enum MergeUndo {
    /// The keeper's fields after the undo, leaving the photo out.
    static func revertedKeeper(current: ContactCard, plan: MergePlan, overwritingLaterEdits: Bool) throws -> ContactCard {
        let (result, conflicts) = reverted(current, plan: plan, overwritingLaterEdits: overwritingLaterEdits)
        if !conflicts.isEmpty { throw ContactStoreError.keeperChangedSinceMerge(fields: conflicts) }
        return result
    }

    /// The keeper after the undo, photo included: whether the photo it had before the merge
    /// goes back in place of `photo`, the one it has now. Only a merge that took another
    /// card's photo changed it. The backup holds the keeper's photo from before and the photo
    /// card's, which is what the merge wrote, so a photo set after the merge shows as a
    /// conflict named "photo", asked about like the fields.
    static func revertedKeeper(
        current: ContactCard, photo: Data?, plan: MergePlan, saved: [String: ContactBackupEntry],
        overwritingLaterEdits: Bool
    ) throws -> (card: ContactCard, restoresPhoto: Bool) {
        var (result, conflicts) = reverted(current, plan: plan, overwritingLaterEdits: overwritingLaterEdits)
        var restoresPhoto = false
        if let source = plan.photoFromID {
            let before = saved[plan.keeperID]?.imageData
            let written = saved[source]?.imageData
            // A photo missing from the backup can't be compared, so it never counts as the same.
            let mergeKeptIt = written != nil && written == before
            if photo != before, !mergeKeptIt {
                if (written != nil && photo == written) || overwritingLaterEdits {
                    restoresPhoto = true
                    result.hasImage = before != nil
                } else {
                    conflicts.append(MergeField.photo)
                }
            }
        }
        if !conflicts.isEmpty { throw ContactStoreError.keeperChangedSinceMerge(fields: conflicts) }
        return (result, restoresPhoto)
    }

    /// The fields put back, and the ones edited since that the undo would have to overwrite.
    private static func reverted(_ current: ContactCard, plan: MergePlan, overwritingLaterEdits: Bool) -> (card: ContactCard, conflicts: [String]) {
        var result = current
        var conflicts: [String] = []
        for field in ManagedField.allCases {
            if current.same(field, as: plan.keeperBefore) { continue }
            if plan.merged.same(field, as: plan.keeperBefore) { continue }
            if current.same(field, as: plan.merged) || overwritingLaterEdits {
                result.copy(field, from: plan.keeperBefore)
            } else {
                conflicts.append(field.rawValue)
            }
        }
        return (result, conflicts)
    }

    /// Whether this undo already ran and only its record was lost, as when the app quits
    /// between the save and the receipt. Then the removed cards are back under new
    /// identifiers, so they can't be found by their old ones, and running it again would add
    /// them a second time. True when the keeper has nothing left to revert and each removed
    /// card has a card in the keeper's account with the same details. (The keeper, when it was
    /// missing and re-created, is one of `cards` too.)
    static func alreadyUndone(_ plan: MergePlan, keeper: ContactCard?, saved: [String: ContactBackupEntry], cards: [ContactCard]) -> Bool {
        var wanted = plan.removedIDs.compactMap { saved[$0]?.card }
        guard wanted.count == plan.removedIDs.count else { return false }
        if let keeper {
            guard let reverted = try? revertedKeeper(current: keeper, plan: plan, overwritingLaterEdits: false),
                  reverted.hasSameDetails(as: keeper)
            else { return false }
        } else {
            wanted.append(saved[plan.keeperID]?.card ?? plan.keeperBefore)
        }
        var others = cards.filter { $0.id != plan.keeperID && $0.containerID == plan.keeperBefore.containerID }
        for card in wanted {
            guard let i = others.firstIndex(where: { $0.hasSameDetails(as: card) }) else { return false }
            others.remove(at: i)
        }
        return true
    }

    /// The groups the merge put the keeper in: a removed card's groups that the keeper, as
    /// backed up, wasn't in. Undo takes the keeper out of these only. Without the keeper's
    /// entry its own groups aren't known, so none.
    static func groupsJoined(_ plan: MergePlan, saved: [String: ContactBackupEntry]) -> Set<String> {
        guard let keeper = saved[plan.keeperID] else { return [] }
        let removed = plan.removedIDs.flatMap { saved[$0]?.groupIDs ?? [] }
        return Set(removed).subtracting(keeper.groupIDs)
    }
}

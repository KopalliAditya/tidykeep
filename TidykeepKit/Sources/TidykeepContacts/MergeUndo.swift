/// Works out what the keeper looks like after an undo, given how it looks now.
///
/// The keeper is reverted in place rather than deleted and re-created, because it may hold a
/// note the app can't read. Each managed field is compared three ways, before the merge, right
/// after it, and now:
/// - unchanged since the merge: the old value goes back;
/// - the merge didn't touch it but the user edited it later: the edit stays;
/// - the merge changed it and the user edited it later: that is a conflict, and the user is
///   asked before the edit is overwritten.
enum MergeUndo {
    static func revertedKeeper(current: ContactCard, plan: MergePlan, overwritingLaterEdits: Bool) throws -> ContactCard {
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
        if !conflicts.isEmpty { throw ContactStoreError.keeperChangedSinceMerge(fields: conflicts) }
        return result
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

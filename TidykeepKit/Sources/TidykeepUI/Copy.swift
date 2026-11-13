import Foundation
import TidykeepCore

/// User-facing text, including everything VoiceOver reads. Kept in one place so it stays
/// consistent and can be tested.
enum Copy {
    static func photos(_ n: Int) -> String { n == 1 ? "1 photo" : "\(n) photos" }

    static func groups(_ n: Int) -> String { n == 1 ? "1 group" : "\(n) groups" }

    static func groupTitle(_ group: PhotoGroup) -> String { "\(group.members.count) similar photos" }

    static func keepRemove(kept: Int, removing: Int) -> String {
        removing == 0 ? "Keeping all \(kept)" : "Keep \(kept) · Remove \(removing)"
    }

    /// Spoken after a keep or remove choice changes: "4 to keep, 2 to remove."
    static func tally(_ group: PhotoGroup, removing: Int) -> String {
        removing == 0
            ? "Keeping all \(group.members.count)."
            : "\(group.members.count - removing) to keep, \(removing) to remove."
    }

    static func groupLabel(_ group: PhotoGroup, kept: Int, removing: Int) -> String {
        var text = "\(groupTitle(group)) from \(group.startDate.formatted(date: .abbreviated, time: .shortened)). "
        text += removing == 0 ? "Keeping all of them." : "\(kept) to keep, \(removing) to remove."
        if group.ranking.isCloseCall { text += " Close call, worth a look." }
        return text
    }

    /// "photo 3", by capture order, matching the tiles.
    static func photoNumber(_ id: String, in group: PhotoGroup) -> String {
        "photo \(group.captureIndex(of: id) ?? 1)"
    }

    static func photoLabel(_ meta: AssetMeta, in group: PhotoGroup) -> String {
        let index = group.captureIndex(of: meta.id) ?? 1
        let time = meta.creationDate.formatted(.dateTime.hour().minute().second())
        return "Photo \(index) of \(group.members.count), taken \(time)"
    }

    static func photoValue(_ meta: AssetMeta, in group: PhotoGroup, kept: Bool) -> String {
        var parts: [String] = []
        let pickedAsFavorite = meta.id == group.keeper.id && group.ranking.reasons == [.favorite]
        if pickedAsFavorite {
            parts.append("Best pick, a favorite")
        } else if meta.id == group.keeper.id {
            parts.append("Best pick, \(reasons(group.ranking.reasons))")
        } else if meta.id == group.runnerUp?.id {
            parts.append("Runner-up")
        }
        parts.append(kept ? "Keeping" : "Marked for removal")
        if meta.isFavorite && !pickedAsFavorite { parts.append("Favorite") }
        if meta.hasAdjustments { parts.append("Edited") }
        if group.documentIDs.contains(meta.id) { parts.append("Looks like a document") }
        return parts.joined(separator: ". ")
    }

    /// Why a photo can't be removed, or nil when it can.
    static func protectedNote(_ meta: AssetMeta, in group: PhotoGroup) -> String? {
        if meta.isFavorite { return "This is a favorite, so it's always kept." }
        if meta.hasAdjustments { return "This photo is edited, so it's always kept." }
        if group.documentIDs.contains(meta.id) { return "This looks like a document, so it's always kept." }
        return nil
    }

    /// "sharpest and best faces"
    static func reasons(_ reasons: [PickReason]) -> String {
        let phrases = reasons.map(\.phrase)
        switch phrases.count {
        case 0: return PickReason.bestOverall.phrase
        case 1: return phrases[0]
        default: return phrases.dropLast().joined(separator: ", ") + " and " + phrases.last!
        }
    }

    static func whyThisOne(_ group: PhotoGroup) -> String {
        group.ranking.reasons == [.favorite]
            ? "Kept because \(PickReason.favorite.phrase)."
            : "Best pick: \(reasons(group.ranking.reasons))."
    }

    /// `whyThisOne` for VoiceOver, which can't see the star, so it names the photo.
    static func whyThisOneSpoken(_ group: PhotoGroup) -> String {
        let pick = photoNumber(group.keeper.id, in: group)
        return group.ranking.reasons == [.favorite]
            ? "Best pick is \(pick), because \(PickReason.favorite.phrase)."
            : "Best pick is \(pick): \(reasons(group.ranking.reasons))."
    }

    static let closeCall = "Close call. Have a look before removing."

    static func closeCallSpoken(_ group: PhotoGroup) -> String {
        guard let runnerUp = group.runnerUp else { return closeCall }
        return "Close call: \(photoNumber(runnerUp.id, in: group)) is nearly as good. Compare them before removing."
    }

    static func scanSummary(groups: Int, extras: Int) -> String {
        if groups == 0 { return "No similar photos found" }
        return "\(self.groups(groups)) · \(extras == 1 ? "1 extra photo" : "\(extras) extra photos")"
    }

    /// The end of a scan, for VoiceOver.
    static func scanDone(groups: Int, extras: Int) -> String {
        "Done checking. " + scanSummary(groups: groups, extras: extras).replacingOccurrences(of: " · ", with: ", ") + "."
    }

    static func checked(_ p: ScanProgress) -> String {
        p.toAnalyze == 0 ? "Getting ready" : "\(p.analyzed + p.skipped) of \(p.toAnalyze) photos checked"
    }

    static func skipped(_ n: Int) -> String {
        "\(photos(n)) couldn't be read on this phone, usually because \(n == 1 ? "it's" : "they're") only in iCloud, and \(n == 1 ? "was" : "were") skipped."
    }
}

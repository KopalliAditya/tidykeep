import Foundation
import TidykeepCore

/// Text for the Similar Shots list, the group screen and Compare. Kept here rather than in
/// Copy.swift so each area can add its own strings without touching the shared file.
extension Copy.Similar {
    // MARK: Decisions

    static let keep = "Keep"
    static let remove = "Remove"
    static let markForRemoval = "Mark for removal"
    static let keepOnlyThisOne = "Keep only this one"
    static func keepOnlyLabel(_ meta: AssetMeta, in group: PhotoGroup) -> String {
        "Keep only \(photoNumber(meta.id, in: group))"
    }
    static func decisionLabel(_ meta: AssetMeta, in group: PhotoGroup) -> String {
        "Keep or remove \(photoNumber(meta.id, in: group))"
    }

    // MARK: List

    static let closeCallShort = "Close call"
    static func keptSafeCount(_ n: Int) -> String { "\(n.formatted()) kept safe" }
    /// "Thu, Oct 12, 6:02 PM". The month header already says the year.
    static func rowDate(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }
    static func rowLabel(_ group: PhotoGroup, kept: Int, removing: Int, keptSafe: Int) -> String {
        var text = groupLabel(group, kept: kept, removing: removing)
        if keptSafe > 0 { text += " \(keptSafeCount(keptSafe))." }
        return text
    }
    static let stillChecking = "Similar shots show up here as they're found."
    static let emptyDetail = "No similar shots in the photos checked."
    static let noneSoFar = "No similar shots in the photos checked so far."
    static let notChecked = "Similar shots show up here after a check."
    static let more = "More"
    static let sort = "Sort"
    static let showKept = "Show groups I kept"
    static let closeCallsRotor = "Close calls"
    static let removeHint = "Shows what goes and what stays before anything is removed."
    static let keepAllHint = "Keeps every photo in this group and takes it off the list."

    static let sortNewest = "Newest first"
    static let sortOldest = "Oldest first"
    static let sortMostExtra = "Most extra photos"

    // MARK: Group screen

    static let photosHeader = "Photos"
    static func pageCount(_ index: Int, of total: Int) -> String { "\(index.formatted()) of \(total.formatted())" }
    static let pagerHint = "Swipe up or down to see the other photos."
    static let tileHint = "Shows it above."
    static let compare = "Compare"
    static let compareBestTwo = "Compare best two"
    static let markedRotor = "Marked for removal"
    static let keptRotor = "Kept"
    static let backToList = "Back to Similar Shots"
    static let goneDetail = "Its photos were removed or kept, here or in Photos."
    static func changed(_ n: Int) -> String {
        "This group changed. \(n == 1 ? "1 photo was" : "\(n.formatted()) photos were") removed in Photos."
    }

    // MARK: Compare

    static let compareTitle = "Compare"
    static let resetZoom = "Reset zoom"
    static func compareAnnouncement(top: String, bottom: String) -> String {
        "Compare. \(top) on top, \(bottom) below."
    }
    static func compareName(_ meta: AssetMeta, in group: PhotoGroup) -> String {
        meta.id == group.keeper.id ? bestPick : "Photo \(group.captureIndex(of: meta.id) ?? 1)"
    }

    // MARK: Reason card and review

    /// Why, for a review of several groups.
    static func fromGroups(_ n: Int) -> String {
        n == 1 ? "From 1 group. The best pick stays." : "From \(Copy.groups(n)). The best pick in each group stays."
    }

    /// What the rules keep, with counts, or nil when nothing is protected.
    static func keptSafe(favorites: Int, edited: Int, albums: Int, documents: Int) -> String? {
        var parts: [String] = []
        if favorites > 0 { parts.append(Copy.count(favorites, "favorite", "favorites")) }
        if edited > 0 { parts.append(Copy.count(edited, "edited photo", "edited photos")) }
        if albums > 0 { parts.append(Copy.count(albums, "photo in an album you protect", "photos in albums you protect")) }
        if documents > 0 { parts.append(Copy.count(documents, "photo that looks like a document", "photos that look like documents")) }
        guard !parts.isEmpty else { return nil }
        let list = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        return "\(list) always \(favorites + edited + albums + documents == 1 ? "stays" : "stay")."
    }

    /// The Undo line before anything is removed.
    static func undoLine(until date: Date) -> String {
        "Removed photos stay in Recently Deleted in Photos until \(Copy.day(date)). Recover them there."
    }
}

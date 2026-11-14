import Foundation
import TidykeepCore

// Text for Copies, Screenshots and Big Videos, kept beside the screens that use it. Shared
// words and the strings other areas use are in Copy.swift.

// MARK: Copies

extension Copy.Copies {
    static let merge = "Merge"
    static let keepingStatus = "Keeping"
    static let removeStatus = "Remove"
    static let keptSafeStatus = "Kept safe"
    static let setGone = "That set is gone."
    static let emptyDetail = "No photo is saved twice."
    static let protectedKeeper = "A favorite or edited copy is always the one kept, so the choice is made for you."
    static let keptSafeFirst = "Copies kept safe always stay, so only a copy listed above them can be the one kept."
    static let cantChooseProtectedKeeper = "Can't be the one kept. A favorite or edited copy is."
    static let cantChooseKeptSafeFirst = "Can't be the one kept. A copy above it is kept safe."
    static let membersHeader = "Copies"
    static let mergeThisTitle = "Merge these copies?"
    static let mergeThisConfirm = "Merge copies"
    static let mergeHint = "Opens a summary to confirm."

    /// "3 copies" for a set of three photos of one picture.
    static func setTitle(_ group: PhotoGroup) -> String { Copy.copies(group.members.count) }

    /// "Oct 12 · 2 to remove"
    static func rowDetail(_ group: PhotoGroup, removing: Int) -> String {
        "\(Copy.day(group.keeper.creationDate)) · \(removing.formatted()) to remove"
    }

    /// "3 copies. Same photo, saved smaller. Oct 12. 2 to remove."
    static func rowLabel(_ group: PhotoGroup, relation: CopyRelation, removing: Int) -> String {
        "\(setTitle(group)). \(Copy.Copies.relation(relation)). From \(Copy.day(group.keeper.creationDate)). \(removing.formatted()) to remove."
    }

    /// What the kept copy has once the set is merged: one sentence, so nothing is a surprise.
    static func afterMerge(favorite: Bool, albums: [String]) -> String {
        var parts: [String] = []
        if favorite { parts.append("a favorite") }
        if !albums.isEmpty { parts.append("in \(list(albums))") }
        guard !parts.isEmpty else { return "After merging, the kept copy stays as it is. Dates don't change." }
        return "After merging, the kept copy is \(parts.joined(separator: " and ")). Dates don't change."
    }

    /// "Trip, Family and Work"
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }

    /// The Why line of a set's reason card. A favorite or edited copy is kept even when
    /// another has more detail.
    static func why(_ relation: CopyRelation, keeperIsProtected: Bool = false) -> String {
        "\(Copy.Copies.relation(relation)). \(keeperIsProtected ? "Keeps the favorite or edited copy." : "Keeps the copy with the most detail.")"
    }

    /// The Why line of the review sheet for one or more sets. The copy that stays may be a
    /// favorite, an edited one or one the user chose, so it isn't called the most detailed.
    static func reviewWhy(sets: Int) -> String {
        let from = sets == 1 ? "From 1 set." : "From \(Copy.sets(sets))."
        return "\(from) The copy that stays is added to the albums of the copies removed. Dates don't change."
    }

    static func keptSafe(_ n: Int) -> String {
        n == 1 ? "1 other copy is kept safe, so it stays as well." : "\(n.formatted()) other copies are kept safe, so they stay as well."
    }

    /// Spoken after a copy is chosen, numbered as the set's rows are: "Keeping copy 2 of 3. 2 to remove."
    static func keepingOnly(_ id: String, in group: PhotoGroup, removing: Int) -> String {
        let number = (group.members.firstIndex { $0.id == id } ?? 0) + 1
        let rest = removing == 0 ? "Nothing to remove." : "\(removing.formatted()) to remove."
        return "Keeping copy \(number) of \(group.members.count). \(rest)"
    }

    static func undo(until date: Date) -> String {
        "Removed copies are in Recently Deleted in Photos until \(Copy.day(date)). The albums added can be taken back in History."
    }
}

// MARK: Screenshots

extension Copy.Screenshots {
    static let markAll = "Mark all"
    static let unmarkAll = "Unmark all"
    static let marked = "Marked"
    static let notMarked = "Not marked"
    static let mark = "Mark for removal"
    static let unmark = "Unmark"
    static let view = "View"
    static let selectHint = "Tap screenshots to mark them for removal."
    static let emptyDetail = "No screenshots to look at."
    static let noneInFilter = "No screenshots this old."
    static let filter = "Show"
    static let markedRotor = "Marked"

    static func summary(_ n: Int, marked: Int) -> String {
        marked == 0 ? "\(Copy.screenshots(n)), newest first" : "\(Copy.screenshots(n)) · \(marked.formatted()) marked"
    }

    /// Under the count when the filter hides some marked screenshots: they stay marked, but
    /// only the ones on screen are removed.
    static func hiddenMarked(_ n: Int) -> String {
        n == 1
            ? "1 marked screenshot isn't shown with this filter, so it won't be removed."
            : "\(n.formatted()) marked screenshots aren't shown with this filter, so they won't be removed."
    }

    static func markAllLabel(_ month: Date) -> String { "Mark all from \(Copy.month(month))" }
    static func unmarkAllLabel(_ month: Date) -> String { "Unmark all from \(Copy.month(month))" }

    /// Under the grid: which screenshots never show here.
    static func keptSafeFooter(albums: Bool) -> String {
        albums
            ? "Favorites, edited screenshots and screenshots in albums are kept safe, so they aren't shown."
            : "Favorites and edited screenshots are kept safe, so they aren't shown."
    }

    static func reviewWhy(months: Int) -> String {
        months == 1 ? "The screenshots you marked, from 1 month." : "The screenshots you marked, from \(months.formatted()) months."
    }

    static func reviewKeptSafe(albums: Bool) -> String {
        albums ? "Favorites, edited screenshots and screenshots in albums stay." : "Favorites and edited screenshots stay."
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all, olderThanMonth, olderThanYear
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All"
            case .olderThanMonth: "Older than a month"
            case .olderThanYear: "Older than a year"
            }
        }
    }
}

// MARK: Big Videos

extension Copy.Videos {
    static let keep = "Keep"
    static let remove = "Remove"
    static let removeVideo = "Remove video"
    static let taken = "Taken"
    static let length = "Length"
    static let size = "Picture size"
    static let gone = "That video is gone."
    static let emptyDetail = "No long videos to look at."
    static let removesEverywhere = "Removing it also removes it from iCloud and your other devices."
    static let keepHint = "Takes it off this list. Undo puts it back."
    static let removeTitle = "Remove this video?"

    /// "5 videos over 1 minute", with the length spelled out.
    static func overMinimum(_ n: Int, minimum: TimeInterval) -> String {
        "\(Copy.videos(n)) over \(spokenDuration(minimum))"
    }

    /// "1 minute", "12 minutes, 34 seconds"
    static func spokenDuration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }

    /// "Video from Oct 12, 2026. 4K. 12 minutes, 34 seconds."
    static func rowLabel(_ meta: VideoMeta) -> String {
        "Video from \(Copy.day(meta.creationDate)). \(resolution(meta)). \(spokenDuration(meta.duration))."
    }

    /// "4K", "HD", or the pixels when it's neither.
    static func resolution(_ meta: VideoMeta) -> String {
        quality(meta).components(separatedBy: " · ").first ?? Copy.pixels(meta.pixelWidth, meta.pixelHeight)
    }

    static func footer(kept: Int) -> String {
        let base = "Favorites and edited videos are kept safe, so they aren't shown. Biggest first, by length and picture size."
        return kept == 0 ? base : "\(base) \(kept == 1 ? "1 video you kept is" : "\(kept.formatted()) videos you kept are") hidden."
    }

    static func reviewWhy(_ n: Int, minimum: TimeInterval) -> String {
        n == 1 ? "A video over \(spokenDuration(minimum)) that you chose." : "Videos over \(spokenDuration(minimum)) that you chose."
    }

    static let reviewKeptSafe = "Favorites and edited videos stay."
}

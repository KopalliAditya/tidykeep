import Foundation
import TidykeepCore

/// History's own words: the receipt screen, its "How to get them back" steps and the one
/// action each row offers.
extension Copy.Receipts {
    static let footer = "History stays on this iPhone. Changes are kept here for a year."
    static let receiptTitle = "Receipt"
    static let missing = "Not in History"
    static let missingDetail = "This change was cleared from History."
    static let canUndoRotor = "Can undo"

    // MARK: Row action

    /// The one thing a row offers, or nil when there's nothing the app can do by itself.
    static func actionTitle(_ kind: Receipt.Kind) -> String {
        switch kind {
        case .copiesMerged: "Undo changes"
        case .keptAll: "Review again"
        case .filesHeld: "Put back"
        case .contactsMerged: Copy.General.undo
        case .photosRemoved, .screenshotsRemoved, .videosRemoved, .filesPutBack, .filesDeleted: Copy.General.undo
        }
    }

    /// What the action does, for VoiceOver.
    static func actionHint(_ kind: Receipt.Kind) -> String {
        switch kind {
        case .copiesMerged: "Takes the favorite and albums back off the kept photo."
        case .keptAll: "Puts it back in the list to look at again."
        case .filesHeld: "Moves the files back where they were."
        case .contactsMerged: "Restores the cards from the backup."
        case .photosRemoved, .screenshotsRemoved, .videosRemoved, .filesPutBack, .filesDeleted: ""
        }
    }

    // MARK: Row

    /// "Today", "Yesterday", or the date, for a day's header.
    static func dayHeader(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return Copy.day(day)
    }

    /// "9:41 AM · In Recently Deleted until Dec 13"
    static func rowStatus(_ r: Receipt, now: Date = Date()) -> String {
        "\(r.date.formatted(date: .omitted, time: .shortened)) · \(status(r, now: now))"
    }

    /// One sentence for VoiceOver: what happened, when, and where it stands.
    static func rowLabel(_ r: Receipt, now: Date = Date()) -> String {
        "\(sentence(r)). \(Copy.dayAndTime(r.date)). \(status(r, now: now))."
    }

    // MARK: Receipt summary

    static let what = "What"
    static let when = "When"
    static let howMany = "How many"
    static let size = "Size"
    static let fileNames = "Files"
    static let keptCard = "Kept card"
    static let undoHeading = Copy.Reason.undo

    /// "18.4 MB (18,420,224 bytes)": files always show their exact size.
    static func exactSize(_ bytes: Int64) -> String {
        "\(Copy.bytes(bytes)) (\(bytes.formatted()) bytes)"
    }

    /// What kind of change this was, in a few words.
    static func whatHappened(_ kind: Receipt.Kind) -> String {
        switch kind {
        case .photosRemoved: "Photos removed"
        case .screenshotsRemoved: "Screenshots removed"
        case .videosRemoved: "Videos removed"
        case .copiesMerged: "Copies merged onto the kept photo"
        case .keptAll: "Kept all. Nothing was removed."
        case .filesHeld: "Files moved to the Held by \(Copy.appName) folder"
        case .filesPutBack: "Files put back where they were"
        case .filesDeleted: "Files deleted permanently"
        case .contactsMerged: "Contact cards merged into one"
        }
    }

    /// "9 photos", "18 of 23 photos", "23 photos, still checking".
    static func howManyValue(_ r: Receipt) -> String {
        let noun = itemCount(r.kind)
        switch r.status {
        case .inProgress: return "\(noun(r.requested)), still checking"
        case .failed: return "None of \(noun(r.requested))"
        case .partial: return "\(r.completed.formatted()) of \(noun(r.requested))"
        case .done, .undone: return noun(r.kind == .keptAll || r.kind == .contactsMerged ? r.requested : r.completed)
        }
    }

    private static func itemCount(_ kind: Receipt.Kind) -> (Int) -> String {
        switch kind {
        case .photosRemoved, .keptAll: Copy.photos
        case .screenshotsRemoved: Copy.screenshots
        case .videosRemoved: Copy.videos
        case .copiesMerged: Copy.copies
        case .filesHeld, .filesPutBack, .filesDeleted: Copy.files
        case .contactsMerged: Copy.cards
        }
    }

    /// File names, one per line, for file receipts. Long lists end with "and N more".
    static func fileNameList(_ r: Receipt, limit: Int = 8) -> String? {
        switch r.kind {
        case .filesHeld, .filesPutBack, .filesDeleted: break
        default: return nil
        }
        var names = r.itemIDs.map { ($0 as NSString).lastPathComponent }.filter { !$0.isEmpty }
        if names.isEmpty, let title = r.title { names = [title] }
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(limit).joined(separator: "\n")
        return names.count > limit ? shown + "\nand \((names.count - limit).formatted()) more" : shown
    }

    /// Where it went and until when, or "Can't be undone." The Reason card's Undo line.
    static func undoLine(_ r: Receipt, now: Date = Date()) -> String {
        switch r.status {
        case .undone: return "Already undone."
        case .failed: return "Nothing changed, so there's nothing to undo."
        case .inProgress: return "Checking what changed."
        case .done, .partial: break
        }
        switch r.kind {
        case .photosRemoved, .screenshotsRemoved, .videosRemoved:
            if let deadline = r.deadline, deadline > now { return Copy.Reason.recentlyDeleted(until: deadline) }
            return "Photos has emptied Recently Deleted, so these can't be brought back."
        case .copiesMerged:
            if let deadline = r.deadline, deadline > now {
                return "Undo changes takes the favorite and albums back. The removed copies are in Recently Deleted in Photos until \(Copy.day(deadline))."
            }
            return "Undo changes takes the favorite and albums back. The removed copies are gone from Recently Deleted."
        case .keptAll: return "Review again puts it back in the list."
        case .filesHeld: return "Put back moves the files where they were."
        case .filesPutBack: return "Nothing to undo. The files are back where they were."
        case .filesDeleted: return Copy.Reason.cantBeUndone
        case .contactsMerged: return "Undo restores the cards from the backup saved on this iPhone."
        }
    }

    // MARK: How to get them back

    static let howToGetBack = "How to get them back"

    /// The line above the steps.
    static func recoveryIntro(_ r: Receipt, now: Date = Date()) -> String {
        switch r.status {
        case .undone: return "This change was undone."
        case .failed: return "Nothing changed, so there's nothing to get back."
        case .inProgress: return "\(Copy.appName) is checking what changed. This finishes on its own."
        case .done, .partial: break
        }
        switch r.kind {
        case .photosRemoved, .screenshotsRemoved, .videosRemoved, .copiesMerged:
            guard let deadline = r.deadline, deadline > now else {
                return "Photos keeps removed items in Recently Deleted for \(Receipt.recentlyDeletedDays) days, then deletes them for good. These are past that, so they can't be brought back."
            }
            return r.kind == .copiesMerged
                ? "The removed copies are in Recently Deleted in the Photos app until \(Copy.day(deadline)). Recover them there."
                : "They're in Recently Deleted in the Photos app until \(Copy.day(deadline)). Recover them there."
        case .keptAll: return "Nothing was removed. The group just isn't suggested again."
        case .filesHeld: return "The files wait in the Held by \(Copy.appName) folder, inside the folder they came from."
        case .filesPutBack: return "The files are back where they were. There's nothing to get back."
        case .filesDeleted: return "These files were deleted permanently. They can't be brought back."
        case .contactsMerged: return "Before merging, \(Copy.appName) saved a backup of the cards on this iPhone."
        }
    }

    /// Numbered steps, or none when there's nothing to do.
    static func recoverySteps(_ r: Receipt, now: Date = Date()) -> [String] {
        guard r.status == .done || r.status == .partial else { return [] }
        switch r.kind {
        case .photosRemoved, .screenshotsRemoved, .videosRemoved, .copiesMerged:
            guard let deadline = r.deadline, deadline > now else { return [] }
            var steps = [
                "Open the Photos app.",
                "Tap Collections, then scroll down to Utilities.",
                "Tap Recently Deleted, then unlock with Face ID or your passcode.",
                "Tap Select and choose the ones to bring back.",
                "Tap Recover.",
            ]
            if r.kind == .copiesMerged {
                steps.append("To take the favorite and albums back off the kept photo, tap Undo changes below.")
            }
            return steps
        case .keptAll:
            return ["Tap Review again below. The group goes back in the list to look at again."]
        case .filesHeld:
            return [
                "Tap Put back below to move every file where it was.",
                "Or open the Files app, go to the Held by \(Copy.appName) folder and move them yourself.",
            ]
        case .contactsMerged:
            return [
                "Tap Undo below.",
                "The kept card goes back to how it was, and the removed cards come back from the backup.",
                "Links other apps made to the removed cards don't come back.",
            ]
        case .filesPutBack, .filesDeleted:
            return []
        }
    }

    /// VoiceOver reads the step number first.
    static func stepLabel(_ index: Int, _ text: String) -> String { "Step \(index). \(text)" }
}

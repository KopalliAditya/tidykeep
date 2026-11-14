import Foundation
import TidykeepCore

/// User-facing text, including everything VoiceOver reads. Kept in nested enums so it stays
/// consistent and can be tested. An area may add its own enum in an `extension Copy` in its
/// own file.
///
/// Voice: plain, calm, specific. Sentence case for buttons. No "we", "oops", "!", "junk" or
/// "free up space". Photos and videos never show bytes; files always show exact bytes.
enum Copy {
    static let appName = AppInfo.name

    // MARK: Counting

    static func count(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n.formatted()) \(n == 1 ? one : many)"
    }

    static func photos(_ n: Int) -> String { count(n, "photo", "photos") }
    static func groups(_ n: Int) -> String { count(n, "group", "groups") }
    static func sets(_ n: Int) -> String { count(n, "set", "sets") }
    static func copies(_ n: Int) -> String { count(n, "copy", "copies") }
    static func screenshots(_ n: Int) -> String { count(n, "screenshot", "screenshots") }
    static func videos(_ n: Int) -> String { count(n, "video", "videos") }
    static func files(_ n: Int) -> String { count(n, "file", "files") }
    static func cards(_ n: Int) -> String { count(n, "card", "cards") }
    static func extraPhotos(_ n: Int) -> String { count(n, "extra photo", "extra photos") }
    static func extraCopies(_ n: Int) -> String { count(n, "extra copy", "extra copies") }

    /// Exact bytes on disk, for files only: "1.2 GB".
    static func bytes(_ n: Int64) -> String { n.formatted(.byteCount(style: .file)) }

    /// "4032 × 3024"
    static func pixels(_ width: Int, _ height: Int) -> String { "\(width) × \(height)" }
    /// "4032 by 3024", for VoiceOver.
    static func pixelsSpoken(_ width: Int, _ height: Int) -> String { "\(width) by \(height)" }

    /// "4 min, 12 sec"
    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }

    /// "4:12", for the capsule on a video poster.
    static func clock(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.rounded()).formatted(.time(pattern: seconds >= 3_600 ? .hourMinuteSecond : .minuteSecond))
    }

    static func day(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .omitted) }
    static func dayAndTime(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }
    static func month(_ date: Date) -> String { date.formatted(.dateTime.month(.wide).year()) }

    // MARK: Shared words

    enum General {
        static let dismiss = "Dismiss"
        static let done = "Done"
        static let cancel = "Cancel"
        static let close = "Close"
        static let undo = "Undo"
        static let tryAgain = "Try again"
        static let openSettings = "Open Settings"
        static let keepAll = "Keep all"
        static let checkAgain = "Check again"
        static let select = "Select"
        static let off = "Off"
        static let favorite = "Favorite"
        static let edited = "Edited"
    }

    enum Reason {
        static let why = "Why"
        static let keptSafe = "Kept safe"
        static let undo = "Undo"
        static let cantBeUndone = "Can't be undone."
        static let alwaysKept = "Favorites and edited photos stay."

        static func recentlyDeleted(until date: Date) -> String {
            "In Recently Deleted in Photos until \(day(date)). Recover them there."
        }
    }

    enum Tabs {
        static let tidy = "Tidy"
        static let history = "History"
        static let rules = "Rules"
    }

    // MARK: Onboarding and access

    enum Onboarding {
        static let title = "Tidy up, keep the good ones"
        static let rows: [(symbol: String, text: String)] = [
            ("photo.stack", "Finds similar shots, copies, screenshots, big videos, duplicate files and contacts."),
            ("text.magnifyingglass", "Says why it suggests each thing. Nothing changes until you confirm."),
            ("arrow.uturn.backward", "Every change is in History, with the way back where there is one."),
            ("lock.shield", "Everything stays on this iPhone. No account, no network."),
        ]
        static let `continue` = "Continue"
    }

    enum Access {
        static let photosOff = "Photos access is off"
        static let photosOffDetail = "\(appName) needs your photos to find similar shots and copies. Files and contacts still work."
        static let allowPhotos = "Allow photos"
        static func limited(_ n: Int) -> String { "Checking the \(photos(n)) you chose." }
        static let chooseMore = "Choose more photos"
    }

    // MARK: Home

    enum Home {
        static let photos = "Photos"
        static let files = "Files"
        static let contacts = "Contacts"
        static let lastChange = "Last change"
        static let similar = "Similar Shots"
        static let copies = "Copies"
        static let screenshots = "Screenshots"
        static let videos = "Big Videos"
        static let duplicateFiles = "Duplicate Files"
        static let largeFiles = "Large Files"
        static let holding = "Holding"
        static let duplicateContacts = "Duplicate Contacts"
        static let checking = "Checking…"
        static let noneFound = "None found"
        static let chooseFolders = "Choose folders"
        static let allowContacts = "Allow contacts"
        static let empty = "Empty"

        static func folders(_ n: Int) -> String { n == 0 ? "No folders chosen" : count(n, "folder", "folders") }

        /// VoiceOver label for a card: "Similar Shots, 23 groups, 61 extra photos".
        static func cardLabel(_ title: String, _ parts: String?...) -> String {
            ([title] + parts.compactMap { $0 }).joined(separator: ", ")
        }
    }

    // MARK: Checking

    enum Scan {
        static let keepOpen = "Keep \(appName) open to finish. It picks up where it left off."
        static let paused = "Paused while iPhone cools down"
        static let stopped = "Stopped. Check again to finish."
        static let failed = "Couldn't read your photo library. Nothing was changed."
        static let gettingReady = "Getting ready"

        static func progress(_ p: ScanProgress) -> String {
            p.photosInRange == 0 ? gettingReady : "\(p.checked.formatted()) of \(p.photosInRange.formatted()) checked"
        }

        static func done(similar: Int, copies: Int) -> String {
            similar + copies == 0
                ? "Done checking. All tidy."
                : "Done checking. \(groups(similar)) of similar shots, \(sets(copies)) of copies."
        }
    }

    enum Coverage {
        static let title = "What was checked"
        static func line(checked: Int, skipped: Int) -> String {
            skipped == 0 ? "Checked \(photos(checked))" : "Checked \(photos(checked)) · \(skipped.formatted()) skipped"
        }
        static func reason(_ reason: SkipReason) -> String {
            switch reason {
            case .iCloudOnly: "Only in iCloud"
            case .unreadable: "Couldn't be read"
            case .sharedAlbum: "In Shared Albums"
            case .outsideRange: "Older than the range you chose"
            case .keptByRule: "Kept safe by your rules"
            }
        }
        static func explanation(_ reason: SkipReason) -> String {
            switch reason {
            case .iCloudOnly: "\(appName) never downloads, so photos stored only in iCloud aren't looked at."
            case .unreadable: "These couldn't be opened on this iPhone."
            case .sharedAlbum: "Shared Albums belong to everyone in them, so they're never suggested."
            case .outsideRange: "Look further back in Rules."
            case .keptByRule: "Photos in albums you protect are never suggested."
            }
        }
        static let footer = "Skipped photos are never changed."
    }

    // MARK: Similar shots

    enum Similar {
        static let title = "Similar Shots"
        static func groupTitle(_ group: PhotoGroup) -> String { "\(group.members.count) similar photos" }
        static func summary(groups: Int, extras: Int) -> String {
            groups == 0 ? Empty.allTidy : "\(Copy.groups(groups)) · \(extraPhotos(extras))"
        }
        static func keepRemove(kept: Int, removing: Int) -> String {
            removing == 0 ? "Keeping all \(kept)" : "Keep \(kept) · Remove \(removing)"
        }
        /// Spoken after a keep or remove choice changes: "4 to keep, 2 to remove."
        static func tally(_ group: PhotoGroup, removing: Int) -> String {
            removing == 0 ? "Keeping all \(group.members.count)." : "\(group.members.count - removing) to keep, \(removing) to remove."
        }
        static func groupLabel(_ group: PhotoGroup, kept: Int, removing: Int) -> String {
            var text = "\(groupTitle(group)) from \(dayAndTime(group.startDate)). "
            text += removing == 0 ? "Keeping all of them." : "\(kept) to keep, \(removing) to remove."
            if group.ranking.isCloseCall { text += " Close call, worth a look." }
            return text
        }
        /// "photo 3", by capture order, matching the tiles.
        static func photoNumber(_ id: String, in group: PhotoGroup) -> String { "photo \(group.captureIndex(of: id) ?? 1)" }
        static func photoLabel(_ meta: AssetMeta, in group: PhotoGroup) -> String {
            "Photo \(group.captureIndex(of: meta.id) ?? 1) of \(group.members.count), taken \(meta.creationDate.formatted(.dateTime.hour().minute().second()))"
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
            if meta.isFavorite && !pickedAsFavorite { parts.append(General.favorite) }
            if meta.hasAdjustments { parts.append(General.edited) }
            if group.documentIDs.contains(meta.id) { parts.append("Looks like a document") }
            if group.ruleIDs.contains(meta.id) { parts.append("In an album you protect") }
            return parts.joined(separator: ". ")
        }
        /// Why a photo can't be removed, or nil when it can.
        static func protectedNote(_ meta: AssetMeta, in group: PhotoGroup) -> String? {
            if meta.isFavorite { return "This is a favorite, so it's always kept." }
            if meta.hasAdjustments { return "This photo is edited, so it's always kept." }
            if group.ruleIDs.contains(meta.id) { return "This is in an album you protect, so it's always kept." }
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
            group.ranking.reasons == [.favorite] ? "Kept because \(PickReason.favorite.phrase)." : "Best pick: \(reasons(group.ranking.reasons))."
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
        static let protectedRefusal = "Favorites, edited photos and photos in albums you protect are always kept."
        static let lastKeptRefusal = "Each group keeps at least one photo."
        static let bestPick = "Best pick"
        static let keepOnlyThis = "Keep only this"
        static let groupGone = "That group is gone."
        static func removeButton(_ n: Int) -> String { "Remove \(photos(n))" }
    }

    // MARK: Copies

    enum Copies {
        static let title = "Copies"
        static func relation(_ relation: CopyRelation) -> String {
            switch relation {
            case .exact: "Exact copy"
            case .smaller: "Same photo, saved smaller"
            case .otherFormat: "Same photo, different format"
            case .screenshot: "Screenshot of this photo"
            }
        }
        static let explainer = "Keeps the copy with the most detail. Its favorite and albums move to it. Dates don't change."
        static let keeping = "Keeping this one"
        static let keepThisInstead = "Keep this copy instead"
        static func summary(sets: Int, extras: Int) -> String {
            sets == 0 ? Empty.allTidy : "\(Copy.sets(sets)) · \(extraCopies(extras))"
        }
        static func mergeButton(_ n: Int) -> String { "Merge \(sets(n))" }
        static let stillLooking = "Still looking for copies. More may show up."
        static func memberLine(_ meta: AssetMeta, format: String?) -> String {
            [pixels(meta.pixelWidth, meta.pixelHeight), format, day(meta.creationDate)].compactMap { $0 }.joined(separator: " · ")
        }
        static func memberLabel(index: Int, of total: Int, _ meta: AssetMeta, format: String?) -> String {
            ["Copy \(index) of \(total)", pixelsSpoken(meta.pixelWidth, meta.pixelHeight), format, day(meta.creationDate)]
                .compactMap { $0 }.joined(separator: ", ")
        }
    }

    // MARK: Screenshots and videos

    enum Screenshots {
        static let title = "Screenshots"
        static func removeButton(_ n: Int) -> String { "Remove \(screenshots(n))" }
        static func tileLabel(_ meta: AssetMeta) -> String { "Screenshot, \(dayAndTime(meta.creationDate))" }
    }

    enum Videos {
        static let title = "Big Videos"
        static func subtitle(_ n: Int, minimum: TimeInterval) -> String { "\(videos(n)) over \(duration(minimum))" }
        static func removeButton(_ n: Int) -> String { "Remove \(videos(n))" }
        static func quality(_ meta: VideoMeta) -> String {
            let short = min(meta.pixelWidth, meta.pixelHeight)
            let label = short >= 2_160 ? "4K" : short >= 1_080 ? "HD" : short >= 720 ? "720p" : pixels(meta.pixelWidth, meta.pixelHeight)
            return "\(label) · \(duration(meta.duration))"
        }
        static let cantPlay = "This video is only in iCloud. \(appName) doesn't download, so it can't play here."
    }

    // MARK: Review sheet

    enum Review {
        static func removePhotos(_ n: Int) -> String { "Remove \(photos(n))?" }
        static func removeScreenshots(_ n: Int) -> String { "Remove \(screenshots(n))?" }
        static func removeVideos(_ n: Int) -> String { "Remove \(videos(n))?" }
        static func mergeSets(_ n: Int) -> String { "Merge \(sets(n))?" }
        static let removing = "Removing"
        static let staying = "Staying"
        static let sharedLibrary = "If you use a Shared Library, removing a shared photo removes it for everyone in it."
        static func moreCount(_ n: Int) -> String { "+\(n.formatted())" }
    }

    // MARK: Notices

    enum Notices {
        static func removedPhotos(_ n: Int) -> String { "Removed \(photos(n)). They're in Recently Deleted in Photos for 30 days." }
        static func removedScreenshots(_ n: Int) -> String { "Removed \(screenshots(n)). They're in Recently Deleted in Photos for 30 days." }
        static func removedVideos(_ n: Int) -> String { "Removed \(videos(n)). They're in Recently Deleted in Photos for 30 days." }
        static func mergedSets(_ sets: Int, copies: Int) -> String {
            "Merged \(Copy.sets(sets)). The \(Copy.copies(copies)) removed \(copies == 1 ? "is" : "are") in Recently Deleted for 30 days."
        }
        static func keptAll(_ n: Int) -> String { "Kept all \(n)." }
        static let nothingRemoved = "Nothing removed."
        static let nothingChanged = "Nothing changed."
        static let mergeUndone = "Took back the favorite and albums. The removed copies are in Recently Deleted in Photos."
        static let reviewAgain = "It's back in the list."
        static let analysisCleared = "Saved analysis cleared. Checking your photos again."
        static let historyCleared = "History cleared."
        static let recoverInPhotos = "Open Photos, then Recently Deleted, to recover them."
    }

    // MARK: History

    enum Receipts {
        /// The sentence for a History row and the Home "Last change" row.
        static func sentence(_ r: Receipt) -> String {
            let n = r.status == .inProgress || r.status == .failed ? r.requested : r.completed
            switch r.kind {
            case .photosRemoved: return "Removed \(photos(n))"
            case .screenshotsRemoved: return "Removed \(screenshots(n))"
            case .videosRemoved: return "Removed \(videos(n))"
            case .copiesMerged: return "Merged \(copies(n))"
            case .keptAll: return "Kept all \(photos(r.requested))"
            case .filesHeld:
                if n == 1, let title = r.title { return "Moved \u{201C}\(title)\u{201D} to Holding" }
                return "Moved \(files(n)) to Holding"
            case .filesPutBack: return "Put back \(files(n))"
            case .filesDeleted: return "Deleted \(files(n))"
            case .contactsMerged:
                if let title = r.title { return "Merged \(cards(r.requested)) into \(title)" }
                return "Merged \(cards(r.requested))"
            }
        }

        static func symbol(_ kind: Receipt.Kind) -> String {
            switch kind {
            case .photosRemoved: "photo.stack"
            case .screenshotsRemoved: "camera.viewfinder"
            case .videosRemoved: "video"
            case .copiesMerged: "square.on.square"
            case .keptAll: "checkmark.circle"
            case .filesHeld: "tray.and.arrow.down"
            case .filesPutBack: "arrow.uturn.backward"
            case .filesDeleted: "trash"
            case .contactsMerged: "person.2.crop.square.stack"
            }
        }

        /// The status line under the sentence.
        static func status(_ r: Receipt, now: Date = Date()) -> String {
            switch r.status {
            case .inProgress: return "Not finished. Checking what changed."
            case .failed: return Notices.nothingChanged
            case .undone: return "Undone"
            case .done, .partial: break
            }
            var line: String
            switch r.kind {
            case .photosRemoved, .screenshotsRemoved, .videosRemoved, .copiesMerged:
                if let deadline = r.deadline, deadline > now {
                    line = "In Recently Deleted until \(day(deadline))"
                } else {
                    line = "Gone from Recently Deleted"
                }
            case .keptAll: line = "Won't be suggested again"
            case .filesHeld: line = r.bytes.map { "\(Copy.bytes($0)) in Holding" } ?? "In Holding"
            case .filesPutBack: line = "Back where they were"
            case .filesDeleted: line = r.bytes.map { "\(Copy.bytes($0)) free again" } ?? "Deleted"
            case .contactsMerged: line = "Backup saved on this iPhone"
            }
            if r.status == .partial { line = "\(r.completed.formatted()) of \(r.requested.formatted()) done · " + line }
            return line
        }

        static let empty = "No history yet"
        static let emptyDetail = "Things you remove, move or merge show up here, with the way back where there is one."
    }

    // MARK: Empty and error states

    enum Empty {
        static let allTidy = "All tidy"
    }
}

public enum AppInfo {
    /// The one place the app's name lives in code. The home-screen name is CFBundleDisplayName.
    public static let name = "Tidykeep"

    public static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
}

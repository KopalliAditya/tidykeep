import Foundation
import TidykeepFiles

// The words for duplicate files, large files, Holding and chosen folders. Files always show
// exact bytes on disk (`Copy.bytes`), and progress reads "N of M checked".

extension Copy {
    enum Files {
        static let holdingFolder = HoldingFolder.name

        // MARK: Checking

        static let gettingReady = Scan.gettingReady
        static func listing(_ found: Int) -> String { "Getting ready · \(files(found)) found" }
        static func progress(checked: Int, total: Int) -> String { "\(checked.formatted()) of \(total.formatted()) checked" }
        static func coverage(checked: Int, skipped: Int) -> String {
            skipped == 0 ? "Checked \(files(checked))" : "Checked \(files(checked)) · \(skipped.formatted()) skipped"
        }
        static let coverageHint = "Shows what was left out, and why."
        static let coverageTitle = "What was checked"
        static func coverageChecked(_ n: Int) -> String { "Checked \(files(n))" }
        static func skipReason(_ reason: FileSkipReason) -> String {
            switch reason {
            case .iCloudOnly: "Only in iCloud"
            case .unreadable: "Couldn't be read"
            }
        }
        static func skipExplanation(_ reason: FileSkipReason) -> String {
            switch reason {
            case .iCloudOnly: "\(appName) never downloads, so files stored only in iCloud aren't looked at."
            case .unreadable: "These couldn't be opened, or changed while they were checked."
            }
        }
        static let keptByRule = Coverage.reason(.keptByRule)
        static func keptByRuleExplanation(days: Int?) -> String {
            guard let days else { return "Nothing is held back by your rules right now." }
            return "Files changed in the last \(dayCount(days)) are never suggested."
        }
        static let coverageFooter = "Skipped files are never changed."

        static func dayCount(_ n: Int) -> String { count(n, "day", "days") }

        /// The footer under a list when the 7-day rule is on.
        static func recentRule(days: Int?, kept: Int) -> String? {
            guard let days else { return nil }
            let base = "Files changed in the last \(dayCount(days)) aren't suggested, so work in progress stays put."
            return kept == 0 ? base : "\(base) \(files(kept)) kept safe this time. Change this in Rules."
        }

        // MARK: Folders

        static let chooseFolders = Home.chooseFolders
        static let chooseFoldersHint = "Opens the folder picker. Choose one or more folders in Files or iCloud Drive."
        static let noFoldersTitle = "Choose folders to check"
        static let noFoldersDetail = "Pick folders in Files or iCloud Drive, such as Downloads. \(appName) looks for identical files and large files there. Nothing changes until you choose."
        static let foldersHeader = "Folders"
        static let addFolder = "Add folder"
        static let removeFolder = "Stop checking"
        static let available = "Checked each time"
        static let unavailable = "Can't be opened. Choose it again."
        static func unavailableNote(_ name: String) -> String {
            "Can't open \(name), so it wasn't checked. Choose it again to check it."
        }
        static let foldersFooter = "Stop checking a folder and any of its files in Holding go back where they were first."
        static let noFoldersYet = "No folders chosen yet."
        static func folderLabel(_ name: String, available: Bool) -> String {
            "\(name), \(available ? Files.available : unavailable)"
        }
        static func addedFolders(_ names: [String]) -> String {
            names.count == 1 ? "Checking \u{201C}\(names[0])\u{201D}." : "Checking \(count(names.count, "folder", "folders"))."
        }
        static func removedFolder(_ name: String) -> String { "Stopped checking \u{201C}\(name)\u{201D}." }
        static let formerFolder = "A folder no longer checked"

        // MARK: Duplicate files

        static let duplicatesTitle = Home.duplicateFiles
        /// `sureNothing` is false when the check didn't see the folders, so an empty list
        /// can't be called done. When it is, "All tidy" below says the rest.
        static func duplicatesSummary(sets: Int, extras: Int, bytes: Int64, sureNothing: Bool = true) -> String {
            guard sets > 0 else { return sureNothing ? checked : notChecked }
            return "\(Copy.sets(sets)) · \(extraCopies(extras)) · \(Copy.bytes(bytes))"
        }
        /// The headline when the folders couldn't be checked; the error below says why.
        static let notChecked = "Not checked"
        /// The headline above "All tidy" once the folders were checked.
        static let checked = "Done checking"
        static func noDuplicates(folders: Int) -> String {
            "No identical files in \(count(folders, "folder", "folders"))."
        }
        static func setTitle(_ copies: Int) -> String { "\(copies.formatted()) identical files" }
        static func setLine(name: String, bytes: Int64) -> String { "\(name) · \(Copy.bytes(bytes)) each" }
        static func setRowLabel(name: String, copies: Int, extraBytes: Int64) -> String {
            "\(name), \(Copy.copies(copies)), \(Copy.bytes(extraBytes)) in extra copies"
        }
        static func extraBytes(_ n: Int64) -> String { "\(Copy.bytes(n)) in extra copies" }
        static let keeping = "Keeping"
        static let keepingThis = "Keeping this one"
        static let movingSection = "Moving to Holding"
        static let stayingSection = "Staying"
        static let keepThisInstead = "Keep this instead"
        static let keepThisCopyInstead = "Keep this copy instead"
        static func keepThisInsteadHint(_ name: String) -> String { "Keeps this copy and moves \u{201C}\(name)\u{201D} instead." }
        /// What happens to a copy, read after its name by VoiceOver.
        static let keepingValue = "Keeping"
        static let movingValue = "Moving to Holding"
        static let stayingValue = "Staying, changed recently"
        static func copyRowLabel(_ item: FileItem, folder: String) -> String {
            "\(item.name), in \(folder), \(Copy.bytes(item.bytes)), changed \(day(item.modified))"
        }
        static func nameIn(_ name: String, folder: String) -> String { "\(name) in \(folder)" }
        static func keeperChanged(_ name: String) -> String { "Keeping \u{201C}\(name)\u{201D}." }
        static let changedRecently = "Changed recently, so it stays"
        static func moveButton(_ n: Int) -> String { "Move \(n.formatted()) to Holding" }
        static func moveAllTitle(_ n: Int) -> String { "Move \(files(n)) to Holding?" }
        static let setGone = "These files changed or were moved. Check again to see them as they are now."
        static let setMoved = "Moved to Holding. Put it back from Holding or History."

        static let whyIdentical = "Same size and the same content, byte for byte."
        static func whyIdenticalSets(_ n: Int) -> String {
            n == 1 ? whyIdentical : "From \(sets(n)): each has the same size and content, byte for byte. One copy of each stays."
        }
        static func keptSafeKeeper(_ name: String, recent: Int) -> String {
            let keeper = "\u{201C}\(name)\u{201D} stays where it is. Nothing is deleted."
            return recent == 0 ? keeper : "\(keeper) \(files(recent)) changed recently and stay too."
        }
        static let keptSafeKeepers = "One copy of each stays where it is. Nothing is deleted."
        static let undoHolding = "Files go to \u{201C}\(HoldingFolder.name)\u{201D} in the same folder. Put them back from Holding or History."

        // MARK: Large files

        static let largeTitle = Home.largeFiles
        static func largeSummary(_ n: Int, bytes: Int64, minimum: Int64, sureNothing: Bool = true) -> String {
            guard n > 0 else { return sureNothing ? checked : notChecked }
            return "\(files(n)) over \(Copy.bytes(minimum)) · \(Copy.bytes(bytes))"
        }
        static func noLargeFiles(minimum: Int64) -> String { "No files over \(Copy.bytes(minimum))." }
        static let moveToHolding = "Move to Holding"
        static let selectAll = "Select all"
        static let deselectAll = "Deselect all"
        static let selectHint = "Selects it to move to Holding."
        static let largeFooter = "Moving a file to Holding keeps it in the same folder, in \u{201C}\(HoldingFolder.name)\u{201D}. Nothing is deleted."
        static func largeRowLabel(_ item: FileItem, folder: String) -> String {
            "\(item.name), \(Copy.bytes(item.bytes)), in \(folder), changed \(day(item.modified))"
        }
        static func changed(_ date: Date) -> String { "Changed \(day(date))" }
        static func movedAt(_ date: Date) -> String { "Moved \(dayAndTime(date))" }
        static func from(_ folder: String) -> String { "From \(folder)" }
        static func exactBytes(_ n: Int64) -> String { "\(n.formatted()) bytes" }

        // MARK: Holding

        static let holdingTitle = Home.holding
        static let putBack = "Put back"
        static let putAllBack = "Put all back"
        static let emptyHolding = "Empty Holding"
        static let deleteNow = "Delete"
        static func holdingSummary(_ n: Int, bytes: Int64) -> String { "\(files(n)) · \(Copy.bytes(bytes))" }
        static let holdingExplainer = "Held files wait in \u{201C}\(HoldingFolder.name)\u{201D} inside the folder they came from. Put them back any time. Nothing is deleted until you empty Holding."
        static let holdingEmptyTitle = "Holding is empty"
        static let holdingEmptyDetail = "When you move a file to Holding, it waits in a \u{201C}\(HoldingFolder.name)\u{201D} folder inside the folder it came from. Put it back any time, or empty Holding to delete it for good."
        static func heldLine(folder: String, movedAt: Date) -> String { "From \(folder) · Moved \(dayAndTime(movedAt))" }
        static func heldRowLabel(_ item: HoldingItem, folder: String) -> String {
            "\(item.name), \(Copy.bytes(item.bytes)), from \(folder), moved \(dayAndTime(item.movedAt))"
        }
        static func removeTitle(_ n: Int) -> String { "Remove \(files(n)) for good?" }
        static func deleteButton(_ n: Int) -> String { "Delete \(files(n))" }
        static func whyDelete(_ n: Int) -> String {
            "\(n == 1 ? "It's" : "They're") in Holding, and you asked to delete \(n == 1 ? "it" : "them")."
        }
        static let keptSafeDelete = "Only the files listed here are deleted. Nothing outside Holding changes."
        static let iCloudDelete = "Files in iCloud Drive are also removed from your other devices."
        static func undoDelete(iCloud: Bool) -> String {
            iCloud ? "\(Copy.Reason.cantBeUndone) \(iCloudDelete)" : Copy.Reason.cantBeUndone
        }
        static let chooseWhere = "Choose where to put it back"
        static let chooseWhereHint = "Opens the file mover, because the folder it came from is gone."
        static let folderGone = "Its folder is gone"

        // MARK: Notices

        static func moved(_ n: Int) -> String { "Moved \(files(n)) to Holding." }
        static func putBackDone(_ n: Int) -> String { "Put back \(files(n))." }
        static func placed(_ name: String, in folder: String) -> String { "Put \(name) in \(folder)." }
        static func deleted(_ n: Int, bytes: Int64, iCloud: Bool) -> String {
            iCloud ? "Deleted \(files(n)). Removed from iCloud Drive." : "Deleted \(files(n)). \(Copy.bytes(bytes)) is free again."
        }
        static let nothingToPutBack = "These files aren't in Holding anymore."
        static func partly(_ done: String, failed: Int) -> String { "\(done) \(files(failed)) couldn't be changed." }

        // MARK: Errors

        static func error(_ error: FilesError) -> String {
            switch error {
            case .notEnoughSpace(let name): "Couldn't move \(name). The iPhone is full."
            case .originalFolderMissing(let name, let folder): "Couldn't put back \(name). Its folder \(folder) is gone, so it's still in Holding. Choose where to put it back."
            case .outsideFolder(let name): "Couldn't move \(name). It's no longer in a folder you chose."
            case .fileChanged(let name): "\(name) changed since the check, so nothing was moved. Check again to see it as it is now."
            case .unreadable(let path): "Couldn't read \(path)."
            case .couldNotMove(let name, let folder): "Couldn't move \(name). It's still in \(folder)."
            case .couldNotDelete(let name): "Couldn't delete \(name). It's still in Holding."
            case .heldFileMissing(let name): "\(name) isn't in \u{201C}\(HoldingFolder.name)\u{201D} anymore."
            case .notHeld: "That file isn't in Holding anymore."
            case .folderUnavailable(let name): "Can't open \(name) right now. Choose it again in Rules."
            case .couldNotSaveManifest: "Couldn't save the list of held files, so nothing was moved."
            }
        }
        static let couldNotAddFolder = "Couldn't use that folder. Try choosing it again."
        static let checkFailed = "Couldn't check the folders. Nothing was changed."
    }
}

extension Copy.Files {
    /// The sample folder's files, for UI tests and screenshots on the simulator.
    enum Sample {
        static let original = "Trip notes.pdf"
        static let copy = "Trip notes copy.pdf"
        static let note = "Packing list.txt"
        static let export = "Big export.mov"
        static let pdfTitle = "Trip notes"
        static let pdfLines = [
            "Day 1: Arrive in the afternoon, check in, walk along the river.",
            "Day 2: Old town in the morning. Market for lunch. Museum after 3.",
            "Day 3: Train to the coast at 9:40. Swim, then dinner by the harbour.",
            "Day 4: Slow morning. Pack. Taxi to the station at 2.",
            "",
            "Bookings: hotel confirmed, train seats in coach 6.",
            "Bring: adapters, rain jacket, the good camera, a paper map.",
        ]
        static let noteText = """
        Packing list
        - passport
        - chargers and adapters
        - rain jacket
        - walking shoes
        - camera and spare card
        """
    }
}

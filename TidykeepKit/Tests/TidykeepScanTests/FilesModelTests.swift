import Foundation
import Testing
import TidykeepCore
import TidykeepFiles
@testable import TidykeepUI

/// The Files model against real folders in the temporary directory: the sample folder, moves to
/// Holding and back, emptying Holding, and the 7-day rule.
@MainActor @Suite(.serialized) struct FilesModelTests {
    let documents: URL
    let data: URL
    let defaults: UserDefaults
    let preferences: Preferences
    let history: History
    let notices: Notices

    init() {
        documents = temporaryDirectory("files-docs-\(UUID().uuidString)")
        data = temporaryDirectory("files-data-\(UUID().uuidString)")
        defaults = freshDefaults()
        preferences = Preferences(defaults: defaults)
        history = History(directory: data)
        notices = Notices()
    }

    private var sample: URL { documents.appendingPathComponent(FilesModel.sampleFolderName, isDirectory: true) }

    private func makeModel(directory: URL? = nil) -> FilesModel {
        FilesModel(directory: directory ?? data, preferences: preferences, history: history, notices: notices)
    }

    private func seeded() async -> FilesModel {
        let model = makeModel()
        model.seedSample(in: documents)
        await model.start()
        await model.scanned()
        return model
    }

    // MARK: Sample

    @Test func sampleHasOneDuplicateSetAndTheLargeExport() async throws {
        let model = await seeded()
        #expect(model.folderNames == [FilesModel.sampleFolderName])
        #expect(model.duplicateSetCount == 1)
        let group = try #require(model.duplicateGroups.first)
        #expect(group.keeper.name == "Trip notes.pdf")
        #expect(group.movable.map(\.name) == ["Trip notes copy.pdf"])
        #expect(model.duplicateExtraBytes > 0)
        #expect(model.duplicateExtraBytes == group.movable[0].unsharedBytes)
        #expect(model.largeFileCount == 1)
        let large = try #require(model.largeFiles.first)
        #expect(large.name == "Big export.mov")
        #expect(large.logicalBytes == 120_000_000)
        #expect(model.largeFileBytes >= 120_000_000)
        #expect(model.checkedCount == 4)
        #expect(model.keptByRule == 0)
        #expect(model.holdingCount == 0)
        #expect(!model.isScanning)

        // The two PDFs are written separately, so the copy takes real space of its own.
        let original = try Data(contentsOf: sample.appendingPathComponent("Trip notes.pdf"))
        #expect(original.count > 1_000)
        #expect(try Data(contentsOf: sample.appendingPathComponent("Trip notes copy.pdf")) == original)
    }

    @Test func seedingAgainResetsTheFolderWithoutAddingASecond() async throws {
        let model = await seeded()
        let group = try #require(model.duplicateGroups.first)
        #expect(await model.moveToHolding(group))
        #expect(model.holdingCount == 1)

        model.seedSample(in: documents)
        await model.scanned()
        #expect(model.folderCount == 1)
        #expect(model.holdingCount == 0)
        #expect(model.duplicateSetCount == 1)
        #expect(!FileManager.default.fileExists(atPath: HoldingFolder.url(in: sample).path))

        // A fresh launch on the same saved data sees the one folder too.
        let relaunched = makeModel()
        relaunched.seedSample(in: documents)
        #expect(relaunched.folderCount == 1)
    }

    // MARK: Holding

    @Test func moveToHoldingThenPutBackRoundTrips() async throws {
        let model = await seeded()
        let copyURL = sample.appendingPathComponent("Trip notes copy.pdf")
        let before = try Data(contentsOf: copyURL)
        let group = try #require(model.duplicateGroups.first)

        #expect(await model.moveToHolding(group))
        #expect(!FileManager.default.fileExists(atPath: copyURL.path))
        #expect(FileManager.default.fileExists(atPath: HoldingFolder.url(in: sample).appendingPathComponent("Trip notes copy.pdf").path))
        #expect(model.duplicateSetCount == 0)
        #expect(model.duplicateExtraBytes == 0)
        #expect(model.holdingCount == 1)
        #expect(model.holdingBytes == group.extraBytes)
        #expect(model.held.first?.name == "Trip notes copy.pdf")
        #expect(model.location(of: try #require(model.held.first)) == FilesModel.sampleFolderName)
        #expect(notices.text == "Moved 1 file to Holding.")
        #expect(notices.current?.undo != nil)

        let receipt = try #require(history.receipts.first)
        #expect(receipt.kind == .filesHeld)
        #expect(receipt.status == .done)
        #expect(receipt.title == "Trip notes copy.pdf")
        #expect(receipt.bytes == model.holdingBytes)
        #expect(Copy.Receipts.sentence(receipt) == "Moved \u{201C}Trip notes copy.pdf\u{201D} to Holding")

        await model.putBack(receipt)
        #expect(try Data(contentsOf: copyURL) == before)
        #expect(model.holdingCount == 0)
        #expect(model.holdingBytes == 0)
        #expect(history.receipt(receipt.id)?.status == .undone)
        let putBack = try #require(history.receipts.first { $0.kind == .filesPutBack })
        #expect(putBack.status == .done)
        #expect(putBack.completed == 1)
        #expect(notices.text == "Put back 1 file.")

        await model.scanned()
        #expect(model.duplicateSetCount == 1)
    }

    @Test func undoFromTheNoticePutsTheFileBack() async throws {
        let model = await seeded()
        #expect(await model.moveToHolding(try #require(model.duplicateGroups.first)))
        let undo = try #require(notices.current?.undo)
        await undo.action()
        #expect(model.holdingCount == 0)
        #expect(FileManager.default.fileExists(atPath: sample.appendingPathComponent("Trip notes copy.pdf").path))
    }

    @Test func keepingTheOtherCopyMovesTheOriginal() async throws {
        let model = await seeded()
        let group = try #require(model.duplicateGroups.first)
        let copy = try #require(group.movable.first)
        model.keep(copy.id, inSet: group.id)
        let changed = try #require(model.group(group.id))
        #expect(changed.keeper.name == "Trip notes copy.pdf")
        #expect(changed.movable.map(\.name) == ["Trip notes.pdf"])
        #expect(await model.moveToHolding(changed))
        #expect(!FileManager.default.fileExists(atPath: sample.appendingPathComponent("Trip notes.pdf").path))
        #expect(FileManager.default.fileExists(atPath: sample.appendingPathComponent("Trip notes copy.pdf").path))
    }

    @Test func largeFilesMoveAndPutAllBack() async throws {
        let model = await seeded()
        let export = try #require(model.largeFiles.first)
        #expect(await model.moveToHolding([export]))
        #expect(model.largeFileCount == 0)
        #expect(model.largeFileBytes == 0)
        #expect(model.holdingCount == 1)
        #expect(model.holdingBytes >= 120_000_000)

        #expect(await model.moveToHolding(try #require(model.duplicateGroups.first)))
        #expect(model.holdingCount == 2)

        await model.putAllBack()
        #expect(model.holdingCount == 0)
        #expect(notices.text == "Put back 2 files.")
        #expect(history.receipts.filter { $0.kind == .filesHeld }.allSatisfy { $0.status == .undone })
        await model.scanned()
        #expect(model.largeFileCount == 1)
        #expect(model.duplicateSetCount == 1)
    }

    @Test func emptyHoldingDeletesForGood() async throws {
        let model = await seeded()
        let group = try #require(model.duplicateGroups.first)
        #expect(await model.moveToHolding(group))
        let heldBytes = model.holdingBytes

        await model.emptyHolding()
        #expect(model.holdingCount == 0)
        #expect(model.holdingBytes == 0)
        let holdingFolder = HoldingFolder.url(in: sample)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: holdingFolder.path)) ?? []
        #expect(left.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sample.appendingPathComponent("Trip notes copy.pdf").path))
        #expect(FileManager.default.fileExists(atPath: sample.appendingPathComponent("Trip notes.pdf").path))

        let deleted = try #require(history.receipts.first)
        #expect(deleted.kind == .filesDeleted)
        #expect(deleted.status == .done)
        #expect(deleted.bytes == heldBytes)
        #expect(notices.text == "Deleted 1 file. \(Copy.bytes(heldBytes)) is free again.")

        model.rescan()
        await model.scanned()
        #expect(model.duplicateSetCount == 0)
        #expect(model.checkedCount == 3)
    }

    @Test func emptyHoldingDeletesOnlyWhatTheReviewShowed() async throws {
        let model = await seeded()
        #expect(await model.moveToHolding(try #require(model.duplicateGroups.first)))
        let review = HoldingView.deleteRequest(model.held, in: model)
        // Moved while the sheet was open, so not in the review.
        let large = try #require(model.largeFiles.first)
        #expect(await model.moveToHolding([large]))
        #expect(model.holdingCount == 2)

        await review.confirm()
        #expect(model.held.map(\.name) == ["Big export.mov"])
        #expect(!FileManager.default.fileExists(atPath: sample.appendingPathComponent("Trip notes copy.pdf").path))
    }

    @Test func undoDuringAnotherMoveWaitsForIt() async throws {
        let model = await seeded()
        #expect(await model.moveToHolding(try #require(model.duplicateGroups.first)))
        let receipt = try #require(history.receipts.first { $0.kind == .filesHeld })
        let large = try #require(model.largeFiles.first)
        let move = Task { await model.moveToHolding([large]) }
        for _ in 0..<1_000 where !model.isBusy { await Task.yield() }
        #expect(model.isBusy)

        await model.putBack(receipt)
        #expect(await move.value)
        #expect(model.held.map(\.name) == ["Big export.mov"])
        #expect(history.receipt(receipt.id)?.status == .undone)
        #expect(FileManager.default.fileExists(atPath: sample.appendingPathComponent("Trip notes copy.pdf").path))
    }

    @Test func holdingAndFoldersSurviveARelaunch() async throws {
        let model = await seeded()
        #expect(await model.moveToHolding(try #require(model.duplicateGroups.first)))

        let relaunched = makeModel()
        #expect(relaunched.folderNames == [FilesModel.sampleFolderName])
        await relaunched.start()
        await relaunched.scanned()
        #expect(relaunched.holdingCount == 1)
        #expect(relaunched.duplicateSetCount == 0)
        #expect(relaunched.largeFileCount == 1)
    }

    @Test func inMemoryModelKeepsNothing() async throws {
        let model = FilesModel(directory: nil, preferences: preferences, history: History(directory: nil), notices: notices)
        model.seedSample(in: documents)
        await model.start()
        await model.scanned()
        #expect(model.duplicateSetCount == 1)
        #expect(!FileManager.default.fileExists(atPath: data.appendingPathComponent("folders.json").path))
    }

    @Test func removingAFolderPutsItsFilesBackFirst() async throws {
        let model = await seeded()
        #expect(await model.moveToHolding(try #require(model.duplicateGroups.first)))
        let id = try #require(model.folders.first?.id)
        await model.removeFolder(id)
        #expect(model.folderCount == 0)
        #expect(model.holdingCount == 0)
        #expect(FileManager.default.fileExists(atPath: sample.appendingPathComponent("Trip notes copy.pdf").path))
        await model.scanned()
        #expect(model.duplicateSetCount == 0)
        #expect(model.largeFileCount == 0)
    }

    @Test func addingTheSameFolderTwiceKeepsOne() async throws {
        let folder = temporaryDirectory("files-add-\(UUID().uuidString)")
        try Data("hello".utf8).write(to: folder.appendingPathComponent("a.txt"))
        let model = makeModel()
        await model.start()
        model.addFolder(folder)
        model.addFolder(folder)
        #expect(model.folderCount == 1)
        await model.scanned()
        #expect(model.checkedCount == 1)
        #expect(model.lastError == nil)
    }

    @Test func interruptedMovesAreCountedFromWhatIsTrue() async throws {
        let model = await seeded()
        let copyPath = try #require(model.duplicateGroups.first?.movable.first?.id)
        let id = history.begin(.filesHeld, requested: 1, itemIDs: [copyPath])
        let receipt = try #require(history.receipt(id))
        #expect(await model.stillThere(receipt) == 1)
    }

    // MARK: The 7-day rule

    @Test func recentFilesAreKeptSafeUntilTheRuleIsOff() async throws {
        let folder = temporaryDirectory("files-recent-\(UUID().uuidString)")
        let content = Data((0..<40_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let old = Date().addingTimeInterval(-30 * 86_400)
        let recent = Date().addingTimeInterval(-2 * 86_400)
        func write(_ name: String, _ data: Data, _ date: Date) throws {
            let url = folder.appendingPathComponent(name)
            try data.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: url.path)
        }
        try write("report.pdf", content, old)
        try write("report copy.pdf", content, recent)
        try write("old big.bin", Data(repeating: 3, count: 2_000_000), old)
        try write("new big.bin", Data(repeating: 4, count: 2_100_000), recent)
        preferences.largeFileMinimum = 1_000_000

        let model = makeModel()
        await model.start()
        model.addFolder(folder)
        await model.scanned()
        #expect(model.recentDays == 7)
        #expect(model.duplicateSetCount == 0)
        #expect(model.largeFiles.map(\.name) == ["old big.bin"])
        #expect(model.keptByRule == 2)
        #expect(Copy.Files.recentRule(days: 7, kept: model.keptByRule)?.contains("2 files kept safe") == true)

        preferences.rules.hideFilesChangedWithinDays = nil
        model.rescan()
        await model.scanned()
        #expect(model.duplicateSetCount == 1)
        #expect(model.duplicateGroups.first?.movable.map(\.name) == ["report copy.pdf"])
        #expect(model.largeFileCount == 2)
        #expect(model.keptByRule == 0)
    }

    @Test func aRecentCopyStaysWhenTheSetIsMoved() async throws {
        let folder = temporaryDirectory("files-mixed-\(UUID().uuidString)")
        let content = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        let dates: [(String, Double)] = [("a.txt", 40), ("b.txt", 30), ("c.txt", 1)]
        for (name, days) in dates {
            let url = folder.appendingPathComponent(name)
            try content.write(to: url)
            let date = Date().addingTimeInterval(-days * 86_400)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: url.path)
        }
        let model = makeModel()
        await model.start()
        model.addFolder(folder)
        await model.scanned()
        let group = try #require(model.duplicateGroups.first)
        #expect(group.keeper.name == "a.txt")
        #expect(group.movable.map(\.name) == ["b.txt"])
        #expect(group.recent.map(\.name) == ["c.txt"])
        #expect(await model.moveToHolding(group))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("c.txt").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("b.txt").path))
        #expect(model.duplicateSetCount == 0)
    }

    // MARK: Folders that can't be opened

    /// Breaks the saved bookmark of the first folder, as if the system stopped honouring it.
    private func breakBookmark() throws -> UUID {
        let file = JSONFile<[FolderRef]>(url: data.appendingPathComponent("folders.json"))
        var refs = try #require(file.load())
        refs[0].bookmark = Data("not a bookmark".utf8)
        try file.save(refs)
        return refs[0].id
    }

    @Test func choosingAnUnopenableFolderAgainKeepsItsPlace() async throws {
        let first = await seeded()
        #expect(await first.moveToHolding(try #require(first.duplicateGroups.first)))
        let id = try breakBookmark()

        let model = makeModel()
        await model.start()
        await model.scanned()
        #expect(model.unavailableFolders.map(\.id) == [id])
        #expect(model.checkedFolderCount == 0)
        #expect(!model.canSayAllTidy)
        #expect(Copy.Files.duplicatesSummary(sets: 0, extras: 0, bytes: 0, sureNothing: model.canSayAllTidy) == Copy.Files.notChecked)
        #expect(model.holdingCount == 1)

        model.addFolder(sample)
        #expect(model.folderCount == 1)
        #expect(model.folders.first?.id == id)
        #expect(model.unavailableFolders.isEmpty)
        await model.scanned()
        #expect(model.canSayAllTidy)
        #expect(model.checkedFolderCount == 1)

        await model.putAllBack()
        #expect(model.holdingCount == 0)
        #expect(model.lastError == nil)
        #expect(FileManager.default.fileExists(atPath: sample.appendingPathComponent("Trip notes copy.pdf").path))
    }

    @Test func choosingARenamedFolderAgainTakesTheOldOnesPlace() async throws {
        let first = await seeded()
        #expect(await first.moveToHolding(try #require(first.duplicateGroups.first)))
        let id = try breakBookmark()
        let renamed = documents.appendingPathComponent("Trip files", isDirectory: true)
        try FileManager.default.moveItem(at: sample, to: renamed)

        let model = makeModel()
        await model.start()
        await model.scanned()
        #expect(model.unavailableFolders.map(\.id) == [id])

        model.addFolders([renamed], replacing: id)
        #expect(model.folderCount == 1)
        #expect(model.folders.first?.id == id)
        #expect(model.folders.first?.name == "Trip files")
        await model.putAllBack()
        #expect(model.holdingCount == 0)
        #expect(FileManager.default.fileExists(atPath: renamed.appendingPathComponent("Trip notes copy.pdf").path))
    }

    @Test func aDifferentFolderWithTheSameNameIsAddedAsNew() async throws {
        let first = await seeded()
        #expect(await first.moveToHolding(try #require(first.duplicateGroups.first)))
        _ = try breakBookmark()
        let other = temporaryDirectory("files-other-\(UUID().uuidString)")
            .appendingPathComponent(FilesModel.sampleFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        let model = makeModel()
        await model.start()
        await model.scanned()
        model.addFolder(other)
        // Its held file isn't in this folder, so this is another folder that shares the name.
        #expect(model.folderCount == 2)
        #expect(model.unavailableFolders.count == 1)
    }

    // MARK: Errors and rules

    @Test func aCheckThatWorksClearsTheLastError() async throws {
        let model = await seeded()
        let group = try #require(model.duplicateGroups.first)
        let copy = sample.appendingPathComponent("Trip notes copy.pdf")
        let handle = try FileHandle(forWritingTo: copy)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("changed".utf8))
        try handle.close()

        #expect(await !model.moveToHolding(group))
        #expect(model.lastError?.contains("changed since the check") == true)
        model.rescan()
        await model.scanned()
        #expect(model.lastError == nil)
        #expect(model.canSayAllTidy)
    }

    @Test func changingTheRulesUpdatesTheListsStraightAway() async throws {
        let model = await seeded()
        #expect(model.largeFileCount == 1)
        #expect(model.duplicateSetCount == 1)

        preferences.largeFileMinimum = 250_000_000
        #expect(await eventually { model.largeFileCount == 0 })
        #expect(model.largeFiles.isEmpty)
        preferences.largeFileMinimum = 100_000_000
        #expect(await eventually { model.largeFileCount == 1 })

        // The sample is about two months old, so a 90-day rule keeps all of it safe.
        preferences.rules.hideFilesChangedWithinDays = 90
        #expect(await eventually { model.duplicateSetCount == 0 && model.largeFileCount == 0 })
        #expect(model.keptByRule == 2)
        preferences.rules.hideFilesChangedWithinDays = 7
        #expect(await eventually { model.duplicateSetCount == 1 && model.largeFileCount == 1 })
        #expect(model.keptByRule == 0)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    // MARK: Putting back when the folder is gone

    @Test func aFileWhoseFolderIsGoneGoesWhereTheUserChooses() async throws {
        let folder = temporaryDirectory("files-gone-\(UUID().uuidString)")
        let trips = folder.appendingPathComponent("Trips", isDirectory: true)
        try FileManager.default.createDirectory(at: trips, withIntermediateDirectories: true)
        let map = trips.appendingPathComponent("map.bin")
        try Data(repeating: 9, count: 2_000_000).write(to: map)
        let old = Date().addingTimeInterval(-30 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: old, .creationDate: old], ofItemAtPath: map.path)
        preferences.largeFileMinimum = 1_000_000

        let model = makeModel()
        await model.start()
        model.addFolder(folder)
        await model.scanned()
        #expect(await model.moveToHolding([try #require(model.largeFiles.first)]))
        try FileManager.default.removeItem(at: trips)

        let item = try #require(model.held.first)
        await model.putBack(item)
        #expect(model.needsPlace == [item.id])
        #expect(model.holdingCount == 1)
        #expect(model.lastError?.hasSuffix(Copy.Files.chooseWhere + ".") == true)

        // The mover closed without moving it.
        let held = try #require(await model.beginPlacing(item))
        #expect(FileManager.default.fileExists(atPath: held.path))
        await model.endPlacing(item, movedTo: nil)
        #expect(model.holdingCount == 1)

        // The mover moved it.
        let again = try #require(await model.beginPlacing(item))
        let destination = folder.appendingPathComponent("map.bin")
        try FileManager.default.moveItem(at: again, to: destination)
        await model.endPlacing(item, movedTo: destination)
        #expect(model.holdingCount == 0)
        #expect(model.needsPlace.isEmpty)
        #expect(model.lastError == nil)
        let receipt = try #require(history.receipts.first)
        #expect(receipt.kind == .filesPutBack)
        #expect(receipt.status == .done)
        #expect(history.receipts.first { $0.kind == .filesHeld }?.status == .undone)
        #expect(notices.text == Copy.Files.placed("map.bin", in: folder.lastPathComponent))
    }

    @Test func emptyHoldingSaysWhatIsDeletedAndWarnsAboutICloud() {
        #expect(!Copy.Files.keptSafeDelete.contains("copies"))
        #expect(Copy.Files.undoDelete(iCloud: false) == Copy.Reason.cantBeUndone)
        #expect(Copy.Files.undoDelete(iCloud: true).contains("other devices"))
    }
}

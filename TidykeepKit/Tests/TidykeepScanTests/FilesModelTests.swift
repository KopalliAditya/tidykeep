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
}

import Foundation
import Testing
@testable import TidykeepFiles

@Suite("Duplicate files")
struct DuplicateFileFinderTests {
    @Test func findsIdenticalFilesWithDifferentNames() async throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        let content = bytes(5_000, seed: 7)
        try temp.write("Notes/plan.pdf", content)
        try temp.write("Old/plan (copy).pdf", content)
        try temp.write("other.pdf", bytes(5_000, seed: 8))

        let sets = try await DuplicateFileFinder.find(scan(temp.url).items).sets

        #expect(sets.count == 1)
        let set = try #require(sets.first)
        #expect(Set(set.items.map(\.relativePath)) == ["Notes/plan.pdf", "Old/plan (copy).pdf"])
        #expect(set.id.count == 64)
        #expect(set.extraBytes == set.extras.reduce(0) { $0 + $1.bytes })
        #expect(set.keeper?.id == set.keeperID)
    }

    @Test func findsLargeCopiesThroughTheFullHash() async throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        // Longer than one 1 MB read and longer than the 128 KB the quick pass reads whole.
        let content = bytes(2_500_000, seed: 3)
        try temp.write("a.mov", content)
        try temp.write("b.mov", content)
        try temp.write("c.mov", content)

        let sets = try await DuplicateFileFinder.find(scan(temp.url).items).sets

        #expect(sets.count == 1)
        #expect(sets.first?.items.count == 3)
        #expect(sets.first?.extras.count == 2)
    }

    @Test func rejectsSameLengthDifferentContent() async throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        try temp.write("small-a.bin", bytes(1_000, seed: 1))
        try temp.write("small-b.bin", bytes(1_000, seed: 2))
        try temp.write("big-a.bin", bytes(400_000, seed: 1))
        try temp.write("big-b.bin", bytes(400_000, seed: 2))

        let sets = try await DuplicateFileFinder.find(scan(temp.url).items).sets

        #expect(sets.isEmpty)
    }

    @Test func rejectsSameEndsDifferentMiddle() async throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        let content = bytes(300_000, seed: 5)
        var changed = content
        changed[150_000] ^= 0xFF
        try temp.write("a.bin", content)
        try temp.write("b.bin", changed)

        let sets = try await DuplicateFileFinder.find(scan(temp.url).items).sets

        #expect(sets.isEmpty)
    }

    @Test func emptyFilesNeverMatch() async throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        try temp.write("a.txt", Data())
        try temp.write("b.txt", Data())

        let sets = try await DuplicateFileFinder.find(scan(temp.url).items, minBytes: 0).sets

        #expect(sets.isEmpty)
    }

    @Test func ignoresFilesBelowMinimum() async throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        try temp.write("a.txt", "same")
        try temp.write("b.txt", "same")

        let items = try await scan(temp.url).items

        #expect(try await DuplicateFileFinder.find(items, minBytes: 5).sets.isEmpty)
        #expect(try await DuplicateFileFinder.find(items, minBytes: 4).sets.count == 1)
    }

    @Test func hardLinksAreOneFile() async throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        let original = try temp.write("a.bin", bytes(2_000, seed: 9))
        let link = temp.url.appendingPathComponent("b.bin")
        try FileManager.default.linkItem(at: original, to: link)
        let identity = try #require(FileFacts.status(of: original)?.identity)
        let now = Date()
        // Built by hand, as the scanner already folds hard links into one item.
        let items = [original, link].map { url in
            FileItem(url: url, bytes: 4_096, logicalBytes: 2_000, modified: now, folderID: UUID(),
                     relativePath: url.lastPathComponent, identity: identity)
        }

        #expect(try await DuplicateFileFinder.find(items).sets.isEmpty)

        try temp.write("c.bin", bytes(2_000, seed: 9))
        let copy = try #require(try await scan(temp.url).item("c.bin"))
        let sets = try await DuplicateFileFinder.find(items + [copy]).sets
        #expect(sets.count == 1)
        #expect(sets.first?.items.count == 2)
    }

    @Test func sortsSetsByExtraSpace() async throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        try temp.write("small-1.bin", bytes(10_000, seed: 1))
        try temp.write("small-2.bin", bytes(10_000, seed: 1))
        try temp.write("big-1.bin", bytes(200_000, seed: 2))
        try temp.write("big-2.bin", bytes(200_000, seed: 2))
        try temp.write("big-3.bin", bytes(200_000, seed: 2))

        let sets = try await DuplicateFileFinder.find(scan(temp.url).items).sets

        #expect(sets.map(\.items.count) == [3, 2])
        #expect(sets[0].extraBytes > sets[1].extraBytes)
    }

    @Test func leavesOutAFileThatChangedLengthSinceTheScan() async throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        let content = bytes(300_000, seed: 4)
        try temp.write("a.bin", content)
        try temp.write("b.bin", content)
        let items = try await scan(temp.url).items
        try temp.write("b.bin", content + Data([1]))

        #expect(try await DuplicateFileFinder.find(items).sets.isEmpty)
    }

    @Test func keeperIsTheOldestCopyOutsideDownloads() async throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        let content = bytes(4_000, seed: 6)
        try temp.write("Downloads/report.pdf", content)
        try temp.write("Work/report.pdf", content)
        try temp.write("Archive/report.pdf", content)
        let day: TimeInterval = 86_400
        let base = Date(timeIntervalSince1970: 1_600_000_000)
        try temp.setDates("Downloads/report.pdf", created: base, modified: base)
        try temp.setDates("Work/report.pdf", created: base + 2 * day, modified: base + 3 * day)
        try temp.setDates("Archive/report.pdf", created: base + day, modified: base + 3 * day)

        let set = try #require(try await DuplicateFileFinder.find(scan(temp.url).items).sets.first)

        #expect(set.items.map(\.relativePath) == ["Archive/report.pdf", "Work/report.pdf", "Downloads/report.pdf"])
        #expect(set.keeper?.relativePath == "Archive/report.pdf")

        let changed = set.keeping(set.items[2].id)
        #expect(changed.keeper?.relativePath == "Downloads/report.pdf")
        #expect(changed.extraBytes == set.items[0].bytes + set.items[1].bytes)
    }

    @Test func stopsWhenCancelled() async throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        // Longer than the quick pass reads whole and different at the ends, so only the check
        // between files can stop it: no full pass runs.
        try temp.write("a.bin", bytes(300_000, seed: 1))
        try temp.write("b.bin", bytes(300_000, seed: 2))
        let items = try await scan(temp.url).items

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DuplicateFileFinder.find(items).sets
        }

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func aCloneClaimsOnlyTheSpaceItDoesntShare() async throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        let content = bytes(3_000_000, seed: 13)
        let original = try temp.write("Docs/movie.mov", content)
        // What the Files app's Duplicate does on APFS: the copy shares the original's blocks.
        try FileManager.default.createDirectory(at: temp.url.appendingPathComponent("Copies"), withIntermediateDirectories: true)
        let clone = temp.url.appendingPathComponent("Copies/movie.mov")
        try #require(clonefile(FileFacts.path(of: original), FileFacts.path(of: clone), 0) == 0, "the temporary folder isn't on APFS")
        try temp.write("Plain/movie.mov", content)

        let inventory = try await scan(temp.url)
        let set = try #require(try await DuplicateFileFinder.find(inventory.items).sets.first)

        let cloned = try #require(inventory.item("Copies/movie.mov"))
        let plain = try #require(inventory.item("Plain/movie.mov"))
        #expect(cloned.bytes >= Int64(content.count))
        #expect(cloned.unsharedBytes < Int64(content.count))
        #expect(plain.unsharedBytes == plain.bytes)
        // Moving the clone out gives back next to nothing; moving the plain copy gives back all of it.
        #expect(set.items.count == 3)
        #expect(set.extraBytes == set.extras.reduce(0) { $0 + $1.unsharedBytes })
        #expect(set.extraBytes < cloned.bytes + plain.bytes)
    }

    @Test func countsFilesItCouldntCompare() async throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        let content = bytes(300_000, seed: 14)
        try temp.write("a.bin", content)
        let locked = try temp.write("b.bin", content)
        let vanished = try temp.write("c.bin", content)
        try temp.write("unique.bin", bytes(1_234, seed: 15))
        let items = try await scan(temp.url).items
        try setPermissions(locked, 0o000)
        defer { try? setPermissions(locked, 0o644) }
        try FileManager.default.removeItem(at: vanished)

        let report = try await DuplicateFileFinder.find(items)

        // A file of a length nothing else has is never read, so it's never skipped.
        #expect(report.sets.isEmpty)
        #expect(report.skipped == [.unreadable: 2])
        #expect(report.skippedCount == 2)
    }

    @Test func aFileThatChangedLengthCountsAsSkipped() async throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        let content = bytes(300_000, seed: 4)
        try temp.write("a.bin", content)
        try temp.write("b.bin", content)
        let items = try await scan(temp.url).items
        try temp.write("b.bin", content + Data([1]))

        #expect(try await DuplicateFileFinder.find(items).skipped == [.unreadable: 1])
    }
}

@Suite("Keeper rule")
struct KeeperRuleTests {
    let folder = UUID()
    let base = Date(timeIntervalSince1970: 1_700_000_000)

    func item(_ path: String, created: Date?, modified: Date) -> FileItem {
        FileItem(url: URL(fileURLWithPath: path), bytes: 100, modified: modified, created: created,
                 folderID: folder, relativePath: String(path.dropFirst()))
    }

    @Test func oldestCreatedWins() {
        let older = item("/f/b.txt", created: base, modified: base + 50)
        let newer = item("/f/a.txt", created: base + 10, modified: base + 10)
        #expect(DuplicateFileFinder.keepingOrder([newer, older]).first == older)
    }

    @Test func downloadsLosesEvenWhenOlder() {
        let download = item("/f/Downloads/a.txt", created: base, modified: base)
        let filed = item("/f/Docs/a.txt", created: base + 100, modified: base + 100)
        #expect(DuplicateFileFinder.keepingOrder([download, filed]).first == filed)
    }

    @Test func downloadsMatchesAnyLetterCaseAndTheChosenFolderItself() {
        #expect(DuplicateFileFinder.isInDownloads(item("/Users/x/downloads/a.txt", created: nil, modified: base)))
        #expect(DuplicateFileFinder.isInDownloads(item("/Users/x/Downloads/Sub/a.txt", created: nil, modified: base)))
        #expect(!DuplicateFileFinder.isInDownloads(item("/Users/x/Docs/Downloads.txt", created: nil, modified: base)))
    }

    @Test func allInDownloadsFallsBackToAge() {
        let older = item("/f/Downloads/b.txt", created: base, modified: base)
        let newer = item("/f/Downloads/a.txt", created: base + 1, modified: base + 1)
        #expect(DuplicateFileFinder.keepingOrder([newer, older]).first == older)
    }

    @Test func sameCreationThenOlderModificationWins() {
        let older = item("/f/b.txt", created: base, modified: base + 1)
        let newer = item("/f/a.txt", created: base, modified: base + 2)
        #expect(DuplicateFileFinder.keepingOrder([newer, older]).first == older)
    }

    @Test func missingCreationUsesModification() {
        let unknown = item("/f/b.txt", created: nil, modified: base)
        let known = item("/f/a.txt", created: base + 5, modified: base + 5)
        #expect(DuplicateFileFinder.keepingOrder([known, unknown]).first == unknown)
    }

    @Test func tiesGoToTheShortestPathThenTheID() {
        let deep = item("/f/Sub/a.txt", created: base, modified: base)
        let shallowB = item("/f/b.txt", created: base, modified: base)
        let shallowA = item("/f/a.txt", created: base, modified: base)
        #expect(DuplicateFileFinder.keepingOrder([deep, shallowB, shallowA]) == [shallowA, shallowB, deep])
    }
}

import Foundation
import Synchronization
import Testing
@testable import TidykeepFiles

@Suite("File scanner")
struct FileScannerTests {
    @Test func listsPlainFilesWithRelativePaths() async throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        try temp.write("a.txt", "alpha")
        try temp.write("Trips/2024/map.pdf", bytes(3_000, seed: 1))

        let inventory = try await scan(temp.url)

        #expect(inventory.relativePaths == ["Trips/2024/map.pdf", "a.txt"])
        let map = try #require(inventory.item("Trips/2024/map.pdf"))
        #expect(map.name == "map.pdf")
        #expect(map.logicalBytes == 3_000)
        #expect(map.bytes >= 3_000)
        #expect(map.parentPath == "Trips/2024")
        #expect(map.id == temp.url.appendingPathComponent("Trips/2024/map.pdf").path(percentEncoded: false))
        #expect(map.identity != nil)
        #expect(inventory.skippedCount == 0)
    }

    @Test func skipsHiddenHoldingSymlinksAndPackages() async throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        try temp.write("keep.txt", "keep")
        try temp.write(".hidden.txt", "hidden")
        try temp.write(".git/config", "hidden folder")
        try temp.write("\(HoldingFolder.name)/held.txt", "held")
        try temp.write("Sub/\(HoldingFolder.name)/held too.txt", "held in a nested chosen folder")
        try temp.write("Thing.app/Contents/Info.plist", "a package")
        let target = try temp.write("Sub/target.txt", "target")
        try FileManager.default.createSymbolicLink(
            at: temp.url.appendingPathComponent("link.txt"), withDestinationURL: target)
        try FileManager.default.createSymbolicLink(
            at: temp.url.appendingPathComponent("LinkedFolder"), withDestinationURL: target.deletingLastPathComponent())

        let inventory = try await scan(temp.url)

        #expect(inventory.relativePaths == ["Sub/target.txt", "keep.txt"])
        #expect(inventory.skippedCount == 0)
    }

    @Test func choosingTheHoldingFolderItselfFindsNothing() async throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        try temp.write("\(HoldingFolder.name)/held.txt", "held")
        try temp.write("\(HoldingFolder.name)/Sub/held too.txt", "held")
        let holding = temp.url.appendingPathComponent(HoldingFolder.name)

        let inventory = try await FileScanner.scan([
            (folderRef("Held"), holding),
            (folderRef("Sub"), holding.appendingPathComponent("Sub")),
        ])

        #expect(inventory.items.isEmpty)
    }

    @Test func skippedCountsSaveAsAPlainObject() throws {
        let inventory = FileInventory(skipped: [.iCloudOnly: 3])
        let json = String(decoding: try JSONEncoder().encode(inventory.skipped), as: UTF8.self)

        #expect(json == #"{"iCloudOnly":3}"#)
        #expect(try JSONDecoder().decode(FileInventory.self, from: JSONEncoder().encode(inventory)) == inventory)
    }

    @Test func countsOldStyleICloudPlaceholdersWithoutOpeningThem() async throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        try temp.write("here.txt", "here")
        try temp.write(".Report.pdf.icloud", "placeholder")

        let inventory = try await scan(temp.url)

        #expect(inventory.relativePaths == ["here.txt"])
        #expect(inventory.skipped == [.iCloudOnly: 1])
    }

    @Test func overlappingFoldersCountAFileOnce() async throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        try temp.write("top.txt", "top")
        try temp.write("Inner/inside.txt", "inside")
        let outer = folderRef("Outer")
        let inner = folderRef("Inner")

        let inventory = try await FileScanner.scan([(outer, temp.url), (inner, temp.url.appendingPathComponent("Inner"))])

        #expect(inventory.checkedCount == 2)
        let inside = try #require(inventory.items.first { $0.name == "inside.txt" })
        // The inner folder is the closer home, so a later move stays inside it.
        #expect(inside.folderID == inner.id)
        #expect(inside.relativePath == "inside.txt")
        #expect(inventory.items.first { $0.name == "top.txt" }?.folderID == outer.id)
    }

    @Test func sameFolderReachedThroughASymlinkedPathCountsOnce() async throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        try temp.write("Real/file.txt", "one file")
        let alias = temp.url.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: temp.url.appendingPathComponent("Real"))

        let inventory = try await FileScanner.scan([
            (folderRef("Real"), temp.url.appendingPathComponent("Real")),
            (folderRef("Alias"), alias),
        ])

        #expect(inventory.checkedCount == 1)
    }

    @Test func hardLinksCountOnce() async throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        let original = try temp.write("a.txt", "linked")
        try FileManager.default.linkItem(at: original, to: temp.url.appendingPathComponent("b.txt"))

        let inventory = try await scan(temp.url)

        #expect(inventory.checkedCount == 1)
    }

    @Test func reportsProgress() async throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        for index in 0..<300 { try temp.write("f\(index).txt", "file \(index)") }
        let reports = Reports()

        _ = try await FileScanner.scan([(folderRef("Root"), temp.url)]) { reports.add($0) }

        #expect(reports.all.last == FileScanProgress(checked: 300, skipped: 0))
        #expect(reports.all.count >= 2)
    }

    @Test func stopsWhenCancelled() async throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        for index in 0..<50 { try temp.write("f\(index).txt", "file \(index)") }
        let root = temp.url

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await FileScanner.scan([(folderRef("Root"), root)])
        }

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func stopsWhenCancelledPartway() async throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        for index in 0..<1_000 { try temp.write("f\(index).txt", "file \(index)") }
        let root = temp.url
        let reports = Reports()

        // Cancelled at the first report, which comes from inside the walk, after the check at
        // the top of the folder loop has already passed.
        let task = Task {
            try await FileScanner.scan([(folderRef("Root"), root)]) { report in
                reports.add(report)
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(reports.all.count == 1)
    }

    @Test func listsFoldersWithDownloadsBarred() async throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        for index in 0..<300 { try temp.write("f\(index).txt", "file \(index)") }
        let policies = Recorded<Int32>()

        _ = try await FileScanner.scan([(folderRef("Root"), temp.url)]) { _ in
            policies.add(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD))
        }

        // The report at 250 comes from inside the walk; the last one from after it.
        #expect(policies.all.first == IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        #expect(policies.all.last != IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
    }

    @Test func skipsFoldersThatLookLikePackagesEvenWhenNoAppKnowsThem() async throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        let clip = bytes(3_000, seed: 4)
        try temp.write("Videos/clip.mov", clip)
        try temp.write("Edit.zqxbundle/Event/Original Media/clip.mov", clip)
        try temp.write("Photos 2024.10/kept.jpg", "a dotted name ending in digits is a plain folder")
        // No app registers this type, so the system sees a plain folder.
        let bundle = temp.url.appendingPathComponent("Edit.zqxbundle", isDirectory: true)
        #expect(try bundle.resourceValues(forKeys: [.isPackageKey]).isPackage == false)

        let inventory = try await scan(temp.url)

        #expect(inventory.relativePaths == ["Photos 2024.10/kept.jpg", "Videos/clip.mov"])
        #expect(inventory.skippedCount == 0)
    }

    @Test func packageNamesAreADotAndAWord() {
        for name in ["Edit.fcpbundle", "Song.logicx", "App.xcodeproj", "Notes.rtfd", "Base.dtBase2"] {
            #expect(PackageFolder.matches(name), "\(name)")
        }
        for name in ["Trips", "Photos 2024.10", "Mr. Smith", "notes.", "v1.2"] {
            #expect(!PackageFolder.matches(name), "\(name)")
        }
    }

    @Test func aFolderThatWontOpenIsNamedNotCountedAsEmpty() async throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        try temp.write("Open/a.txt", "a")
        for index in 0..<40 { try temp.write("Locked/f\(index).txt", "file \(index)") }
        let locked = temp.url.appendingPathComponent("Locked")
        try setPermissions(locked, 0o000)
        defer { try? setPermissions(locked, 0o755) }
        let open = folderRef("Open")
        let lockedRef = folderRef("Locked")

        let inventory = try await FileScanner.scan([(lockedRef, locked), (open, temp.url.appendingPathComponent("Open"))])

        #expect(inventory.unavailableFolderIDs == [lockedRef.id])
        #expect(inventory.relativePaths == ["a.txt"])
        #expect(inventory.skippedCount == 0)
    }
}

/// Collects progress reports from the scanner's thread.
final class Reports: Sendable {
    private let reports = Mutex<[FileScanProgress]>([])

    func add(_ report: FileScanProgress) {
        reports.withLock { $0.append(report) }
    }

    var all: [FileScanProgress] { reports.withLock { $0 } }
}

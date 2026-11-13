import Foundation
import Testing
@testable import TidykeepFiles

@Suite("Holding")
struct HoldingStoreTests {
    /// A chosen folder and, beside it (not inside), the app's own storage for the manifest.
    struct Setup {
        let temp: TempFolder
        let root: URL
        let folder = folderRef("Root")
        let manifest: URL

        init() throws {
            temp = try TempFolder()
            root = try temp.folder("Root")
            manifest = temp.url.appendingPathComponent("App/holding.json")
        }

        func path(_ relative: String) -> String { "Root/\(relative)" }

        func scanned(_ relative: String) async throws -> FileItem {
            let inventory = try await scan(root, as: folder)
            return try #require(inventory.item(relative))
        }
    }

    @Test func holdThenPutBack() async throws {
        let s = try Setup()
        defer { s.temp.remove() }
        let content = bytes(10_000, seed: 2)
        try s.temp.write(s.path("Trips/map.pdf"), content)
        let store = HoldingStore(manifestURL: s.manifest)

        let held = try await store.hold(s.scanned("Trips/map.pdf"), folderRoot: s.root)

        #expect(held.name == "map.pdf")
        #expect(held.folderID == s.folder.id)
        #expect(held.originalRelativePath == "Trips/map.pdf")
        #expect(held.heldRelativePath == "\(HoldingFolder.name)/map.pdf")
        #expect(!s.temp.exists(s.path("Trips/map.pdf")))
        #expect(try s.temp.read(s.path("\(HoldingFolder.name)/map.pdf")) == content)
        #expect(try await store.items() == [held])

        let back = try await store.putBack(held.id, folderRoot: s.root)

        #expect(back.lastPathComponent == "map.pdf")
        #expect(try s.temp.read(s.path("Trips/map.pdf")) == content)
        #expect(!s.temp.exists(s.path("\(HoldingFolder.name)/map.pdf")))
        #expect(try await store.items().isEmpty)
    }

    @Test func heldFilesDontComeBackInAScan() async throws {
        let s = try Setup()
        defer { s.temp.remove() }
        try s.temp.write(s.path("a.txt"), "same")
        try s.temp.write(s.path("b.txt"), "same")
        let store = HoldingStore(manifestURL: s.manifest)

        _ = try await store.hold(s.scanned("b.txt"), folderRoot: s.root)
        let inventory = try await scan(s.root, as: s.folder)

        #expect(inventory.relativePaths == ["a.txt"])
        #expect(try await DuplicateFileFinder.find(inventory.items).sets.isEmpty)
    }

    @Test func nameClashWhenHolding() async throws {
        let s = try Setup()
        defer { s.temp.remove() }
        try s.temp.write(s.path("One/notes.txt"), "first")
        try s.temp.write(s.path("Two/notes.txt"), "second")
        try s.temp.write(s.path("Three/notes"), "no extension")
        try s.temp.write(s.path("Four/notes"), "no extension either")
        let store = HoldingStore(manifestURL: s.manifest)

        let first = try await store.hold(s.scanned("One/notes.txt"), folderRoot: s.root)
        let second = try await store.hold(s.scanned("Two/notes.txt"), folderRoot: s.root)
        _ = try await store.hold(s.scanned("Three/notes"), folderRoot: s.root)
        let fourth = try await store.hold(s.scanned("Four/notes"), folderRoot: s.root)

        #expect(first.heldRelativePath == "\(HoldingFolder.name)/notes.txt")
        #expect(second.heldRelativePath == "\(HoldingFolder.name)/notes 2.txt")
        #expect(second.name == "notes.txt")
        #expect(fourth.heldRelativePath == "\(HoldingFolder.name)/notes 2")
        #expect(String(decoding: try s.temp.read(s.path("\(HoldingFolder.name)/notes 2.txt")), as: UTF8.self) == "second")

        _ = try await store.putBack(second.id, folderRoot: s.root)
        #expect(String(decoding: try s.temp.read(s.path("Two/notes.txt")), as: UTF8.self) == "second")
    }

    @Test func nameClashWhenPuttingBack() async throws {
        let s = try Setup()
        defer { s.temp.remove() }
        try s.temp.write(s.path("Docs/plan.pdf"), "old plan")
        let store = HoldingStore(manifestURL: s.manifest)
        let held = try await store.hold(s.scanned("Docs/plan.pdf"), folderRoot: s.root)
        try s.temp.write(s.path("Docs/plan.pdf"), "new plan")

        let back = try await store.putBack(held.id, folderRoot: s.root)

        #expect(back.lastPathComponent == "plan 2.pdf")
        #expect(String(decoding: try s.temp.read(s.path("Docs/plan 2.pdf")), as: UTF8.self) == "old plan")
        #expect(String(decoding: try s.temp.read(s.path("Docs/plan.pdf")), as: UTF8.self) == "new plan")
    }

    @Test func missingOriginalFolderIsATypedErrorAndTheFileStaysHeld() async throws {
        let s = try Setup()
        defer { s.temp.remove() }
        try s.temp.write(s.path("Trips/2024/map.pdf"), "map")
        let store = HoldingStore(manifestURL: s.manifest)
        let held = try await store.hold(s.scanned("Trips/2024/map.pdf"), folderRoot: s.root)
        try FileManager.default.removeItem(at: s.root.appendingPathComponent("Trips"))

        await #expect(throws: FilesError.originalFolderMissing(name: "map.pdf", folder: "Trips/2024")) {
            try await store.putBack(held.id, folderRoot: s.root)
        }
        #expect(s.temp.exists(s.path("\(HoldingFolder.name)/map.pdf")))
        #expect(try await store.items() == [held])

        // The UI's file mover puts it somewhere else, then the row is forgotten.
        try await store.forget(held.id)
        #expect(try await store.items().isEmpty)
    }

    @Test func deleteRemovesTheFileForGood() async throws {
        let s = try Setup()
        defer { s.temp.remove() }
        try s.temp.write(s.path("big.mov"), bytes(50_000, seed: 1))
        let store = HoldingStore(manifestURL: s.manifest)
        let held = try await store.hold(s.scanned("big.mov"), folderRoot: s.root)

        try await store.delete(held.id, folderRoot: s.root)

        #expect(!s.temp.exists(s.path("\(HoldingFolder.name)/big.mov")))
        #expect(!s.temp.exists(s.path("big.mov")))
        #expect(try await store.items().isEmpty)
        await #expect(throws: FilesError.notHeld(id: held.id)) {
            try await store.delete(held.id, folderRoot: s.root)
        }
    }

    @Test func deletingAFileTheUserAlreadyDeletedJustLeavesTheList() async throws {
        let s = try Setup()
        defer { s.temp.remove() }
        try s.temp.write(s.path("old.zip"), bytes(1_000, seed: 3))
        let store = HoldingStore(manifestURL: s.manifest)
        let held = try await store.hold(s.scanned("old.zip"), folderRoot: s.root)
        try FileManager.default.removeItem(at: s.root.appendingPathComponent(held.heldRelativePath))

        try await store.delete(held.id, folderRoot: s.root)

        #expect(try await store.items().isEmpty)
    }

    @Test func manifestPersistsAcrossStores() async throws {
        let s = try Setup()
        defer { s.temp.remove() }
        try s.temp.write(s.path("a.txt"), "a")
        try s.temp.write(s.path("Sub/b.txt"), "b")
        let first = HoldingStore(manifestURL: s.manifest)
        let a = try await first.hold(s.scanned("a.txt"), folderRoot: s.root)
        let b = try await first.hold(s.scanned("Sub/b.txt"), folderRoot: s.root)

        let second = HoldingStore(manifestURL: s.manifest)

        #expect(try await second.items() == [a, b])
        #expect(try await second.items(in: s.folder.id) == [a, b])
        #expect(try await second.items(in: UUID()).isEmpty)
        _ = try await second.putBack(b.id, folderRoot: s.root)
        #expect(s.temp.exists(s.path("Sub/b.txt")))
        #expect(try await HoldingStore(manifestURL: s.manifest).items() == [a])
    }

    @Test func reconcileDropsRowsWhoseFileVanished() async throws {
        let s = try Setup()
        defer { s.temp.remove() }
        try s.temp.write(s.path("a.txt"), "a")
        try s.temp.write(s.path("b.txt"), "b")
        let store = HoldingStore(manifestURL: s.manifest)
        let a = try await store.hold(s.scanned("a.txt"), folderRoot: s.root)
        let b = try await store.hold(s.scanned("b.txt"), folderRoot: s.root)
        // The user empties part of the folder in the Files app.
        try FileManager.default.removeItem(at: s.root.appendingPathComponent(b.heldRelativePath))

        await #expect(throws: FilesError.heldFileMissing(name: "b.txt")) {
            try await store.putBack(b.id, folderRoot: s.root)
        }
        let otherFolder = try await store.reconcile(folderID: UUID(), folderRoot: s.root)
        let dropped = try await store.reconcile(folderID: s.folder.id, folderRoot: s.root)

        #expect(otherFolder.isEmpty)
        #expect(dropped == [b])
        #expect(try await store.items() == [a])
        #expect(try await HoldingStore(manifestURL: s.manifest).items() == [a])
    }

    @Test func reconcileDropsNothingWhenTheFolderCantBeOpened() async throws {
        let s = try Setup()
        defer { s.temp.remove() }
        try s.temp.write(s.path("a.txt"), "a")
        let store = HoldingStore(manifestURL: s.manifest)
        let a = try await store.hold(s.scanned("a.txt"), folderRoot: s.root)
        let gone = s.temp.url.appendingPathComponent("Unplugged")

        await #expect(throws: FilesError.folderUnavailable(name: "Unplugged")) {
            try await store.reconcile(folderID: s.folder.id, folderRoot: gone)
        }
        #expect(try await store.items() == [a])
    }

    @Test func refusesFilesOutsideTheFolder() async throws {
        let s = try Setup()
        defer { s.temp.remove() }
        try s.temp.write("Elsewhere/x.txt", "x")
        let outside = try #require(try await scan(s.temp.url.appendingPathComponent("Elsewhere")).item("x.txt"))
        let store = HoldingStore(manifestURL: s.manifest)

        await #expect(throws: FilesError.outsideFolder(name: "x.txt")) {
            try await store.hold(outside, folderRoot: s.root)
        }
        #expect(s.temp.exists("Elsewhere/x.txt"))
        #expect(try await store.items().isEmpty)
    }

    @Test func refusesToHoldAFileThatIsAlreadyHeld() async throws {
        let s = try Setup()
        defer { s.temp.remove() }
        try s.temp.write(s.path("a.txt"), "a")
        let store = HoldingStore(manifestURL: s.manifest)
        let held = try await store.hold(s.scanned("a.txt"), folderRoot: s.root)
        let heldURL = try await store.heldURL(of: held.id, folderRoot: s.root)
        let item = FileItem(url: heldURL, bytes: 1, logicalBytes: 1, modified: Date(), folderID: s.folder.id,
                            relativePath: "a.txt")

        // Whether the chosen folder is the outer one or "Held by Tidykeep" itself.
        for root in [s.root, heldURL.deletingLastPathComponent()] {
            await #expect(throws: FilesError.outsideFolder(name: "a.txt")) {
                try await store.hold(item, folderRoot: root)
            }
        }
        #expect(try await store.items() == [held])
    }

    @Test func refusesAFileThatChangedSinceTheCheck() async throws {
        let s = try Setup()
        defer { s.temp.remove() }
        try s.temp.write(s.path("draft.txt"), "first draft")
        let item = try await s.scanned("draft.txt")
        try s.temp.write(s.path("draft.txt"), "second draft, longer")
        let store = HoldingStore(manifestURL: s.manifest)

        await #expect(throws: FilesError.fileChanged(name: "draft.txt")) {
            try await store.hold(item, folderRoot: s.root)
        }
        #expect(s.temp.exists(s.path("draft.txt")))
        #expect(!s.temp.exists(s.path(HoldingFolder.name)))
        #expect(try await store.items().isEmpty)
    }

    @Test func refusesAFileThatVanishedSinceTheCheck() async throws {
        let s = try Setup()
        defer { s.temp.remove() }
        try s.temp.write(s.path("gone.txt"), "soon gone")
        let item = try await s.scanned("gone.txt")
        try FileManager.default.removeItem(at: item.url)
        let store = HoldingStore(manifestURL: s.manifest)

        await #expect(throws: FilesError.fileChanged(name: "gone.txt")) {
            try await store.hold(item, folderRoot: s.root)
        }
    }

    @Test func aFileWhoseFolderVanishedIsChangedNotOutside() async throws {
        let s = try Setup()
        defer { s.temp.remove() }
        try s.temp.write(s.path("Gone/x.txt"), "x")
        // Reached the way the system hands out temporary paths (/var rather than /private/var),
        // so only the real, canonical path shows it was inside the folder.
        let rootPath = s.root.path(percentEncoded: false)
        let plainRoot = URL(fileURLWithPath: rootPath.hasPrefix("/private/") ? String(rootPath.dropFirst(8)) : rootPath)
        let item = FileItem(url: plainRoot.appendingPathComponent("Gone/x.txt"), bytes: 1, modified: Date(),
                            folderID: s.folder.id, relativePath: "Gone/x.txt")
        try FileManager.default.removeItem(at: s.root.appendingPathComponent("Gone"))
        let store = HoldingStore(manifestURL: s.manifest)

        await #expect(throws: FilesError.fileChanged(name: "x.txt")) {
            try await store.hold(item, folderRoot: plainRoot)
        }
        #expect(try await store.items().isEmpty)
    }

    @Test func unreadableManifestIsNeverOverwritten() async throws {
        let s = try Setup()
        defer { s.temp.remove() }
        try s.temp.write("App/holding.json", "not json")
        try s.temp.write(s.path("a.txt"), "a")
        let store = HoldingStore(manifestURL: s.manifest)
        let item = try await s.scanned("a.txt")

        await #expect(throws: FilesError.unreadable(path: s.manifest.path(percentEncoded: false))) {
            try await store.hold(item, folderRoot: s.root)
        }
        #expect(s.temp.exists(s.path("a.txt")))
        #expect(String(decoding: try s.temp.read("App/holding.json"), as: UTF8.self) == "not json")
    }

    @Test func reachesTheFolderThroughItsBookmark() async throws {
        let s = try Setup()
        defer { s.temp.remove() }
        try s.temp.write(s.path("a.txt"), "a")

        let ref = try FolderAccess.makeRef(for: s.root)
        let resolved = try FolderAccess.resolve(ref)
        let refreshed = try FolderAccess.refreshed(ref, url: resolved.url)

        #expect(ref.displayName == "Root")
        #expect(!resolved.isStale)
        #expect(FileFacts.canonical(resolved.url) == FileFacts.canonical(s.root))
        #expect(refreshed.id == ref.id)
        let count = try FolderAccess.withAccess(to: resolved.url) {
            try FileManager.default.contentsOfDirectory(atPath: resolved.url.path(percentEncoded: false)).count
        }
        #expect(count == 1)
        let inventory = try await FolderAccess.withAccess(to: [resolved.url]) {
            try await FileScanner.scan([(ref, resolved.url)])
        }
        #expect(inventory.item("a.txt")?.folderID == ref.id)
    }

    @Test func aBookmarkThatCantResolveIsAFolderUnavailableError() {
        let broken = FolderRef(displayName: "Downloads", bookmark: Data([1, 2, 3]))
        #expect(throws: FilesError.folderUnavailable(name: "Downloads")) {
            try FolderAccess.resolve(broken)
        }
    }
}

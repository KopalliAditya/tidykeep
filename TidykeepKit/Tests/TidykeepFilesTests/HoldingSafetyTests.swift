import Foundation
import Testing
@testable import TidykeepFiles

/// The rules that keep Holding from losing track of a file, or deleting the wrong one.
@Suite("Holding safety")
struct HoldingSafetyTests {
    typealias Setup = HoldingStoreTests.Setup

    @Test func reconcileKeepsRowsWhoseFileCantBeChecked() async throws {
        let s = try Setup()
        defer { s.temp.remove() }
        try s.temp.write(s.path("a.txt"), "a")
        let store = HoldingStore(manifestURL: s.manifest)
        let held = try await store.hold(s.scanned("a.txt"), folderRoot: s.root)
        let holding = HoldingFolder.url(in: s.root)

        // Locked (nothing can be looked up) and listable but not searchable: the chosen folder
        // still opens, yet whether the held file is there can't be told. A flaky share or an
        // offline iCloud folder looks like this.
        for mode in [0o000, 0o444] {
            try setPermissions(holding, mode)
            defer { try? setPermissions(holding, 0o755) }

            #expect(try await store.reconcile(folderID: s.folder.id, folderRoot: s.root).isEmpty)
            #expect(try await store.items() == [held])
        }
        #expect(try await HoldingStore(manifestURL: s.manifest).items() == [held])
        #expect(s.temp.exists(s.path(held.heldRelativePath)))
    }

    @Test func reconcileDropsEveryRowWhenTheWholeFolderWasDeleted() async throws {
        let s = try Setup()
        defer { s.temp.remove() }
        try s.temp.write(s.path("a.txt"), "a")
        try s.temp.write(s.path("b.txt"), "b")
        let store = HoldingStore(manifestURL: s.manifest)
        let a = try await store.hold(s.scanned("a.txt"), folderRoot: s.root)
        let b = try await store.hold(s.scanned("b.txt"), folderRoot: s.root)
        try FileManager.default.removeItem(at: HoldingFolder.url(in: s.root))

        #expect(try await store.reconcile(folderID: s.folder.id, folderRoot: s.root) == [a, b])
        #expect(try await store.items().isEmpty)
    }

    @Test func deleteLeavesAFileItCantCheck() async throws {
        let s = try Setup()
        defer { s.temp.remove() }
        try s.temp.write(s.path("a.txt"), "a")
        let store = HoldingStore(manifestURL: s.manifest)
        let held = try await store.hold(s.scanned("a.txt"), folderRoot: s.root)
        let holding = HoldingFolder.url(in: s.root)
        try setPermissions(holding, 0o444)

        await #expect(throws: FilesError.couldNotDelete(name: "a.txt")) {
            try await store.delete(held.id, folderRoot: s.root)
        }

        try setPermissions(holding, 0o755)
        #expect(try await store.items() == [held])
        #expect(s.temp.exists(s.path(held.heldRelativePath)))
    }

    @Test func aFileDroppedInUnderAHeldNameIsLeftAlone() async throws {
        let s = try Setup()
        defer { s.temp.remove() }
        try s.temp.write(s.path("Trips/IMG_0001.mov"), bytes(4_000, seed: 1))
        let store = HoldingStore(manifestURL: s.manifest)
        let held = try await store.hold(s.scanned("Trips/IMG_0001.mov"), folderRoot: s.root)
        // In the Files app the held file is dragged out, and another video from another import,
        // with the same camera name, is dropped into "Held by Tidykeep".
        try FileManager.default.moveItem(
            at: s.root.appendingPathComponent(held.heldRelativePath),
            to: s.root.appendingPathComponent("Dragged out.mov"))
        let other = bytes(6_000, seed: 2)
        try s.temp.write(s.path(held.heldRelativePath), other)

        await #expect(throws: FilesError.heldFileMissing(name: "IMG_0001.mov")) {
            try await store.delete(held.id, folderRoot: s.root)
        }
        await #expect(throws: FilesError.heldFileMissing(name: "IMG_0001.mov")) {
            try await store.putBack(held.id, folderRoot: s.root)
        }
        #expect(!s.temp.exists(s.path("Trips/IMG_0001.mov")))
        #expect(try await store.reconcile(folderID: s.folder.id, folderRoot: s.root) == [held])
        #expect(try s.temp.read(s.path(held.heldRelativePath)) == other)
        #expect(try await store.items().isEmpty)
    }

    @Test func aFolderAtTheHeldPathIsNeverDeleted() async throws {
        let s = try Setup()
        defer { s.temp.remove() }
        try s.temp.write(s.path("notes"), "a file with no extension")
        let store = HoldingStore(manifestURL: s.manifest)
        let held = try await store.hold(s.scanned("notes"), folderRoot: s.root)
        try FileManager.default.removeItem(at: s.root.appendingPathComponent(held.heldRelativePath))
        try s.temp.write(s.path("\(held.heldRelativePath)/inside.txt"), "the user's folder")

        await #expect(throws: FilesError.heldFileMissing(name: "notes")) {
            try await store.delete(held.id, folderRoot: s.root)
        }
        #expect(s.temp.exists(s.path("\(held.heldRelativePath)/inside.txt")))
    }

    @Test func anUnsavableListMovesNothing() async throws {
        let s = try Setup()
        defer { s.temp.remove() }
        try s.temp.write(s.path("a.txt"), "a")
        let item = try await s.scanned("a.txt")
        let app = try s.temp.folder("App")
        try setPermissions(app, 0o555)
        defer { try? setPermissions(app, 0o755) }
        let store = HoldingStore(manifestURL: s.manifest)

        await #expect(throws: FilesError.couldNotSaveManifest(path: FileFacts.path(of: s.manifest))) {
            try await store.hold(item, folderRoot: s.root)
        }
        // The list is saved before the move, so a list that can't be saved means no move.
        #expect(s.temp.exists(s.path("a.txt")))
        #expect(!s.temp.exists(s.path("\(HoldingFolder.name)/a.txt")))
        #expect(try await store.items().isEmpty)
    }

    @Test func refusesAPartOfAPackage() async throws {
        let s = try Setup()
        defer { s.temp.remove() }
        let clip = try s.temp.write(s.path("Edit.zqxbundle/Media/clip.mov"), bytes(2_000, seed: 5))
        let status = try #require(FileFacts.status(of: clip))
        let length = try #require(FileFacts.lengthAndDate(of: clip))
        // The scanner never lists it; a saved or hand-made item could still point at it.
        let item = FileItem(url: clip, bytes: 4_096, logicalBytes: length.length, modified: length.modified,
                            folderID: s.folder.id, relativePath: "Edit.zqxbundle/Media/clip.mov",
                            identity: status.identity)
        let store = HoldingStore(manifestURL: s.manifest)

        await #expect(throws: FilesError.outsideFolder(name: "clip.mov")) {
            try await store.hold(item, folderRoot: s.root)
        }
        #expect(s.temp.exists(s.path("Edit.zqxbundle/Media/clip.mov")))
    }

    @Test func holdingRecordsTheSpaceItWillGiveBackNow() async throws {
        let s = try Setup()
        defer { s.temp.remove() }
        let content = bytes(3_000_000, seed: 6)
        let original = try s.temp.write(s.path("movie.mov"), content)
        let item = try await s.scanned("movie.mov")
        #expect(item.unsharedBytes == item.bytes)
        // Duplicated in the Files app after the check: the two now share their blocks.
        let clone = s.root.appendingPathComponent("movie copy.mov")
        try #require(clonefile(FileFacts.path(of: original), FileFacts.path(of: clone), 0) == 0, "the temporary folder isn't on APFS")
        let store = HoldingStore(manifestURL: s.manifest)

        let held = try await store.hold(item, folderRoot: s.root)

        #expect(held.bytes < Int64(content.count))
        #expect(held.heldLength == Int64(content.count))
        #expect(held.heldIdentity?.inode == item.identity?.inode)
    }
}

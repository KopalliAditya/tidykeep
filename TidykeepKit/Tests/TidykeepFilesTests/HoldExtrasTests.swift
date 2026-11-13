import Foundation
import Testing
@testable import TidykeepFiles

/// Holding a duplicate set's extras is only safe while the copy being kept is still there.
@Suite("Holding a set's extras")
struct HoldExtrasTests {
    typealias Setup = HoldingStoreTests.Setup

    /// Archive/v.mov (the keeper: not in Downloads) and Downloads/v.mov.
    func twoCopies(_ s: Setup) async throws -> DuplicateFileSet {
        let content = bytes(200_000, seed: 21)
        try s.temp.write(s.path("Archive/v.mov"), content)
        try s.temp.write(s.path("Downloads/v.mov"), content)
        let set = try #require(try await DuplicateFileFinder.find(scan(s.root, as: s.folder).items).sets.first)
        #expect(set.keeper?.relativePath == "Archive/v.mov")
        return set
    }

    @Test func holdsTheExtrasAndLeavesTheKeeper() async throws {
        let s = try Setup()
        defer { s.temp.remove() }
        let set = try await twoCopies(s)
        let store = HoldingStore(manifestURL: s.manifest)

        let results = try await store.holdExtras(of: set, folderRoots: [s.folder.id: s.root])

        #expect(results.count == 1)
        let held = try #require(try results.first?.get())
        #expect(held.originalRelativePath == "Downloads/v.mov")
        #expect(try await store.items() == [held])
        #expect(s.temp.exists(s.path("Archive/v.mov")))
        #expect(!s.temp.exists(s.path("Downloads/v.mov")))
    }

    @Test func refusesWhenTheKeeperWasHeldFromLargeFiles() async throws {
        let s = try Setup()
        defer { s.temp.remove() }
        let set = try await twoCopies(s)
        let store = HoldingStore(manifestURL: s.manifest)
        // Both copies are big, so both show in Large Files too, and the keeper goes from there.
        let keeperRow = try await store.hold(try #require(set.keeper), folderRoot: s.root)

        await #expect(throws: FilesError.fileChanged(name: "v.mov")) {
            try await store.holdExtras(of: set, folderRoots: [s.folder.id: s.root])
        }
        #expect(s.temp.exists(s.path("Downloads/v.mov")))
        #expect(try await store.items() == [keeperRow])
    }

    @Test func refusesWhenTheKeeperChangedOrVanished() async throws {
        let s = try Setup()
        defer { s.temp.remove() }
        let set = try await twoCopies(s)
        let store = HoldingStore(manifestURL: s.manifest)
        let roots = [s.folder.id: s.root]

        // Edited on another device: the keeper is no longer the content the user saw.
        try s.temp.write(s.path("Archive/v.mov"), bytes(200_001, seed: 22))
        await #expect(throws: FilesError.fileChanged(name: "v.mov")) {
            try await store.holdExtras(of: set, folderRoots: roots)
        }
        try FileManager.default.removeItem(at: s.root.appendingPathComponent("Archive/v.mov"))
        await #expect(throws: FilesError.fileChanged(name: "v.mov")) {
            try await store.holdExtras(of: set, folderRoots: roots)
        }
        #expect(s.temp.exists(s.path("Downloads/v.mov")))
        #expect(try await store.items().isEmpty)
    }

    @Test func refusesWhenTheKeepersFolderIsntGiven() async throws {
        let s = try Setup()
        defer { s.temp.remove() }
        let set = try await twoCopies(s)
        let store = HoldingStore(manifestURL: s.manifest)

        await #expect(throws: FilesError.outsideFolder(name: "v.mov")) {
            try await store.holdExtras(of: set, folderRoots: [:])
        }
        #expect(s.temp.exists(s.path("Downloads/v.mov")))
    }

    @Test func eachCopyGoesToItsOwnFoldersHolding() async throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        let content = bytes(5_000, seed: 23)
        try temp.write("Docs/plan.pdf", content)
        try temp.write("Downloads/plan.pdf", content)
        let docs = folderRef("Docs")
        let downloads = folderRef("Downloads")
        let docsRoot = temp.url.appendingPathComponent("Docs")
        let downloadsRoot = temp.url.appendingPathComponent("Downloads")
        let inventory = try await FileScanner.scan([(docs, docsRoot), (downloads, downloadsRoot)])
        let set = try #require(try await DuplicateFileFinder.find(inventory.items).sets.first)
        let store = HoldingStore(manifestURL: temp.url.appendingPathComponent("App/holding.json"))

        let results = try await store.holdExtras(of: set, folderRoots: [docs.id: docsRoot, downloads.id: downloadsRoot])

        let held = try #require(try results.first?.get())
        #expect(held.folderID == downloads.id)
        #expect(temp.exists("Downloads/\(HoldingFolder.name)/plan.pdf"))
        #expect(temp.exists("Docs/plan.pdf"))
    }
}

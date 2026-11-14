import Foundation
import Testing
import TidykeepContacts

@Suite struct ContactBackupStoreTests {
    @Test func savesLoadsAndDeletes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TidykeepContactsTests-\(UUID().uuidString)/Backups", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = ContactBackupStore(directory: directory)
        let id = UUID()
        let data = Data("BEGIN:VCARD\r\nEND:VCARD\r\n".utf8)

        let url = try store.save(data, id: id)
        #expect(url.pathExtension == "vcf")
        #expect(url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
        #expect(try store.load(id: id) == data)

        try store.delete(id: id)
        #expect(throws: (any Error).self) { try store.load(id: id) }
        // Deleting twice is fine.
        try store.delete(id: id)
    }

    @Test func thePlanIsSavedNextToTheBackupAndDeletedWithIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TidykeepContactsTests-\(UUID().uuidString)/Backups", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = ContactBackupStore(directory: directory)
        let plan = try MergePlanner.plan(
            cards: [card("k", given: "Ana", phones: ["415 555 0123"]), card("o", given: "Ana", emails: ["ana@example.com"])],
            keeperID: "k", choices: MergeChoices(nameFrom: "k"))
        let id = UUID()
        try store.save(Data("BEGIN:VCARD\r\nEND:VCARD\r\n".utf8), id: id)
        try store.savePlan(plan, id: id)
        #expect(store.planURL(id).deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
        #expect(try store.loadPlan(id: id) == plan)

        // A plan left without its backup is found too, but only backups are counted.
        let alone = UUID()
        try store.savePlan(plan, id: alone)
        try Data("other".utf8).write(to: directory.appending(path: "notes.txt"))
        #expect(store.savedIDs() == [id, alone])
        #expect(store.count() == 1)

        try store.delete(id: id)
        try store.delete(id: alone)
        #expect(throws: (any Error).self) { try store.loadPlan(id: id) }
        #expect(store.savedIDs().isEmpty)
        #expect(store.count() == 0)
    }
}

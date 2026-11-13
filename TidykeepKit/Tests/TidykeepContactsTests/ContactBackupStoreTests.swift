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
}

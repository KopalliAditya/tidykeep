import Foundation

/// vCard backups on disk, one file per merge, so a merge can be undone after a relaunch and
/// the backup exported from History. The app keeps them in Application Support; they never
/// leave the device unless the user exports one.
public struct ContactBackupStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Writes the backup and returns where it is. The folder is created when missing, and the
    /// file is written whole or not at all.
    @discardableResult
    public func save(_ data: Data, id: UUID) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(id)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    /// The backup saved under this ID. Throws when it is gone, so Undo can say it can't be done.
    public func load(id: UUID) throws -> Data {
        try Data(contentsOf: fileURL(id))
    }

    /// Removes the backup. One that is already gone is fine.
    public func delete(id: UUID) throws {
        do {
            try FileManager.default.removeItem(at: fileURL(id))
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }

    /// Where the backup with this ID lives, for `fileExporter`.
    public func fileURL(_ id: UUID) -> URL {
        directory.appending(path: id.uuidString + ".vcf", directoryHint: .notDirectory)
    }
}

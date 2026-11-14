import Foundation

/// vCard backups on disk, one per merge, so a merge can be undone after a relaunch. The app
/// keeps them in Application Support, left out of device backups; they never leave the device.
///
/// Next to each backup is the merge's plan, which undo needs too. The plan holds the cards'
/// details, so it is kept here, protected like the backup, rather than in History, and
/// `delete` removes both.
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

    /// Writes the merge's plan next to its backup, the same way as the backup.
    public func savePlan(_ plan: MergePlan, id: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(plan).write(to: planURL(id), options: [.atomic, .completeFileProtection])
    }

    /// The plan saved with the backup under this ID. Throws when it is gone or can't be read,
    /// so Undo can say it can't be done.
    public func loadPlan(id: UUID) throws -> MergePlan {
        try JSONDecoder().decode(MergePlan.self, from: Data(contentsOf: planURL(id)))
    }

    /// Removes the backup and its plan. One that is already gone is fine.
    public func delete(id: UUID) throws {
        for url in [fileURL(id), planURL(id)] {
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                continue
            }
        }
    }

    /// Where the backup with this ID lives.
    public func fileURL(_ id: UUID) -> URL {
        directory.appending(path: id.uuidString + Self.backupSuffix, directoryHint: .notDirectory)
    }

    /// Where the plan saved with the backup with this ID lives.
    public func planURL(_ id: UUID) -> URL {
        directory.appending(path: id.uuidString + Self.planSuffix, directoryHint: .notDirectory)
    }

    /// The IDs with a backup or a plan in the folder, from the file names, so a plan left
    /// without its backup is found too. Other files are left out.
    public func savedIDs() -> Set<UUID> {
        Set(fileNames().compactMap { name in
            guard let suffix = [Self.backupSuffix, Self.planSuffix].first(where: name.hasSuffix) else { return nil }
            return UUID(uuidString: String(name.dropLast(suffix.count)))
        })
    }

    /// How many backups there are, one per merge. Plans aren't counted.
    public func count() -> Int {
        fileNames().count { name in
            name.hasSuffix(Self.backupSuffix) && UUID(uuidString: String(name.dropLast(Self.backupSuffix.count))) != nil
        }
    }

    private func fileNames() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
    }

    private static let backupSuffix = ".vcf"
    private static let planSuffix = ".plan.json"
}

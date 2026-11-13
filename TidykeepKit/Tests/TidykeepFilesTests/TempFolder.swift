import Foundation
import Synchronization
@testable import TidykeepFiles

/// A throwaway folder under the system temporary directory. Tests only ever touch files in here.
struct TempFolder {
    /// Canonical (/private/var rather than /var), so paths compare equal to the scanner's.
    let url: URL

    init() throws {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("TidykeepFilesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        url = FileFacts.canonical(raw)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes `data` at `relativePath`, making folders on the way.
    @discardableResult
    func write(_ relativePath: String, _ data: Data) throws -> URL {
        let file = url.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return file
    }

    @discardableResult
    func write(_ relativePath: String, _ text: String) throws -> URL {
        try write(relativePath, Data(text.utf8))
    }

    func folder(_ relativePath: String) throws -> URL {
        let folder = url.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(relativePath).path(percentEncoded: false))
    }

    func read(_ relativePath: String) throws -> Data {
        try Data(contentsOf: url.appendingPathComponent(relativePath, isDirectory: false))
    }

    /// Sets the dates the keeper rule and the recent-change rule look at. Modification first:
    /// some file systems pull the creation date back to an earlier modification date.
    func setDates(_ relativePath: String, created: Date? = nil, modified: Date? = nil) throws {
        let path = url.appendingPathComponent(relativePath).path(percentEncoded: false)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path) }
        if let created { try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: path) }
    }
}

/// Deterministic bytes: the same seed always gives the same content.
func bytes(_ count: Int, seed: UInt8) -> Data {
    var data = Data(count: count)
    var state = UInt32(seed) &* 2_654_435_761 &+ 1
    for index in 0..<count {
        state = state &* 1_664_525 &+ 1_013_904_223
        data[index] = UInt8(truncatingIfNeeded: state >> 24)
    }
    return data
}

func folderRef(_ name: String) -> FolderRef {
    FolderRef(displayName: name, bookmark: Data())
}

/// Scans one folder and returns what it found.
func scan(_ root: URL, as folder: FolderRef = folderRef("Root")) async throws -> FileInventory {
    try await FileScanner.scan([(folder, root)])
}

extension FileInventory {
    func item(_ relativePath: String) -> FileItem? {
        items.first { $0.relativePath == relativePath }
    }

    var relativePaths: [String] { items.map(\.relativePath).sorted() }
}

/// Sets a file's or folder's POSIX permissions, to make the system refuse access the way a
/// locked-down share or drive does.
func setPermissions(_ url: URL, _ mode: Int) throws {
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path(percentEncoded: false))
}

/// Collects values reported from another thread, such as progress reports.
final class Recorded<Value: Sendable>: Sendable {
    private let values = Mutex<[Value]>([])

    func add(_ value: Value) {
        values.withLock { $0.append(value) }
    }

    var all: [Value] { values.withLock { $0 } }
}

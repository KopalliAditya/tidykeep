import Foundation

/// Finds exact duplicate files: same content, byte for byte, whatever their names.
///
/// Reading is the cost, so each stage only reads what the one before couldn't rule out:
/// 1. Group by length. Files of a unique length can't have a copy, and cost nothing.
/// 2. Hash the first and last 64 KB of each file in a group (all of it, up to 128 KB).
/// 3. Hash the whole file, in 1 MB pieces, for files whose ends matched.
///
/// Only files with the same full SHA-256 form a set. Files that can't be read, aren't fully on
/// the device, or changed length since the scan are left out of every set, and counted in
/// `DuplicateFileReport.skipped` so the Coverage sheet can say so.
///
/// The files are read by path, so the chosen folders' scopes must be open for the whole call
/// (`FolderAccess.withAccess(to:_:)`). If they aren't, every read fails and shows up as
/// "couldn't be read" rather than as "no duplicates".
public enum DuplicateFileFinder: Sendable {
    /// Sets of two or more copies, the most extra space first, and the files that couldn't be
    /// compared. Files shorter than `minBytes` are ignored, and empty files never match: two
    /// empty files aren't copies of anything. Files of a length no other file has are never
    /// read, so they are never skipped either.
    @concurrent
    public static func find(_ items: [FileItem], minBytes: Int64 = 1) async throws -> DuplicateFileReport {
        let floor = max(minBytes, 1)
        let files = oneEntryPerFile(items.filter { $0.logicalBytes >= floor })
        let byLength = Dictionary(grouping: files, by: \.logicalBytes)
        var sets: [DuplicateFileSet] = []
        var skipped: [FileSkipReason: Int] = [:]
        for length in byLength.keys.sorted(by: >) {
            guard let sameLength = byLength[length], sameLength.count > 1 else { continue }
            var byEdges: [String: [FileItem]] = [:]
            for item in sameLength {
                try Task.checkCancellation()
                switch try ContentHasher.edgeDigest(of: item.url, length: length) {
                case .digest(let digest): byEdges[digest, default: []].append(item)
                case .skipped(let reason): skipped[reason, default: 0] += 1
                }
            }
            for (edgeDigest, candidates) in byEdges where candidates.count > 1 {
                // Up to 128 KB the edge pass read everything, so its digest is the full one.
                if length <= ContentHasher.wholeFileLimit {
                    sets.append(makeSet(id: edgeDigest, candidates))
                    continue
                }
                var byContent: [String: [FileItem]] = [:]
                for item in candidates {
                    switch try ContentHasher.fullDigest(of: item.url, length: length) {
                    case .digest(let digest): byContent[digest, default: []].append(item)
                    case .skipped(let reason): skipped[reason, default: 0] += 1
                    }
                }
                for (digest, copies) in byContent where copies.count > 1 {
                    sets.append(makeSet(id: digest, copies))
                }
            }
        }
        let sorted = sets.sorted { a, b in
            a.extraBytes != b.extraBytes ? a.extraBytes > b.extraBytes : a.id < b.id
        }
        return DuplicateFileReport(sets: sorted, skipped: skipped)
    }

    /// Copies in keeping order, the suggested keeper first:
    /// 1. not inside a folder named Downloads, since a download is usually the stray copy;
    /// 2. the oldest by creation date (modification date when there's none), then by
    ///    modification date, since the first copy is usually the one the user filed;
    /// 3. the shortest path, then the id, so the choice never depends on scan order.
    static func keepingOrder(_ items: [FileItem]) -> [FileItem] {
        items.sorted { a, b in
            let aDownloads = isInDownloads(a)
            let bDownloads = isInDownloads(b)
            if aDownloads != bDownloads { return !aDownloads }
            let aCreated = a.created ?? a.modified
            let bCreated = b.created ?? b.modified
            if aCreated != bCreated { return aCreated < bCreated }
            if a.modified != b.modified { return a.modified < b.modified }
            if a.id.count != b.id.count { return a.id.count < b.id.count }
            return a.id < b.id
        }
    }

    /// True when any folder on the file's path is named Downloads, including the chosen folder.
    static func isInDownloads(_ item: FileItem) -> Bool {
        item.url.standardized.pathComponents.dropLast().contains {
            $0.compare("Downloads", options: .caseInsensitive) == .orderedSame
        }
    }

    private static func makeSet(id: String, _ copies: [FileItem]) -> DuplicateFileSet {
        let ordered = keepingOrder(copies)
        return DuplicateFileSet(id: id, items: ordered, keeperID: ordered[0].id)
    }

    /// One item per file. Hard links (and one path listed twice) are the same file: moving one
    /// gives no space back, so they must never be offered as copies of each other.
    private static func oneEntryPerFile(_ items: [FileItem]) -> [FileItem] {
        let byFile = Dictionary(grouping: items) { item in
            item.identity.map { "\($0.device):\($0.inode)" } ?? "path:\(item.id)"
        }
        return byFile.values.compactMap { keepingOrder($0).first }
    }
}

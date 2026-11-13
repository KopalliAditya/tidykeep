import Foundation

/// How far a check has got, for "1,204 checked".
public struct FileScanProgress: Hashable, Sendable {
    /// Files found so far, each counted once.
    public let checked: Int
    /// Files left out so far, for any reason.
    public let skipped: Int

    public init(checked: Int, skipped: Int) {
        self.checked = checked
        self.skipped = skipped
    }
}

/// Lists the files in the chosen folders. It reads names and sizes only; no file is opened,
/// and the walk runs with downloads barred, so even a folder whose listing is only in iCloud
/// isn't fetched.
///
/// Left out, and not counted, because they aren't the user's files to tidy:
/// - hidden files and folders (names starting with "." or marked hidden);
/// - symlinks, which point at a file that is listed where it really lives (or not at all);
/// - "Held by Tidykeep", wherever it is (even when it's the chosen folder), or held files would
///   come back as duplicates;
/// - packages such as a Pages document or an app. They look like one file but are folders, and
///   their parts can't be judged one by one, so they are skipped whole. Their size would need
///   every part read, which a check that only lists files shouldn't do. A folder named like a
///   package ("Edit.fcpbundle") counts too, even when no app on the device knows the type
///   (`PackageFolder`).
///
/// Left out and counted, for the Coverage sheet:
/// - files whose content is only in iCloud (`iCloudOnly`). Their status comes from the folder
///   listing, so seeing them never downloads them. A folder whose listing is only in iCloud
///   counts once;
/// - entries the system won't let the app read (`unreadable`).
///
/// A chosen folder that can't be opened at all isn't a skip: it goes in
/// `FileInventory.unavailableFolderIDs`, so the UI can name it and offer to choose it again.
public enum FileScanner: Sendable {
    /// Checks every folder. Each pair is a folder and the URL its bookmark resolved to.
    ///
    /// A file reached through two chosen folders (one inside the other) or through two hard
    /// links is listed once, under the shortest path inside its folder: for nested folders
    /// that's the inner one, so a later move stays as close as it can.
    ///
    /// Items come back sorted by id. Throws `CancellationError` when the task is cancelled.
    @concurrent
    public static func scan(
        _ folders: [(FolderRef, URL)],
        progress: @Sendable (FileScanProgress) -> Void = { _ in }
    ) async throws -> FileInventory {
        var tally = Tally()
        for (folder, url) in folders {
            try Task.checkCancellation()
            try FolderAccess.withAccess(to: url) {
                let root = FileFacts.canonical(url)
                // A chosen folder that is (or is inside) "Held by Tidykeep" holds files the user
                // already put aside. Offering them again would hold them twice.
                guard !root.pathComponents.contains(where: HoldingFolder.matches) else { return }
                // The walk never suspends, so the thread's rule against downloads holds for
                // all of it.
                try FileFacts.withoutDownloads {
                    guard FileFacts.canList(root) else {
                        if FileFacts.status(of: root)?.isDataless == true {
                            tally.skip(.iCloudOnly)
                        } else {
                            tally.unavailable.append(folder.id)
                        }
                        return
                    }
                    try walk(folder, root: root, into: &tally, progress: progress)
                }
            }
            progress(tally.progress)
        }
        let items = tally.found.values.sorted { $0.id < $1.id }
        return FileInventory(items: items, skipped: tally.skipped, unavailableFolderIDs: tally.unavailable)
    }

    /// The running count. Files are keyed by identity, so one file seen twice is one entry.
    private struct Tally {
        var found: [String: FileItem] = [:]
        var skipped: [FileSkipReason: Int] = [:]
        var unavailable: [UUID] = []
        var progress: FileScanProgress {
            FileScanProgress(checked: found.count, skipped: skipped.values.reduce(0, +))
        }

        mutating func skip(_ reason: FileSkipReason, count: Int = 1) {
            skipped[reason, default: 0] += count
        }

        mutating func add(_ item: FileItem) {
            let key = item.identity.map { "\($0.device):\($0.inode)" } ?? "path:\(item.id)"
            if let existing = found[key], !Self.prefers(item, over: existing) { return }
            found[key] = item
        }

        private static func prefers(_ a: FileItem, over b: FileItem) -> Bool {
            let aDepth = a.relativePath.split(separator: "/").count
            let bDepth = b.relativePath.split(separator: "/").count
            if aDepth != bDepth { return aDepth < bDepth }
            if a.id.count != b.id.count { return a.id.count < b.id.count }
            return a.id < b.id
        }
    }

    /// How often progress is reported. Often enough to look alive, rarely enough to be free.
    private static let progressEvery = 250

    // The directory enumerator can't be iterated from async code, so the walk is synchronous.
    // The caller runs it with downloads barred.
    private static func walk(
        _ folder: FolderRef,
        root: URL,
        into tally: inout Tally,
        progress: (FileScanProgress) -> Void
    ) throws {
        // Folders the enumerator couldn't open. It reports each one and keeps going. With
        // downloads barred, a folder whose listing is only in iCloud lands here too.
        var unopenable: [FileSkipReason: Int] = [:]
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: FileFacts.scanKeys,
            options: [.skipsPackageDescendants],
            errorHandler: { url, _ in
                let reason: FileSkipReason = FileFacts.status(of: url)?.isDataless == true ? .iCloudOnly : .unreadable
                unopenable[reason, default: 0] += 1
                return true
            }
        ) else {
            tally.skip(.unreadable)
            return
        }
        let keys = Set(FileFacts.scanKeys)
        var seen = 0
        while let next = walker.nextObject() {
            try Task.checkCancellation()
            guard let url = next as? URL else { continue }
            seen += 1
            if seen.isMultiple(of: progressEvery) { progress(tally.progress) }

            let name = url.lastPathComponent
            guard let values = try? url.resourceValues(forKeys: keys) else {
                tally.skip(.unreadable)
                continue
            }
            if values.isSymbolicLink == true { continue }
            if name.hasPrefix(".") || values.isHidden == true {
                // Older iCloud Drive placeholders are hidden ".name.icloud" stand-ins.
                if name.hasPrefix("."), name.hasSuffix(".icloud") { tally.skip(.iCloudOnly) }
                if values.isDirectory == true { walker.skipDescendants() }
                continue
            }
            if values.isDirectory == true {
                if HoldingFolder.matches(name) || PackageFolder.matches(name) { walker.skipDescendants() }
                // A package the system knows arrives here as one directory with its insides
                // already skipped.
                continue
            }
            guard values.isRegularFile == true else { continue }
            if let downloading = values.ubiquitousItemDownloadingStatus, downloading != .current {
                tally.skip(.iCloudOnly)
                continue
            }
            let status = FileFacts.status(of: url)
            if status?.isDataless == true {
                tally.skip(.iCloudOnly)
                continue
            }
            guard values.isReadable != false,
                  let parts = FileFacts.components(of: url, under: root) else {
                tally.skip(.unreadable)
                continue
            }
            let logical = Int64(values.fileSize ?? 0)
            let allocated = values.totalFileAllocatedSize.map(Int64.init) ?? logical
            tally.add(FileItem(
                url: url,
                bytes: allocated,
                logicalBytes: logical,
                unsharedBytes: FileFacts.unsharedBytes(of: url, allocated: allocated),
                modified: values.contentModificationDate ?? .distantPast,
                created: values.creationDate,
                folderID: folder.id,
                relativePath: parts.joined(separator: "/"),
                identity: status?.identity
            ))
        }
        for (reason, count) in unopenable { tally.skip(reason, count: count) }
    }
}

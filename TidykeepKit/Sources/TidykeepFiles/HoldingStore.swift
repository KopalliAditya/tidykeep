import Foundation

/// Moves files into "Held by Tidykeep" and remembers where each came from, so it can be put
/// back or deleted for good.
///
/// The folder is the truth about what's held: the user can see it, and empty it, in the Files
/// app. The manifest (a JSON file the app keeps in its own storage) is the truth only about
/// original paths, which the folder can't hold. `reconcile` brings the two back in step.
///
/// Nothing is dropped from the list or deleted on a guess. A held file counts as gone only when
/// the system says there's no such file, and a file at a held path counts as the held one only
/// when it matches what was moved there (`HoldingItem.heldIdentity`).
///
/// Every method opens the chosen folder's security scope itself. `folderRoot` must be the
/// current URL of the folder the item belongs to (`FolderAccess.resolve`).
public actor HoldingStore {
    public nonisolated let manifestURL: URL
    /// Loaded on first use. Nil until then.
    private var rows: [HoldingItem]?

    public init(manifestURL: URL) {
        self.manifestURL = manifestURL
    }

    /// Every held file, in the order they were held.
    public func items() throws -> [HoldingItem] {
        try loaded()
    }

    /// Held files in one chosen folder, in the order they were held.
    public func items(in folderID: UUID) throws -> [HoldingItem] {
        try loaded().filter { $0.folderID == folderID }
    }

    /// Where a held file is now, for previewing it or handing it to the system's file mover.
    public func heldURL(of id: UUID, folderRoot: URL) throws -> URL {
        let item = try row(id)
        guard let url = FileFacts.url(item.heldRelativePath, under: FileFacts.canonical(folderRoot)) else {
            throw FilesError.heldFileMissing(name: item.name)
        }
        return url
    }

    /// Moves a file into "Held by Tidykeep" at the root of its chosen folder. A clash with a
    /// file already held gets "name 2.ext". When anything goes wrong the file stays where it was.
    ///
    /// Refuses (`fileChanged`) a file that changed since the check, because the user decided
    /// about the file as it was. Refuses (`outsideFolder`) a file outside `folderRoot`, already
    /// held, or inside a package (`PackageFolder`).
    ///
    /// For the extra copies of a duplicate set use `holdExtras(of:folderRoots:)`, which first
    /// makes sure the copy being kept is still there.
    public func hold(_ file: FileItem, folderRoot: URL) throws -> HoldingItem {
        let current = try loaded()
        return try FolderAccess.withAccess(to: folderRoot) {
            let root = FileFacts.canonical(folderRoot)
            let checked = try check(file, root: root)
            let parts = checked.parts
            let stillIn = parts.count > 1 ? parts[parts.count - 2] : FileFacts.displayName(of: root)

            let holding = HoldingFolder.url(in: root)
            let taken = Set(current.filter { $0.folderID == file.folderID }.map {
                ($0.heldRelativePath as NSString).lastPathComponent
            })
            do {
                try FileManager.default.createDirectory(at: holding, withIntermediateDirectories: true)
            } catch {
                throw Self.failure(error, name: file.name, folder: stillIn, ifGone: .fileChanged(name: file.name))
            }
            let heldName = UniqueName.pick(for: file.name, in: holding, avoiding: taken)
            let destination = holding.appendingPathComponent(heldName, isDirectory: false)
            let item = HoldingItem(
                name: file.name,
                folderID: file.folderID,
                originalRelativePath: parts.joined(separator: "/"),
                heldRelativePath: "\(HoldingFolder.name)/\(heldName)",
                // Read now, not at the check: a clone made since then shares the file's blocks.
                bytes: FileFacts.unsharedBytes(of: checked.source, allocated: file.bytes),
                movedAt: Date(),
                heldIdentity: checked.status.identity,
                heldLength: file.logicalBytes,
                heldModified: file.modified
            )
            // The row is saved before the move. If the app stops in between, reconcile drops a
            // row whose file never arrived; the other order would leave a held file with no way back.
            try write(current + [item])
            rows = current + [item]
            do {
                try CoordinatedFiles.move(checked.source, to: destination)
            } catch {
                rows = current
                try? write(current)
                throw Self.failure(error, name: file.name, folder: stillIn, ifGone: .fileChanged(name: file.name))
            }
            // A rename keeps a file's identity on most volumes. Where it doesn't, the row learns
            // the new one; if that can't be saved, the length and date still recognize the file.
            if let moved = FileFacts.status(of: destination)?.identity, moved != item.heldIdentity {
                let updated = item.withHeldIdentity(moved)
                if (try? write(current + [updated])) != nil {
                    rows = current + [updated]
                    return updated
                }
            }
            return item
        }
    }

    /// Moves the extra copies of a duplicate set into "Held by Tidykeep", once the copy being
    /// kept is confirmed to be where it was, as it was.
    ///
    /// The user agreed to move the extras because the keeper stays. If the keeper was moved
    /// since the check (perhaps held from Large Files), deleted or edited, holding the extras
    /// could leave no copy outside Holding, and emptying it would delete the only one. So when
    /// anything about the keeper changed this throws `fileChanged` with the keeper's name, and
    /// moves nothing.
    ///
    /// `folderRoots` maps each chosen folder's id to its current URL (`FolderAccess.resolve`).
    /// A copy whose folder isn't in it is refused (`outsideFolder`); for the keeper, that
    /// refuses the whole set.
    ///
    /// Returns one result per extra, in `set.extras` order: the held item, or why that copy
    /// stayed where it was (the same errors as `hold`).
    public func holdExtras(of set: DuplicateFileSet, folderRoots: [UUID: URL]) throws -> [Result<HoldingItem, FilesError>] {
        guard let keeper = set.keeper else { throw FilesError.fileChanged(name: set.items.first?.name ?? set.id) }
        guard let keeperRoot = folderRoots[keeper.folderID] else { throw FilesError.outsideFolder(name: keeper.name) }
        try FolderAccess.withAccess(to: keeperRoot) {
            do {
                _ = try check(keeper, root: FileFacts.canonical(keeperRoot))
            } catch {
                throw FilesError.fileChanged(name: keeper.name)
            }
        }
        var results: [Result<HoldingItem, FilesError>] = []
        for extra in set.extras {
            guard let root = folderRoots[extra.folderID] else {
                results.append(.failure(.outsideFolder(name: extra.name)))
                continue
            }
            do {
                results.append(.success(try hold(extra, folderRoot: root)))
            } catch let error as FilesError {
                results.append(.failure(error))
            }
        }
        return results
    }

    /// Moves a held file back to where it was and returns its URL there. A clash gets
    /// "name 2.ext". Throws `originalFolderMissing` when the folder it came from is gone; the
    /// file stays held, and the UI can offer the system's file mover (then call `forget`).
    ///
    /// Throws `heldFileMissing` when the held file is gone or something else is at its path
    /// (which is left alone), and `couldNotMove` when it can't be checked right now.
    public func putBack(_ id: UUID, folderRoot: URL) throws -> URL {
        let current = try loaded()
        let item = try row(id)
        return try FolderAccess.withAccess(to: folderRoot) {
            let root = FileFacts.canonical(folderRoot)
            guard FileFacts.canList(root) else { throw FilesError.folderUnavailable(name: FileFacts.displayName(of: root)) }
            let held: URL
            switch Self.heldFile(item, root: root) {
            case .here(let url): held = url
            case .gone, .replaced: throw FilesError.heldFileMissing(name: item.name)
            case .unknown: throw FilesError.couldNotMove(name: item.name, folder: HoldingFolder.name)
            }
            let folderName = item.originalFolderPath.isEmpty ? FileFacts.displayName(of: root) : item.originalFolderPath
            guard let original = FileFacts.url(item.originalRelativePath, under: root),
                  FileFacts.isDirectory(original.deletingLastPathComponent()) else {
                throw FilesError.originalFolderMissing(name: item.name, folder: folderName)
            }
            let parent = original.deletingLastPathComponent()
            let destination = parent.appendingPathComponent(
                UniqueName.pick(for: original.lastPathComponent, in: parent),
                isDirectory: false
            )
            do {
                try CoordinatedFiles.move(held, to: destination)
            } catch {
                throw Self.failure(error, name: item.name, folder: HoldingFolder.name, ifGone: .heldFileMissing(name: item.name))
            }
            // The file is back whatever happens next. If the save fails, the row points at a
            // held file that's gone, so the next reconcile drops it.
            let remaining = current.filter { $0.id != id }
            rows = remaining
            try? write(remaining)
            return destination
        }
    }

    /// Deletes a held file permanently. Nothing goes to a trash, so the UI confirms first.
    ///
    /// A file the user already deleted in the Files app just leaves the list. Anything else at
    /// the held path, such as a file the user dropped in under the same name or a folder, is
    /// left alone (`heldFileMissing`). When the file can't be checked right now nothing
    /// changes (`couldNotDelete`).
    public func delete(_ id: UUID, folderRoot: URL) throws {
        let current = try loaded()
        let item = try row(id)
        try FolderAccess.withAccess(to: folderRoot) {
            let root = FileFacts.canonical(folderRoot)
            guard FileFacts.canList(root) else { throw FilesError.folderUnavailable(name: FileFacts.displayName(of: root)) }
            switch Self.heldFile(item, root: root) {
            case .here(let held):
                do {
                    try CoordinatedFiles.delete(held)
                } catch {
                    // Gone a moment ago (deleted in the Files app) is what the user asked for.
                    if !FilesError.isNoSuchFile(error) { throw FilesError.couldNotDelete(name: item.name) }
                }
            case .gone:
                break
            case .replaced:
                throw FilesError.heldFileMissing(name: item.name)
            case .unknown:
                throw FilesError.couldNotDelete(name: item.name)
            }
            let remaining = current.filter { $0.id != id }
            rows = remaining
            try? write(remaining)
        }
    }

    /// Drops the row without touching any file, for a file the user put back somewhere else
    /// with the system's file mover.
    public func forget(_ id: UUID) throws {
        let remaining = try loaded().filter { $0.id != id }
        try write(remaining)
        rows = remaining
    }

    /// Drops rows of one chosen folder whose held file is gone, usually because the user
    /// emptied "Held by Tidykeep" in the Files app, or whose path now holds something else.
    /// Returns the rows dropped, for a receipt.
    ///
    /// Files in the folder with no row (dropped in by the user) are left alone: there's no
    /// original path to offer. When the folder can't be opened nothing is dropped, because
    /// an unreachable folder looks the same as an empty one; a row whose file can't be checked
    /// right now stays too.
    @discardableResult
    public func reconcile(folderID: UUID, folderRoot: URL) throws -> [HoldingItem] {
        let current = try loaded()
        return try FolderAccess.withAccess(to: folderRoot) {
            let root = FileFacts.canonical(folderRoot)
            guard FileFacts.canList(root) else { throw FilesError.folderUnavailable(name: FileFacts.displayName(of: root)) }
            let gone = current.filter { item in
                guard item.folderID == folderID else { return false }
                switch Self.heldFile(item, root: root) {
                case .gone, .replaced: return true
                case .here, .unknown: return false
                }
            }
            guard !gone.isEmpty else { return [] }
            let goneIDs = Set(gone.map(\.id))
            let remaining = current.filter { !goneIDs.contains($0.id) }
            try write(remaining)
            rows = remaining
            return gone
        }
    }

    // MARK: - Manifest

    private struct Manifest: Codable {
        var version = 1
        var items: [HoldingItem]
    }

    private func row(_ id: UUID) throws -> HoldingItem {
        guard let item = try loaded().first(where: { $0.id == id }) else { throw FilesError.notHeld(id: id) }
        return item
    }

    /// A manifest that exists but can't be read throws and is never overwritten: it's the only
    /// record of where held files came from.
    private func loaded() throws -> [HoldingItem] {
        if let rows { return rows }
        // Only "no such file" means there's no list yet. Any other failure falls through to
        // the read, which throws.
        if FileFacts.isMissing(manifestURL) {
            rows = []
            return []
        }
        do {
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
            rows = manifest.items
            return manifest.items
        } catch {
            throw FilesError.unreadable(path: FileFacts.path(of: manifestURL))
        }
    }

    /// Writes atomically, so a crash leaves the old list or the new one, never half of each.
    private func write(_ items: [HoldingItem]) throws {
        do {
            try FileManager.default.createDirectory(
                at: manifestURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Manifest(items: items)).write(to: manifestURL, options: .atomic)
        } catch {
            throw FilesError.couldNotSaveManifest(path: FileFacts.path(of: manifestURL))
        }
    }

    // MARK: - Checks

    /// A file that passed the checks every move needs, and where it is.
    private struct Checked {
        let source: URL
        let parts: [String]
        let status: FileFacts.Status
    }

    /// Where `file` is inside `root` (canonical), once it's known to be there, inside the
    /// folder, not already held, not part of a package and unchanged since the check.
    private func check(_ file: FileItem, root: URL) throws -> Checked {
        let source = FileFacts.canonicalFile(file.url)
        // A vanished file (or folder) can't be canonicalized, so it could look like it's
        // outside the folder. Say what really happened.
        guard let status = FileFacts.status(of: source) else { throw FilesError.fileChanged(name: file.name) }
        // Already held (in "Held by Tidykeep", or a chosen folder inside it) counts as outside:
        // holding it again would bury it one level deeper. So does a part of a package: moving
        // it out would break the document it belongs to.
        guard let parts = FileFacts.components(of: source, under: root),
              !(root.pathComponents + parts.dropLast()).contains(where: HoldingFolder.matches),
              !parts.dropLast().contains(where: PackageFolder.matches) else {
            throw FilesError.outsideFolder(name: file.name)
        }
        guard Self.isUnchanged(file, status, at: source) else { throw FilesError.fileChanged(name: file.name) }
        return Checked(source: source, parts: parts, status: status)
    }

    /// Same length, date and identity as when it was scanned, and still a plain file.
    private static func isUnchanged(_ file: FileItem, _ status: FileFacts.Status, at url: URL) -> Bool {
        guard status.isRegularFile, let now = FileFacts.lengthAndDate(of: url) else { return false }
        if let identity = file.identity, identity != status.identity { return false }
        return now.length == file.logicalBytes && abs(now.modified.timeIntervalSince(file.modified)) < 0.001
    }

    /// What's at a row's held path now.
    private enum HeldFile {
        /// The file Tidykeep moved there.
        case here(URL)
        /// Nothing, and the system says so.
        case gone
        /// Something else: a folder, or another file the user dropped in under the same name.
        case replaced
        /// The system wouldn't say. Nothing may be dropped or deleted on this.
        case unknown
    }

    private static func heldFile(_ item: HoldingItem, root: URL) -> HeldFile {
        guard let held = FileFacts.url(item.heldRelativePath, under: root) else { return .gone }
        switch FileFacts.presence(of: held) {
        case .present(let status):
            return isHeldFile(item, status, at: held) ? .here(held) : .replaced
        case .unknown:
            return .unknown
        case .missing:
            // "No such file" inside a folder that can't be listed (an iCloud folder whose
            // listing isn't on the device, a share that's half there) proves nothing.
            let folder = held.deletingLastPathComponent()
            return FileFacts.isMissing(folder) || FileFacts.canList(folder) ? .gone : .unknown
        }
    }

    /// True when the file at a held path is the one Tidykeep moved there. Only the inode is
    /// compared, because the device number can change when a drive is plugged in again; where
    /// a volume renumbers files anyway, the same length and date still recognize it.
    private static func isHeldFile(_ item: HoldingItem, _ status: FileFacts.Status, at url: URL) -> Bool {
        guard status.isRegularFile else { return false }
        guard let identity = item.heldIdentity else { return true }
        if status.identity.inode == identity.inode { return true }
        guard let length = item.heldLength, let modified = item.heldModified,
              let now = FileFacts.lengthAndDate(of: url) else { return false }
        return now.length == length && abs(now.modified.timeIntervalSince(modified)) < 0.001
    }

    private static func failure(_ error: any Error, name: String, folder: String, ifGone: FilesError) -> FilesError {
        if let error = error as? FilesError { return error }
        if FilesError.isOutOfSpace(error) { return .notEnoughSpace(name: name) }
        if FilesError.isNoSuchFile(error) { return ifGone }
        return .couldNotMove(name: name, folder: folder)
    }
}

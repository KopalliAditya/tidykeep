import Foundation
import Observation
import TidykeepCore
import TidykeepFiles

/// Files in folders the user chose: duplicates, large files and Holding.
///
/// The folders are remembered as bookmarks in `folders.json`, and what is held in
/// `holding.json`, both in the model's directory (in memory when it is nil). Each check
/// first brings Holding in step with what is really in "Held by Tidykeep", then lists the
/// files, then compares the ones that share a size.
///
/// Nothing is deleted except through `emptyHolding()` and `delete(_:)`. Moving a file to
/// Holding is a rename inside its own folder, recorded in History with a way back.
@MainActor
@Observable
public final class FilesModel {
    // MARK: Types

    /// A chosen folder as the screens show it.
    public struct Folder: Identifiable, Hashable, Sendable {
        public let id: UUID
        public let name: String
        /// False when its bookmark no longer opens, so the user needs to choose it again.
        public let isAvailable: Bool
    }

    /// Where the check is.
    enum Phase: Equatable {
        case idle
        /// Listing the folders; the total isn't known yet.
        case listing(found: Int)
        /// Comparing files that share a size. Files of a size no other file has count as
        /// checked straight away.
        case comparing(checked: Int, total: Int)
    }

    /// A set of identical files as offered: the copy that stays, the copies that can move, and
    /// any copies that stay because they changed recently (the 7-day rule).
    struct DuplicateGroup: Identifiable, Hashable {
        /// Every copy still in place, the kept one first.
        let fileSet: DuplicateFileSet
        let movable: [FileItem]
        let recent: [FileItem]

        var id: String { fileSet.id }
        var keeper: FileItem { fileSet.keeper ?? fileSet.items[0] }
        var items: [FileItem] { fileSet.items }
        /// What moving the copies gives back: blocks they don't share with another file.
        var extraBytes: Int64 { movable.reduce(0) { $0 + $1.unsharedBytes } }
    }

    // MARK: What Home reads

    /// Folders the user chose.
    public private(set) var folders: [Folder] = []
    /// Folders the user chose, by name.
    public var folderNames: [String] { folders.map(\.name) }
    public private(set) var isScanning = false
    /// Sets of identical files.
    public private(set) var duplicateSetCount = 0
    /// Bytes the extra copies take.
    public private(set) var duplicateExtraBytes: Int64 = 0
    public private(set) var largeFileCount = 0
    public private(set) var largeFileBytes: Int64 = 0
    /// Files in "Held by Tidykeep".
    public private(set) var holdingCount = 0
    public private(set) var holdingBytes: Int64 = 0

    public var folderCount: Int { folders.count }

    // MARK: What the screens read

    private(set) var phase = Phase.idle
    private(set) var duplicateGroups: [DuplicateGroup] = []
    /// Biggest first.
    private(set) var largeFiles: [FileItem] = []
    /// Newest first.
    private(set) var held: [HoldingItem] = []
    /// Files listed in the last check.
    private(set) var checkedCount = 0
    /// Files left out of the last check, by reason.
    private(set) var skipped: [FileSkipReason: Int] = [:]
    /// Files left out by the "changed in the last 7 days" rule.
    private(set) var keptByRule = 0
    /// True once a check has finished, so an empty list means "nothing found".
    private(set) var hasChecked = false
    /// A move, put back or delete in progress.
    private(set) var isBusy = false
    /// What went wrong last, in a sentence. Cleared by the next change that works.
    private(set) var lastError: String?

    var skippedCount: Int { skipped.values.reduce(0, +) + keptByRule }
    var duplicateExtraCount: Int { duplicateGroups.reduce(0) { $0 + $1.movable.count } }
    var unavailableFolders: [Folder] { folders.filter { !$0.isAvailable } }
    /// Days the 7-day rule covers, or nil when it is off.
    var recentDays: Int? { preferences.rules.hideFilesChangedWithinDays }
    var largeFileMinimum: Int64 { preferences.largeFileMinimum }

    // MARK: State

    private let directory: URL?
    private let preferences: Preferences
    private let history: History
    private let notices: Notices
    private let foldersFile: JSONFile<[FolderRef]>?
    private let holding: HoldingStore

    private var refs: [FolderRef]
    /// Where each folder's bookmark resolved to this session.
    private var urls: [UUID: URL] = [:]
    private var unavailableIDs: Set<UUID> = []
    /// Files from the last check, minus any moved to Holding since.
    private var present: [FileItem] = []
    private var foundSets: [DuplicateFileSet] = []
    /// Copies the user chose to keep instead of the suggested one, by set id.
    private var keeperChoices: [String: String] = [:]
    /// Folders whose Holding rows should be forgotten before the next check (the sample).
    private var pendingHoldingClear: Set<UUID> = []

    private var prepared = false
    private var started = false
    private var scanTask: Task<Void, Never>?
    private var scanToken = 0
    /// Bumped by every move, so a check that was listing at the time knows to start again.
    private var changeCount = 0
    private var lastScanned: Date?

    public init(directory: URL?, preferences: Preferences, history: History, notices: Notices) {
        self.directory = directory
        self.preferences = preferences
        self.history = history
        self.notices = notices
        let foldersFile = directory.map { JSONFile<[FolderRef]>(url: $0.appendingPathComponent("folders.json")) }
        self.foldersFile = foldersFile
        let manifest = directory?.appendingPathComponent("holding.json")
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("tidykeep-holding-\(UUID().uuidString).json")
        self.holding = HoldingStore(manifestURL: manifest)
        self.refs = foldersFile?.load() ?? []
        publishFolders()
    }

    // MARK: Starting and checking

    /// Loads the saved folders and checks them.
    public func start() async {
        guard !started else { return }
        started = true
        await prepare()
        rescan()
    }

    public func rescan() {
        guard started else { return }
        scanTask?.cancel()
        scanToken += 1
        let token = scanToken
        scanTask = Task { [weak self] in await self?.runScan(token: token) }
    }

    /// Checks again when the app comes back if the folders may have changed.
    public func refreshIfStale() async {
        guard started, !isScanning, !isBusy else { return }
        if let lastScanned, Date().timeIntervalSince(lastScanned) < 30 { return }
        rescan()
    }

    /// Waits for the check in progress, and any it starts, to finish. For tests.
    func scanned() async {
        while let task = scanTask {
            await task.value
            if scanTask == task { return }
        }
    }

    /// Resolves the folders and loads Holding, once. Runs before the first check, and before
    /// History asks about an interrupted change.
    private func prepare() async {
        guard !prepared else { return }
        prepared = true
        resolveFolders()
        await clearPendingHolding()
        await reloadHolding()
    }

    private func runScan(token: Int) async {
        await prepare()
        await clearPendingHolding()
        guard token == scanToken else { return }
        resolveFolders()
        guard !refs.isEmpty else {
            clearResults()
            return
        }
        isScanning = true
        phase = .listing(found: 0)
        let changesAtStart = changeCount
        defer {
            if token == scanToken {
                isScanning = false
                phase = .idle
            }
        }

        for ref in refs {
            guard let url = urls[ref.id] else { continue }
            _ = try? await holding.reconcile(folderID: ref.id, folderRoot: url)
        }
        await reloadHolding()

        let pairs: [(FolderRef, URL)] = refs.compactMap { ref in urls[ref.id].map { (ref, $0) } }
        let (stream, continuation) = AsyncStream.makeStream(of: FileScanProgress.self, bufferingPolicy: .bufferingNewest(1))
        let listener = Task { [weak self] in
            for await progress in stream {
                guard let self, token == self.scanToken, case .listing = self.phase else { continue }
                self.phase = .listing(found: progress.checked)
            }
        }
        defer {
            continuation.finish()
            listener.cancel()
        }
        do {
            let (inventory, report) = try await FolderAccess.withAccess(to: pairs.map(\.1)) {
                let inventory = try await FileScanner.scan(pairs) { continuation.yield($0) }
                continuation.finish()
                let report = try await compare(inventory.items, token: token)
                return (inventory, report)
            }
            guard token == scanToken else { return }
            guard changeCount == changesAtStart else {
                // A file moved while the folders were being listed; the list may still name it
                // where it was.
                rescan()
                return
            }
            apply(inventory, report)
        } catch is CancellationError {
            return
        } catch {
            if token == scanToken { lastError = Copy.Files.checkFailed }
        }
    }

    /// Finds identical files, a few sizes at a time, so progress can say how far it got.
    private func compare(_ items: [FileItem], token: Int) async throws -> DuplicateFileReport {
        let total = items.count
        let groups = Dictionary(grouping: items.filter { $0.logicalBytes > 0 }, by: \.logicalBytes)
            .filter { $0.value.count > 1 }
            .sorted { $0.key > $1.key }
        var checked = total - groups.reduce(0) { $0 + $1.value.count }
        if token == scanToken { phase = .comparing(checked: checked, total: total) }

        var report = DuplicateFileReport()
        var index = 0
        while index < groups.count {
            var batch: [FileItem] = []
            var batchBytes: Int64 = 0
            while index < groups.count, batch.isEmpty || (batch.count < 64 && batchBytes < 256_000_000) {
                batch += groups[index].value
                batchBytes += groups[index].key * Int64(groups[index].value.count)
                index += 1
            }
            let part = try await DuplicateFileFinder.find(batch)
            report.sets += part.sets
            for (reason, count) in part.skipped { report.skipped[reason, default: 0] += count }
            checked += batch.count
            if token == scanToken { phase = .comparing(checked: checked, total: total) }
        }
        report.sets.sort { a, b in a.extraBytes != b.extraBytes ? a.extraBytes > b.extraBytes : a.id < b.id }
        return report
    }

    private func apply(_ inventory: FileInventory, _ report: DuplicateFileReport) {
        present = inventory.items
        foundSets = report.sets
        var skipped = inventory.skipped
        for (reason, count) in report.skipped { skipped[reason, default: 0] += count }
        self.skipped = skipped
        checkedCount = inventory.checkedCount
        unavailableIDs.formUnion(inventory.unavailableFolderIDs)
        publishFolders()
        lastScanned = Date()
        hasChecked = true
        derive()
    }

    private func clearResults() {
        present = []
        foundSets = []
        skipped = [:]
        checkedCount = 0
        isScanning = false
        phase = .idle
        hasChecked = true
        derive()
    }

    /// Rebuilds the lists and counts from the last check, the user's keeper choices and the
    /// rules. Cheap: nothing is read from disk.
    private func derive() {
        let now = Date()
        let days = recentDays
        let cutoff = days.map { now.addingTimeInterval(-TimeInterval($0) * 86_400) }
        func isRecent(_ item: FileItem) -> Bool {
            guard let cutoff else { return false }
            return max(item.modified, item.created ?? item.modified) > cutoff
        }

        let presentIDs = Set(present.map(\.id))
        var kept = Set<String>()
        var groups: [DuplicateGroup] = []
        for found in foundSets {
            let items = found.items.filter { presentIDs.contains($0.id) }
            guard items.count > 1 else { continue }
            let keeperID = items.contains { $0.id == found.keeperID } ? found.keeperID : items[0].id
            var set = DuplicateFileSet(id: found.id, items: items, keeperID: keeperID)
            if let choice = keeperChoices[found.id] { set = set.keeping(choice) }
            let recent = set.extras.filter(isRecent)
            let movable = set.extras.filter { !isRecent($0) }
            kept.formUnion(recent.map(\.id))
            guard !movable.isEmpty else { continue }
            groups.append(DuplicateGroup(fileSet: set, movable: movable, recent: recent))
        }
        groups.sort { a, b in a.extraBytes != b.extraBytes ? a.extraBytes > b.extraBytes : a.id < b.id }
        duplicateGroups = groups
        duplicateSetCount = groups.count
        duplicateExtraBytes = groups.reduce(0) { $0 + $1.extraBytes }

        let minimum = preferences.largeFileMinimum
        largeFiles = LargeFileFinder.find(present, minBytes: minimum, hideChangedWithinDays: days, now: now)
        largeFileCount = largeFiles.count
        largeFileBytes = largeFiles.reduce(0) { $0 + $1.bytes }
        kept.formUnion(present.filter { $0.bytes >= minimum && isRecent($0) }.map(\.id))
        keptByRule = kept.count
    }

    // MARK: Folders

    /// Adds a folder the system picker returned, remembering it with a bookmark, and checks.
    /// Choosing a folder that is already there (say, one that couldn't be opened) refreshes
    /// its bookmark instead of adding it twice.
    public func addFolder(_ url: URL) {
        addFolders([url])
    }

    func addFolders(_ picked: [URL]) {
        var names: [String] = []
        for url in picked {
            do {
                names.append(try insertFolder(url).displayName)
            } catch {
                lastError = Copy.Files.couldNotAddFolder
            }
        }
        guard !names.isEmpty else { return }
        if names.count == picked.count { lastError = nil }
        saveFolders()
        publishFolders()
        notices.show(Copy.Files.addedFolders(names), systemImage: "folder.badge.plus")
        rescan()
    }

    /// Stops checking a folder. Its held files go back where they were first; if any can't,
    /// the folder stays so they can still be reached.
    public func removeFolder(_ id: UUID) async {
        guard let ref = refs.first(where: { $0.id == id }) else { return }
        await prepare()
        let mine = held.filter { $0.folderID == id }
        if !mine.isEmpty {
            if urls[id] != nil, !unavailableIDs.contains(id) {
                let back = await putBackItems(mine, announce: false)
                guard back.count == mine.count else { return }
            } else {
                // The folder can't be opened, so its files can't be moved. They stay in
                // "Held by Tidykeep", where the Files app shows them.
                for item in mine { try? await holding.forget(item.id) }
            }
        }
        refs.removeAll { $0.id == id }
        urls[id] = nil
        unavailableIDs.remove(id)
        present.removeAll { $0.folderID == id }
        saveFolders()
        publishFolders()
        await reloadHolding()
        derive()
        notices.show(Copy.Files.removedFolder(ref.displayName), systemImage: "folder")
    }

    /// The chosen folder's name, for rows.
    func folderName(_ id: UUID) -> String {
        refs.first { $0.id == id }?.displayName ?? Copy.Files.formerFolder
    }

    /// "Downloads/Trips": the chosen folder and the folders inside it down to the file.
    func location(of item: FileItem) -> String {
        Self.join(folderName(item.folderID), item.parentPath)
    }

    /// Where a held file came from: "Downloads/Trips".
    func location(of item: HoldingItem) -> String {
        Self.join(folderName(item.folderID), item.originalFolderPath)
    }

    private static func join(_ folder: String, _ path: String) -> String {
        path.isEmpty ? folder : "\(folder)/\(path)"
    }

    private func insertFolder(_ url: URL) throws -> FolderRef {
        let made = try FolderAccess.makeRef(for: url)
        let path = Self.canonicalPath(url)
        let ref: FolderRef
        if let index = refs.firstIndex(where: { urls[$0.id].map(Self.canonicalPath) == path }) {
            ref = FolderRef(id: refs[index].id, displayName: made.displayName, bookmark: made.bookmark)
            refs[index] = ref
        } else {
            ref = made
            refs.append(ref)
        }
        urls[ref.id] = url
        unavailableIDs.remove(ref.id)
        return ref
    }

    private func resolveFolders() {
        var refreshed = false
        for (index, ref) in refs.enumerated() {
            do {
                let (url, isStale) = try FolderAccess.resolve(ref)
                urls[ref.id] = url
                unavailableIDs.remove(ref.id)
                if isStale, let fresh = try? FolderAccess.refreshed(ref, url: url) {
                    refs[index] = fresh
                    refreshed = true
                }
            } catch {
                urls[ref.id] = nil
                unavailableIDs.insert(ref.id)
            }
        }
        if refreshed { saveFolders() }
        publishFolders()
    }

    private func publishFolders() {
        folders = refs.map { ref in
            Folder(id: ref.id, name: ref.displayName, isAvailable: !unavailableIDs.contains(ref.id))
        }
    }

    private func saveFolders() {
        try? foldersFile?.save(refs)
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: Keeper

    /// Keeps a different copy of a set; the suggested one moves instead.
    func keep(_ fileID: String, inSet setID: String) {
        keeperChoices[setID] = fileID
        derive()
        if let name = group(setID)?.keeper.name {
            notices.announce(Copy.Files.keeperChanged(name))
        }
    }

    func group(_ id: String) -> DuplicateGroup? {
        duplicateGroups.first { $0.id == id }
    }

    // MARK: Moving to Holding

    /// Moves the extra copies of one set to Holding, keeping its chosen copy. Returns whether
    /// anything moved.
    @discardableResult
    func moveToHolding(_ group: DuplicateGroup) async -> Bool {
        await moveToHolding(groups: [group])
    }

    /// Moves the extra copies of several sets to Holding.
    @discardableResult
    func moveToHolding(groups: [DuplicateGroup]) async -> Bool {
        let files = groups.flatMap(\.movable)
        guard !files.isEmpty, !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        let receipt = beginHold(files)
        var moved: [(FileItem, HoldingItem)] = []
        var errors: [FilesError] = []
        for group in groups {
            // Only the copies on offer: a copy kept by the 7-day rule stays where it is.
            let set = DuplicateFileSet(id: group.id, items: [group.keeper] + group.movable, keeperID: group.keeper.id)
            do {
                let results = try await holding.holdExtras(of: set, folderRoots: urls)
                for (file, result) in zip(set.extras, results) {
                    switch result {
                    case .success(let item): moved.append((file, item))
                    case .failure(let error): errors.append(error)
                    }
                }
            } catch let error as FilesError {
                errors.append(error)
            } catch {
                errors.append(.fileChanged(name: group.keeper.name))
            }
        }
        return await finishHold(receipt, moved: moved, errors: errors)
    }

    /// Moves files (from Large Files) to Holding. Returns whether anything moved.
    @discardableResult
    func moveToHolding(_ files: [FileItem]) async -> Bool {
        guard !files.isEmpty, !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        let receipt = beginHold(files)
        var moved: [(FileItem, HoldingItem)] = []
        var errors: [FilesError] = []
        for file in files {
            guard let root = urls[file.folderID] else {
                errors.append(.folderUnavailable(name: folderName(file.folderID)))
                continue
            }
            do {
                moved.append((file, try await holding.hold(file, folderRoot: root)))
            } catch let error as FilesError {
                errors.append(error)
            } catch {
                errors.append(.couldNotMove(name: file.name, folder: location(of: file)))
            }
        }
        return await finishHold(receipt, moved: moved, errors: errors)
    }

    private func beginHold(_ files: [FileItem]) -> UUID {
        changeCount += 1
        return history.begin(
            .filesHeld,
            requested: files.count,
            itemIDs: files.map(\.id),
            bytes: files.reduce(0) { $0 + $1.unsharedBytes },
            title: files.count == 1 ? files[0].name : nil
        )
    }

    private func finishHold(_ receipt: UUID, moved: [(FileItem, HoldingItem)], errors: [FilesError]) async -> Bool {
        let heldIDs = moved.map(\.1.id)
        history.finish(receipt, completed: moved.count) {
            $0.itemIDs = moved.map(\.0.id)
            $0.bytes = moved.reduce(0) { $0 + $1.1.bytes }
            $0.title = moved.count == 1 ? moved[0].0.name : nil
            $0.payload = try? JSONEncoder().encode(heldIDs)
        }
        let movedPaths = Set(moved.map(\.0.id))
        present.removeAll { movedPaths.contains($0.id) }
        await reloadHolding()
        derive()
        lastError = errors.first.map(Copy.Files.error)
        guard !moved.isEmpty else {
            if let lastError { notices.announce(lastError, priority: .high) }
            return false
        }
        let done = Copy.Files.moved(moved.count)
        let text = errors.isEmpty ? done : Copy.Files.partly(done, failed: errors.count)
        notices.show(text, systemImage: "tray.and.arrow.down", undo: Notice.Undo(title: Copy.General.undo) { [weak self] in
            guard let self, let receipt = self.history.receipt(receipt) else { return }
            await self.putBack(receipt)
        })
        return true
    }

    // MARK: Putting back

    /// Undo for a `.filesHeld` receipt: moves the files back where they were.
    public func putBack(_ receipt: Receipt) async {
        guard receipt.kind == .filesHeld else { return }
        await prepare()
        await reloadHolding()
        let ids = receipt.payload.flatMap { try? JSONDecoder().decode([UUID].self, from: $0) } ?? []
        var items = held.filter { ids.contains($0.id) }
        if ids.isEmpty {
            // Cut off before it finished: match by where the files were.
            items = held.filter { item in receipt.itemIDs.contains { $0.hasSuffix("/" + item.originalRelativePath) } }
        }
        guard !items.isEmpty else {
            notices.show(Copy.Files.nothingToPutBack, systemImage: "info.circle")
            return
        }
        let back = await putBackItems(items, announce: true)
        if back.count == items.count, history.receipt(receipt.id)?.status != .undone {
            history.markUndone(receipt.id)
        }
    }

    /// Puts one held file back.
    func putBack(_ item: HoldingItem) async {
        _ = await putBackItems([item], announce: true)
    }

    /// Puts every held file back.
    func putAllBack() async {
        await prepare()
        _ = await putBackItems(held, announce: true)
    }

    private func putBackItems(_ items: [HoldingItem], announce: Bool) async -> [HoldingItem] {
        guard !items.isEmpty, !isBusy else { return [] }
        isBusy = true
        defer { isBusy = false }
        changeCount += 1
        let receipt = history.begin(
            .filesPutBack,
            requested: items.count,
            itemIDs: items.map(\.id.uuidString),
            bytes: items.reduce(0) { $0 + $1.bytes },
            title: items.count == 1 ? items[0].name : nil
        )
        var back: [HoldingItem] = []
        var errors: [FilesError] = []
        for item in items {
            guard let root = urls[item.folderID] else {
                errors.append(.folderUnavailable(name: folderName(item.folderID)))
                continue
            }
            do {
                _ = try await holding.putBack(item.id, folderRoot: root)
                back.append(item)
            } catch let error as FilesError {
                errors.append(error)
            } catch {
                errors.append(.couldNotMove(name: item.name, folder: HoldingFolder.name))
            }
        }
        history.finish(receipt, completed: back.count) {
            $0.itemIDs = back.map(\.id.uuidString)
            $0.bytes = back.reduce(0) { $0 + $1.bytes }
            $0.title = back.count == 1 ? back[0].name : nil
        }
        markHeldReceiptsUndone(Set(back.map(\.id)))
        await reloadHolding()
        lastError = errors.first.map(Copy.Files.error)
        if !back.isEmpty {
            if announce {
                let done = Copy.Files.putBackDone(back.count)
                notices.show(errors.isEmpty ? done : Copy.Files.partly(done, failed: errors.count), systemImage: "arrow.uturn.backward")
            }
            rescan()
        } else if let lastError {
            notices.announce(lastError, priority: .high)
        }
        return back
    }

    /// A move whose files are all back has been undone.
    private func markHeldReceiptsUndone(_ back: Set<UUID>) {
        guard !back.isEmpty else { return }
        for receipt in history.receipts where receipt.kind == .filesHeld && (receipt.status == .done || receipt.status == .partial) {
            guard let payload = receipt.payload,
                  let ids = try? JSONDecoder().decode([UUID].self, from: payload),
                  !ids.isEmpty, Set(ids).isSubset(of: back) else { continue }
            history.markUndone(receipt.id)
        }
    }

    // MARK: Deleting

    /// Deletes everything in Holding, for good. The screen confirms first.
    func emptyHolding() async {
        await prepare()
        await delete(held)
    }

    /// Deletes held files for good. The screen confirms first.
    func delete(_ items: [HoldingItem]) async {
        guard !items.isEmpty, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        changeCount += 1
        let receipt = history.begin(
            .filesDeleted,
            requested: items.count,
            itemIDs: items.map(\.id.uuidString),
            bytes: items.reduce(0) { $0 + $1.bytes },
            title: items.count == 1 ? items[0].name : nil
        )
        var gone: [HoldingItem] = []
        var errors: [FilesError] = []
        for item in items {
            guard let root = urls[item.folderID] else {
                errors.append(.folderUnavailable(name: folderName(item.folderID)))
                continue
            }
            do {
                try await holding.delete(item.id, folderRoot: root)
                gone.append(item)
            } catch let error as FilesError {
                errors.append(error)
            } catch {
                errors.append(.couldNotDelete(name: item.name))
            }
        }
        let bytes = gone.reduce(0) { $0 + $1.bytes }
        history.finish(receipt, completed: gone.count) {
            $0.itemIDs = gone.map(\.id.uuidString)
            $0.bytes = bytes
            $0.title = gone.count == 1 ? gone[0].name : nil
        }
        await reloadHolding()
        lastError = errors.first.map(Copy.Files.error)
        guard !gone.isEmpty else {
            if let lastError { notices.announce(lastError, priority: .high) }
            return
        }
        let inICloud = gone.contains { urls[$0.folderID].map(Self.isInICloudDrive) ?? false }
        let done = Copy.Files.deleted(gone.count, bytes: bytes, iCloud: inICloud)
        notices.show(errors.isEmpty ? done : Copy.Files.partly(done, failed: errors.count), systemImage: "trash")
    }

    private static func isInICloudDrive(_ url: URL) -> Bool {
        url.path.contains("/Mobile Documents/")
    }

    // MARK: Holding

    private func reloadHolding() async {
        do {
            held = try await holding.items().sorted { $0.movedAt > $1.movedAt }
        } catch {
            lastError = Copy.Files.error(.couldNotSaveManifest(path: holding.manifestURL.path))
        }
        holdingCount = held.count
        holdingBytes = held.reduce(0) { $0 + $1.bytes }
    }

    private func clearPendingHolding() async {
        let folderIDs = pendingHoldingClear
        pendingHoldingClear = []
        for folderID in folderIDs {
            for item in (try? await holding.items(in: folderID)) ?? [] {
                try? await holding.forget(item.id)
            }
        }
    }

    // MARK: History

    /// How many of an interrupted receipt's files are still where they started.
    func stillThere(_ receipt: Receipt) async -> Int {
        await prepare()
        switch receipt.kind {
        case .filesHeld:
            let paths = receipt.itemIDs
            return await FolderAccess.withAccess(to: Array(urls.values)) {
                paths.filter { FileManager.default.fileExists(atPath: $0) }.count
            }
        case .filesPutBack, .filesDeleted:
            let current = Set(((try? await holding.items()) ?? []).map(\.id.uuidString))
            return receipt.itemIDs.filter(current.contains).count
        default:
            return receipt.requested
        }
    }

    // MARK: Sample

    static let sampleFolderName = "Tidykeep Sample"

    /// Simulator only, for UI tests (`-TKSeedFiles YES`).
    func seedSample() {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        seedSample(in: documents)
    }

    /// Writes "Tidykeep Sample" in `documents` afresh (two identical PDFs, a small note and a
    /// 120 MB export, all about two months old) and chooses it. Running it again resets the
    /// folder and forgets what it had in Holding; it never adds a second folder.
    func seedSample(in documents: URL) {
        let folder = documents.appendingPathComponent(Self.sampleFolderName, isDirectory: true)
        let path = Self.canonicalPath(folder)
        // Found before the folder is rewritten, while its bookmark still resolves.
        let existing = refs.firstIndex { ref in
            if let url = try? FolderAccess.resolve(ref).url { return Self.canonicalPath(url) == path }
            return ref.displayName == Self.sampleFolderName
        }
        do {
            try SampleFiles.write(to: folder, now: Date())
            let made = try FolderAccess.makeRef(for: folder)
            let ref: FolderRef
            if let existing {
                ref = FolderRef(id: refs[existing].id, displayName: made.displayName, bookmark: made.bookmark)
                refs[existing] = ref
            } else {
                ref = made
                refs.append(ref)
            }
            urls[ref.id] = folder
            unavailableIDs.remove(ref.id)
            keeperChoices = [:]
            pendingHoldingClear.insert(ref.id)
            saveFolders()
            publishFolders()
            // Holding forgets the folder's old rows at the start of the next check.
            rescan()
        } catch {
            lastError = Copy.Files.couldNotAddFolder
        }
    }
}

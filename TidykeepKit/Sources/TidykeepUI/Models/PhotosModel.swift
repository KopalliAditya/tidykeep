import CoreGraphics
import Foundation
import Observation
import SwiftUI
import TidykeepCore

/// The photo library side of the app: checking, the four photo lists, and every change made
/// to photos, each with a receipt in History.
@MainActor
@Observable
public final class PhotosModel {
    public enum ScanState: Equatable {
        case idle
        case scanning(ScanProgress)
        case paused(ScanProgress)
        case stopped(ScanProgress)
        case finished(ScanProgress, Date)
        case failed

        public var isActive: Bool {
            switch self {
            case .scanning, .paused: true
            default: false
            }
        }

        public var progress: ScanProgress? {
            switch self {
            case .scanning(let p), .paused(let p), .stopped(let p), .finished(let p, _): p
            case .idle, .failed: nil
            }
        }
    }

    public private(set) var access: LibraryAccess = .notDetermined
    public private(set) var scanState: ScanState = .idle
    /// Similar shots to review, newest first, with the user's rules applied.
    public private(set) var similar: [PhotoGroup] = []
    /// Copy sets to review, newest first.
    public private(set) var copies: [PhotoGroup] = []
    /// False until the copy pass has seen every photo, so the list may still grow.
    public private(set) var copiesComplete = false
    /// Screenshots that could go, newest first. Favorites, edited ones and ones the rules keep
    /// are left out.
    public private(set) var screenshots: [AssetMeta] = []
    /// Videos over the minimum length, biggest first (duration × pixels).
    public private(set) var videos: [VideoMeta] = []
    public private(set) var albums: [PhotoAlbum] = []
    public private(set) var coverage = Coverage()
    /// Photo format names ("HEIC"), loaded for copy sets as they're opened.
    public private(set) var formats: [String: String] = [:]
    public private(set) var ledger: ReviewLedger
    public private(set) var isWorking = false
    /// Screenshots marked for removal on the Screenshots screen.
    public var markedScreenshots: Set<String> = []
    /// Videos marked for removal on the Big Videos screen.
    public var markedVideos: Set<String> = []

    private let source: any PhotoSource
    private let analyzer: any FrameAnalyzing
    private let directory: URL?
    private let preferences: Preferences
    private let history: History
    private let notices: Notices
    private let conditions: @Sendable () -> DeviceConditions
    private let findsCopies: Bool
    private let ledgerFile: JSONFile<ReviewLedger>?
    private var store: AnalysisStore?
    private var storeTask: Task<AnalysisStore, Never>?
    private var found = PhotoResults(similar: [], copies: [], copiesComplete: false)
    private var library: [AssetMeta] = []
    private var allVideos: [VideoMeta] = []
    private var keptByRules: Set<String> = []
    private var libraryCoverage = LibraryCoverage()
    /// Removed since the scan started. A scan already under way may still group them.
    private var removedIDs: Set<String> = []
    private var scanTask: Task<Void, Never>?
    private var changeTask: Task<Void, Never>?
    private var libraryChanged = false
    private var wasInBackground = false
    private var resumeOnActive = false
    @ObservationIgnored private let thumbnails = NSCache<NSString, ImageBox>()

    /// - Parameter directory: where the analysis cache and review ledger live; nil keeps them in memory.
    public init(
        source: any PhotoSource,
        analyzer: any FrameAnalyzing,
        directory: URL?,
        preferences: Preferences,
        history: History,
        notices: Notices,
        conditions: @escaping @Sendable () -> DeviceConditions = { .current() },
        findsCopies: Bool = true
    ) {
        self.source = source
        self.analyzer = analyzer
        self.directory = directory
        self.preferences = preferences
        self.history = history
        self.notices = notices
        self.conditions = conditions
        self.findsCopies = findsCopies
        self.ledgerFile = directory.map { JSONFile(url: $0.appendingPathComponent("review.json")) }
        self.ledger = ledgerFile?.load() ?? ReviewLedger()
        thumbnails.totalCostLimit = 64 << 20
    }

    // MARK: Access

    /// Reads the access state without asking. Starts checking when the app can read photos.
    public func start() async {
        access = await source.access()
        accessChanged()
    }

    public func requestAccess() async {
        access = await source.requestAccess()
        accessChanged()
    }

    /// Limited access only: the user picks which photos the app can see, then it checks again.
    public func chooseMorePhotos() async {
        await source.chooseMorePhotos()
        rescan()
    }

    private func accessChanged() {
        guard access.canRead else { return }
        observeLibraryChanges()
        if scanTask == nil { rescan() }
    }

    // MARK: Checking

    public func rescan() {
        guard access.canRead else { return }
        scanTask?.cancel()
        removedIDs = []
        // Show the new check straight away rather than the last one's result until it starts.
        scanState = .scanning(ScanProgress())
        scanTask = Task { await runScan() }
    }

    public func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        switch scanState {
        case .scanning(let p), .paused(let p): scanState = .stopped(p)
        default: break
        }
    }

    private func runScan() async {
        let store = await loadStore()
        let scope = preferences.scope
        let since = scope.startDate(now: Date())
        async let albumList = source.albums()
        async let videoList = try? source.fetchVideos(since: since)
        async let libraryCoverage = source.coverage(since: since)
        albums = await albumList
        allVideos = await videoList ?? []
        self.libraryCoverage = await libraryCoverage
        guard !Task.isCancelled else { return }
        refresh()

        let scanner = Scanner(source: source, analyzer: analyzer, store: store, conditions: conditions, findsCopies: findsCopies)
        var progress = ScanProgress()
        scanState = .scanning(progress)
        do {
            for try await event in scanner.scan(scope: scope, config: preferences.sensitivity.config) {
                guard !Task.isCancelled else { return }
                switch event {
                case .progress(let p):
                    progress = p
                    scanState = .scanning(p)
                    updateCoverage(p)
                case .paused:
                    // The scanner repeats this while the phone stays hot; say it once.
                    if case .paused = scanState {} else { notices.announce(Copy.Scan.paused) }
                    scanState = .paused(progress)
                case .library(let metas):
                    library = metas
                    refresh()
                case .results(let results):
                    found = results
                    refresh()
                case .finished(let p):
                    let now = Date()
                    ledger.lastScan = now
                    saveLedger()
                    scanState = .finished(p, now)
                    updateCoverage(p)
                    notices.announce(Copy.Scan.done(similar: similar.count, copies: copies.count))
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            scanState = .failed
            notices.announce(Copy.Scan.failed)
        }
    }

    /// Loads the cache once, however many checks ask for it at the same time.
    private func loadStore() async -> AnalysisStore {
        if let store { return store }
        if storeTask == nil {
            let url = directory?.appendingPathComponent("analysis.plist")
            let version = analyzer.version
            // Decoding a large cache shouldn't block the main thread.
            storeTask = Task.detached(priority: .userInitiated) { AnalysisStore(url: url, analyzerVersion: version) }
        }
        let loaded = await storeTask!.value
        store = loaded
        return loaded
    }

    /// Rebuilds the lists from the last results, the rules and the user's choices.
    func refresh() {
        let rules = preferences.rules
        var kept = Set<String>()
        for album in albums where rules.albumIDs.contains(album.id) { kept.formUnion(album.assetIDs) }
        if rules.keepScreenshotsInAlbums {
            let inAnyAlbum = albums.reduce(into: Set<String>()) { $0.formUnion($1.assetIDs) }
            kept.formUnion(library.lazy.filter { $0.isScreenshot && inAnyAlbum.contains($0.id) }.map(\.id))
        }
        keptByRules = kept

        let gone = removedIDs
        func visible(_ groups: [PhotoGroup]) -> [PhotoGroup] {
            groups
                .filter { !$0.members.contains { gone.contains($0.id) } && !ledger.dismissedGroups.contains($0.id) }
                .map { $0.applying(keptByRules: kept) }
        }
        similar = visible(found.similar).filter { !$0.isFullyProtected && $0.hasSuggestions }
        copies = visible(found.copies).filter { $0.hasSuggestions }
        copiesComplete = found.copiesComplete

        screenshots = library
            .filter { $0.isScreenshot && !$0.isProtected && !kept.contains($0.id) && !gone.contains($0.id) }
            .sorted { $0.creationDate > $1.creationDate }
        markedScreenshots.formIntersection(screenshots.map(\.id))

        videos = allVideos
            .filter { $0.duration >= preferences.videoMinimum && !$0.isProtected && !ledger.keptVideoIDs.contains($0.id) && !gone.contains($0.id) }
            .sorted { $0.weight != $1.weight ? $0.weight > $1.weight : $0.id < $1.id }
        markedVideos.formIntersection(videos.map(\.id))

        if let progress = scanState.progress { updateCoverage(progress) }
    }

    private func updateCoverage(_ p: ScanProgress) {
        var skipped: [SkipReason: Int] = [:]
        skipped[.iCloudOnly] = p.skippedInCloud
        skipped[.unreadable] = max(0, p.skipped - p.skippedInCloud)
        skipped[.outsideRange] = libraryCoverage.outsideRange
        skipped[.sharedAlbum] = libraryCoverage.inSharedAlbums
        skipped[.keptByRule] = library.lazy.filter { self.keptByRules.contains($0.id) }.count
        coverage = Coverage(checked: p.checked, skipped: skipped.filter { $0.value > 0 })
    }

    // MARK: Library changes

    private func observeLibraryChanges() {
        guard changeTask == nil else { return }
        let stream = source.changes()
        changeTask = Task { [weak self] in
            for await _ in stream { self?.libraryChanged = true }
        }
    }

    /// Stops a check in the background and picks it up on return. Checks again on return (say,
    /// from Photos) if the library changed. Not on every activation: the delete confirmation
    /// alert also deactivates the app.
    public func scenePhaseChanged(to phase: ScenePhase) {
        switch phase {
        case .background:
            wasInBackground = true
            // iOS doesn't let background apps use the GPU, which Vision and the model need.
            if scanState.isActive {
                stopScan()
                resumeOnActive = true
            }
            if let store { Task { try? await store.save() } }
        case .active:
            if wasInBackground, access.canRead, resumeOnActive || (libraryChanged && !scanState.isActive) {
                resumeOnActive = false
                libraryChanged = false
                rescan()
            }
            wasInBackground = false
        default:
            break
        }
    }

    // MARK: Similar shots and copies

    public func group(_ id: String) -> PhotoGroup? {
        similar.first { $0.id == id } ?? copies.first { $0.id == id }
    }

    public func isKept(_ id: String, in group: PhotoGroup) -> Bool {
        ledger.decisions.keeps(id, in: group)
    }

    public func removals(in group: PhotoGroup) -> [AssetMeta] {
        ledger.decisions.removals(in: group)
    }

    public var similarRemovalCount: Int { similar.reduce(0) { $0 + removals(in: $1).count } }
    public var copyRemovalCount: Int { copies.reduce(0) { $0 + removals(in: $1).count } }

    /// The copy that stays when a set is merged: the first one the user keeps, best first.
    public func copyKeeper(in group: PhotoGroup) -> AssetMeta {
        group.members.first { isKept($0.id, in: group) } ?? group.keeper
    }

    public func setKeep(_ keep: Bool, _ id: String, in group: PhotoGroup) {
        switch ledger.decisions.setKeep(keep, id, in: group) {
        case .protected?:
            notices.show(Copy.Similar.protectedRefusal, systemImage: "lock.shield")
        case .lastKept?:
            notices.show(Copy.Similar.lastKeptRefusal, systemImage: "info.circle")
        case nil:
            saveLedger()
            notices.announce("\(keep ? "Keeping it" : "Marked for removal"). \(Copy.Similar.tally(group, removing: removals(in: group).count))")
        }
    }

    public func keepOnly(_ id: String, in group: PhotoGroup) {
        ledger.decisions.keepOnly(id, in: group)
        saveLedger()
        notices.announce("Keeping only \(Copy.Similar.photoNumber(id, in: group)). \(Copy.Similar.tally(group, removing: removals(in: group).count))")
    }

    /// "Keep all": hides this group until a new photo joins it. Undo brings it back.
    public func keepAll(_ group: PhotoGroup) {
        ledger.dismissedGroups.insert(group.id)
        saveLedger()
        let id = history.begin(.keptAll, requested: group.members.count, itemIDs: [group.id])
        history.finish(id, completed: group.members.count)
        refresh()
        notices.show(Copy.Notices.keptAll(group.members.count), undo: Notice.Undo(title: Copy.General.undo) { [weak self] in
            guard let self, let receipt = self.history.receipt(id) else { return }
            self.reviewAgain(receipt)
        })
    }

    /// Undoes "Keep all": the group comes back to the list.
    public func reviewAgain(_ receipt: Receipt) {
        guard receipt.kind == .keptAll, receipt.status != .undone else { return }
        ledger.dismissedGroups.subtract(receipt.itemIDs)
        saveLedger()
        history.markUndone(receipt.id)
        refresh()
        notices.show(Copy.Notices.reviewAgain, systemImage: "arrow.uturn.backward")
    }

    public func restoreKeptGroups() {
        ledger.dismissedGroups.removeAll()
        saveLedger()
        refresh()
        notices.announce("Groups you kept are back in the list.")
    }

    /// Removes what the user marked in these groups.
    public func removeSuggested(in groups: [PhotoGroup]) async {
        let ids = groups.flatMap { removals(in: $0).map(\.id) }
        guard !ids.isEmpty, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        // If every photo a group would keep was deleted in Photos since the check, leave the
        // rest of it alone, so a moment is never removed entirely.
        let requested = Set(ids)
        let present = await source.existing(groups.flatMap { $0.members.map(\.id) })
        let safe = groups
            .filter { !ledger.decisions.keptIDs(in: $0).isDisjoint(with: present) }
            .flatMap { $0.members.map(\.id).filter(requested.contains) }

        let receipt = history.begin(.photosRemoved, requested: safe.count, itemIDs: safe)
        let deleted = safe.isEmpty ? [] : await source.delete(safe)
        guard !deleted.isEmpty else {
            history.discard(receipt)
            notices.show(Copy.Notices.nothingRemoved, systemImage: "info.circle")
            return
        }
        history.finish(receipt, completed: deleted.count) { $0.itemIDs = safe.filter(deleted.contains) }

        // A group the user just cleaned is done. What's left of it is kept and remembered as
        // reviewed, so it doesn't come back on the next check, even grouped differently.
        for group in groups where group.members.contains(where: { deleted.contains($0.id) }) {
            let left = group.members.map(\.id).filter { !deleted.contains($0) }
            ledger.decisions.pin(left)
            if left.count >= 2 { ledger.dismissedGroups.insert(Fingerprint.of(left)) }
        }
        await removed(deleted)
        notices.show(Copy.Notices.removedPhotos(deleted.count), systemImage: "trash")
    }

    /// Merges copy sets: the kept copy joins the albums of the others, which are removed.
    public func mergeCopies(_ groups: [PhotoGroup]) async {
        guard !isWorking else { return }
        let merges = groups.compactMap { group -> CopyMerge? in
            let remove = removals(in: group).map(\.id)
            return remove.isEmpty ? nil : CopyMerge(keeperID: copyKeeper(in: group).id, removeIDs: remove)
        }
        guard !merges.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }

        let requested = merges.reduce(0) { $0 + $1.removeIDs.count }
        let receipt = history.begin(.copiesMerged, requested: requested, itemIDs: merges.flatMap(\.removeIDs))
        guard let outcomes = await source.merge(merges), !outcomes.isEmpty else {
            history.discard(receipt)
            notices.show(Copy.Notices.nothingRemoved, systemImage: "info.circle")
            return
        }
        let deleted = outcomes.reduce(into: Set<String>()) { $0.formUnion($1.deletedIDs) }
        history.finish(receipt, completed: deleted.count) {
            $0.itemIDs = Array(deleted).sorted()
            $0.payload = try? JSONEncoder().encode(outcomes)
        }
        for outcome in outcomes { ledger.decisions.pin([outcome.keeperID]) }
        await removed(deleted)
        notices.show(Copy.Notices.mergedSets(outcomes.count, copies: deleted.count), systemImage: "square.on.square", undo: Notice.Undo(title: Copy.General.undo) { [weak self] in
            guard let self, let receipt = self.history.receipt(receipt) else { return }
            await self.undoMerge(receipt)
        })
    }

    /// Takes the albums and favorite back off the kept copies. The removed copies are in
    /// Recently Deleted, where only Photos can bring them back.
    public func undoMerge(_ receipt: Receipt) async {
        guard receipt.kind == .copiesMerged, receipt.status != .undone,
              let data = receipt.payload, let outcomes = try? JSONDecoder().decode([MergeOutcome].self, from: data)
        else { return }
        guard await source.undoMerge(outcomes) else {
            notices.show(Copy.Notices.nothingChanged, systemImage: "exclamationmark.triangle")
            return
        }
        history.markUndone(receipt.id)
        notices.show(Copy.Notices.mergeUndone, systemImage: "arrow.uturn.backward")
    }

    public func loadFormats(for group: PhotoGroup) async {
        let missing = group.members.map(\.id).filter { formats[$0] == nil }
        guard !missing.isEmpty else { return }
        let loaded = await source.formats(for: missing)
        formats.merge(loaded) { _, new in new }
    }

    public func relation(of meta: AssetMeta, in group: PhotoGroup) -> CopyRelation {
        CopyRelation.of(meta, keeper: copyKeeper(in: group), formats: formats)
    }

    // MARK: Screenshots and videos

    public func removeScreenshots(_ ids: [String]) async {
        let deleted = await delete(ids, kind: .screenshotsRemoved)
        guard !deleted.isEmpty else { return }
        markedScreenshots.subtract(deleted)
        notices.show(Copy.Notices.removedScreenshots(deleted.count), systemImage: "trash")
    }

    public func removeVideos(_ ids: [String]) async {
        let deleted = await delete(ids, kind: .videosRemoved)
        guard !deleted.isEmpty else { return }
        markedVideos.subtract(deleted)
        notices.show(Copy.Notices.removedVideos(deleted.count), systemImage: "trash")
    }

    /// Takes a video off Big Videos for good. Undo puts it back.
    public func keepVideo(_ id: String) {
        ledger.keptVideoIDs.insert(id)
        saveLedger()
        refresh()
        notices.show("Kept this video.", undo: Notice.Undo(title: Copy.General.undo) { [weak self] in
            guard let self else { return }
            self.ledger.keptVideoIDs.remove(id)
            self.saveLedger()
            self.refresh()
            self.notices.show(Copy.Notices.reviewAgain, systemImage: "arrow.uturn.backward")
        })
    }

    public func video(_ id: String) -> VideoMeta? { videos.first { $0.id == id } ?? allVideos.first { $0.id == id } }

    public func videoURL(for id: String) async -> URL? { await source.videoURL(for: id) }

    private func delete(_ ids: [String], kind: Receipt.Kind) async -> Set<String> {
        guard !ids.isEmpty, !isWorking else { return [] }
        isWorking = true
        defer { isWorking = false }
        let receipt = history.begin(kind, requested: ids.count, itemIDs: ids)
        let deleted = await source.delete(ids)
        guard !deleted.isEmpty else {
            history.discard(receipt)
            notices.show(Copy.Notices.nothingRemoved, systemImage: "info.circle")
            return []
        }
        history.finish(receipt, completed: deleted.count) { $0.itemIDs = ids.filter(deleted.contains) }
        await removed(deleted)
        return deleted
    }

    private func removed(_ deleted: Set<String>) async {
        ledger.decisions.forget(deleted)
        ledger.photosRemoved += deleted.count
        saveLedger()
        removedIDs.formUnion(deleted)
        refresh()
        if let store {
            await store.remove(deleted)
            try? await store.save()
        }
    }

    /// How many of an interrupted receipt's items are still in the library.
    func stillThere(_ receipt: Receipt) async -> Int {
        await source.existing(receipt.itemIDs).count
    }

    // MARK: Saved data

    public func forgetAnalysis() async {
        stopScan()
        let store = await loadStore()
        await store.removeAll()
        try? await store.save()
        thumbnails.removeAllObjects()
        found = PhotoResults(similar: [], copies: [], copiesComplete: false)
        refresh()
        rescan()
        notices.announce(Copy.Notices.analysisCleared)
    }

    // MARK: Images

    public func thumbnail(for id: String, pixelSize: Int) async -> CGImage? {
        let key = "\(id)@\(pixelSize)" as NSString
        if let box = thumbnails.object(forKey: key) { return box.image }
        guard let image = await source.thumbnail(for: id, pixelSize: pixelSize) else { return nil }
        let box = ImageBox(image)
        thumbnails.setObject(box, forKey: key, cost: image.bytesPerRow * image.height)
        thumbnails.setObject(box, forKey: id as NSString, cost: 0)
        return image
    }

    /// The last image loaded for this photo at any size, so a view can draw something at once
    /// while the right size loads.
    func cachedThumbnail(for id: String) -> CGImage? {
        thumbnails.object(forKey: id as NSString)?.image
    }

    private func saveLedger() {
        try? ledgerFile?.save(ledger)
    }
}

final class ImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

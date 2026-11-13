import Accessibility
import CoreGraphics
import Foundation
import TidykeepCore
import Observation
import SwiftUI

public enum AppInfo {
    /// The one place the app's name lives in code. The home-screen name is CFBundleDisplayName.
    public static let name = "Tidykeep"

    public static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
}

@MainActor
@Observable
public final class AppModel {
    public enum Phase: Equatable {
        case launching
        case needsAccess
        case denied
        case ready
    }

    public enum ScanState: Equatable {
        case idle
        case scanning(ScanProgress)
        case paused(ScanProgress)
        case stopped(ScanProgress)
        case finished(ScanProgress, Date)
        case failed(String)

        public var isActive: Bool {
            switch self {
            case .scanning, .paused: true
            default: false
            }
        }
    }

    public private(set) var phase: Phase = .launching
    public private(set) var access: LibraryAccess = .notDetermined
    public private(set) var scanState: ScanState = .idle
    /// Groups to review, newest first. Groups the user kept whole are left out.
    public private(set) var groups: [PhotoGroup] = []
    public private(set) var ledger: ReviewLedger
    public private(set) var isDeleting = false
    public private(set) var scope: ScanScope
    public private(set) var sensitivity: Sensitivity
    /// The latest thing worth telling the user. Also announced to VoiceOver.
    public private(set) var notice: String?

    private let source: any PhotoSource
    private let analyzer: any FrameAnalyzing
    private let directory: URL?
    private let defaults: UserDefaults
    private let conditions: @Sendable () -> DeviceConditions
    private let findsCopies: Bool
    private let ledgerFile: JSONFile<ReviewLedger>?
    private var store: AnalysisStore?
    private var storeTask: Task<AnalysisStore, Never>?
    private var allGroups: [PhotoGroup] = []
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
        defaults: UserDefaults = .standard,
        conditions: @escaping @Sendable () -> DeviceConditions = { .current() },
        findsCopies: Bool = true
    ) {
        self.findsCopies = findsCopies
        self.source = source
        self.analyzer = analyzer
        self.directory = directory
        self.defaults = defaults
        self.conditions = conditions
        self.ledgerFile = directory.map { JSONFile(url: $0.appendingPathComponent("review.json")) }
        self.ledger = ledgerFile?.load() ?? ReviewLedger()
        self.scope = defaults.string(forKey: Keys.scope).flatMap(ScanScope.init) ?? .last12Months
        self.sensitivity = defaults.string(forKey: Keys.sensitivity).flatMap(Sensitivity.init) ?? .balanced
        thumbnails.totalCostLimit = 64 << 20
    }

    enum Keys {
        static let scope = "scanScope"
        static let sensitivity = "sensitivity"
    }

    // MARK: Access

    public func start() async {
        access = await source.access()
        route()
    }

    public func requestAccess() async {
        access = await source.requestAccess()
        route()
    }

    /// Limited access only: the user picks which photos the app can see, then it checks again.
    public func chooseMorePhotos() async {
        await source.chooseMorePhotos()
        rescan()
    }

    private func route() {
        switch access {
        case .notDetermined: phase = .needsAccess
        case .denied: phase = .denied
        case .limited, .full:
            phase = .ready
            observeLibraryChanges()
            if scanTask == nil { rescan() }
        }
    }

    // MARK: Scanning

    public func rescan() {
        scanTask?.cancel()
        removedIDs = []
        // Show the new scan straight away rather than the last one's result until it starts.
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

    public func setScope(_ scope: ScanScope) {
        guard scope != self.scope else { return }
        self.scope = scope
        defaults.set(scope.rawValue, forKey: Keys.scope)
        rescan()
    }

    public func setSensitivity(_ sensitivity: Sensitivity) {
        guard sensitivity != self.sensitivity else { return }
        self.sensitivity = sensitivity
        defaults.set(sensitivity.rawValue, forKey: Keys.sensitivity)
        rescan()
    }

    private func runScan() async {
        let store = await loadStore()
        let scanner = Scanner(source: source, analyzer: analyzer, store: store, conditions: conditions, findsCopies: findsCopies)
        var progress = ScanProgress()
        scanState = .scanning(progress)
        do {
            for try await event in scanner.scan(scope: scope, config: sensitivity.config) {
                guard !Task.isCancelled else { return }
                switch event {
                case .progress(let p):
                    progress = p
                    scanState = .scanning(p)
                case .paused:
                    // The scanner repeats this while the phone stays hot; say it once.
                    if case .paused = scanState {} else { announce("Paused while your phone cools down.") }
                    scanState = .paused(progress)
                case .results(let found):
                    show(found.similar)
                case .library:
                    break
                case .finished(let p):
                    let now = Date()
                    ledger.lastScan = now
                    saveLedger()
                    scanState = .finished(p, now)
                    announce(Copy.scanDone(groups: groups.count, extras: suggestedRemovalCount))
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            let message = "Couldn't read your photo library. Try again in a moment."
            scanState = .failed(message)
            announce(message)
        }
    }

    /// Loads the cache once, however many scans ask for it at the same time.
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

    private func show(_ found: [PhotoGroup]) {
        allGroups = found.filter { !$0.members.contains { removedIDs.contains($0.id) } }
        groups = allGroups.filter { !ledger.dismissedGroups.contains($0.id) }
    }

    // MARK: Library changes

    private func observeLibraryChanges() {
        guard changeTask == nil else { return }
        let stream = source.changes()
        changeTask = Task { [weak self] in
            for await _ in stream { self?.libraryChanged = true }
        }
    }

    /// Stops a scan in the background and picks it up on return. Rescans on return (say, from
    /// Photos) if the library changed. Not on every activation: the delete confirmation alert
    /// also deactivates the app.
    public func scenePhaseChanged(to phase: ScenePhase) {
        switch phase {
        case .background:
            wasInBackground = true
            // iOS doesn't let background apps use the GPU, which Vision and the softening need.
            if scanState.isActive {
                stopScan()
                resumeOnActive = true
            }
            if let store { Task { try? await store.save() } }
        case .active:
            if wasInBackground, self.phase == .ready, resumeOnActive || (libraryChanged && !scanState.isActive) {
                resumeOnActive = false
                libraryChanged = false
                rescan()
            }
            wasInBackground = false
        default:
            break
        }
    }

    // MARK: Review

    public func group(_ id: String) -> PhotoGroup? { groups.first { $0.id == id } }

    public func isKept(_ id: String, in group: PhotoGroup) -> Bool {
        ledger.decisions.keeps(id, in: group)
    }

    public func removals(in group: PhotoGroup) -> [AssetMeta] {
        ledger.decisions.removals(in: group)
    }

    public var suggestedRemovalCount: Int {
        groups.reduce(0) { $0 + removals(in: $1).count }
    }

    public func setKeep(_ keep: Bool, _ id: String, in group: PhotoGroup) {
        switch ledger.decisions.setKeep(keep, id, in: group) {
        case .protected?:
            tell("Favorites, edited photos and documents are always kept.")
        case .lastKept?:
            tell("Each group keeps at least one photo.")
        case nil:
            saveLedger()
            announce("\(keep ? "Keeping it" : "Marked for removal"). \(Copy.tally(group, removing: removals(in: group).count))")
        }
    }

    public func keepOnly(_ id: String, in group: PhotoGroup) {
        ledger.decisions.keepOnly(id, in: group)
        saveLedger()
        announce("Keeping only \(Copy.photoNumber(id, in: group)). \(Copy.tally(group, removing: removals(in: group).count))")
    }

    /// "Keep all": hide this group for good (until a new photo joins it).
    public func keepAll(_ group: PhotoGroup) {
        ledger.dismissedGroups.insert(group.id)
        saveLedger()
        show(allGroups)
        tell("Kept all \(Copy.photos(group.members.count)).")
    }

    public func restoreKeptGroups() {
        ledger.dismissedGroups.removeAll()
        saveLedger()
        show(allGroups)
        announce("Groups you kept are back in the list.")
    }

    public func removeSuggested(in group: PhotoGroup) async {
        await remove(removals(in: group).map(\.id))
    }

    public func removeAllSuggested() async {
        await remove(groups.flatMap { removals(in: $0).map(\.id) })
    }

    private func remove(_ ids: [String]) async {
        guard !ids.isEmpty, !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }

        // The groups as the user saw them; a scan may replace them while iOS asks to confirm.
        let requested = Set(ids)
        let touched = allGroups.filter { $0.members.contains { requested.contains($0.id) } }

        // If every photo a group would keep was deleted in Photos since the scan, leave the
        // rest of it alone, so a moment is never removed entirely.
        let present = await source.existing(touched.flatMap { $0.members.map(\.id) })
        let safe = touched
            .filter { !ledger.decisions.keptIDs(in: $0).isDisjoint(with: present) }
            .flatMap { $0.members.map(\.id).filter(requested.contains) }

        let deleted = safe.isEmpty ? [] : await source.delete(safe)
        guard !deleted.isEmpty else {
            tell("Nothing was removed.")
            return
        }

        // A group the user just cleaned is done. What's left of it is kept and remembered as
        // reviewed, so it doesn't come back on the next scan, even grouped differently.
        for group in touched where group.members.contains(where: { deleted.contains($0.id) }) {
            let left = group.members.map(\.id).filter { !deleted.contains($0) }
            ledger.decisions.pin(left)
            if left.count >= 2 { ledger.dismissedGroups.insert(Fingerprint.of(left)) }
        }
        ledger.decisions.forget(deleted)
        ledger.photosRemoved += deleted.count
        saveLedger()

        removedIDs.formUnion(deleted)
        if let store {
            await store.remove(deleted)
        }
        show(allGroups)
        if let store {
            try? await store.save()
        }
        tell("Removed \(Copy.photos(deleted.count)). They're in Recently Deleted in Photos for 30 days.")
    }

    // MARK: Settings

    public func forgetAnalysis() async {
        stopScan()
        let store = await loadStore()
        await store.removeAll()
        try? await store.save()
        thumbnails.removeAllObjects()
        allGroups = []
        groups = []
        rescan()
        announce("Saved analysis cleared. Checking your photos again.")
    }

    // MARK: Images

    public func thumbnail(for id: String, pixelSize: Int) async -> CGImage? {
        let key = "\(id)@\(pixelSize)" as NSString
        if let box = thumbnails.object(forKey: key) { return box.image }
        guard let image = await source.thumbnail(for: id, pixelSize: pixelSize) else { return nil }
        thumbnails.setObject(ImageBox(image), forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    // MARK: Notices

    public func clearNotice() { notice = nil }

    /// Shows a banner and says it. High priority, so the screen change that often follows
    /// (a group closing after Remove) doesn't cut it off.
    private func tell(_ message: String) {
        notice = message
        announce(message, priority: .high)
    }

    /// Says something to VoiceOver without a banner, for changes the screen already shows.
    private func announce(_ message: String, priority: AnnouncementPriority = .default) {
        var spoken = AttributedString(message)
        spoken.accessibilitySpeechAnnouncementPriority = priority
        AccessibilityNotification.Announcement(spoken).post()
    }

    private func saveLedger() {
        try? ledgerFile?.save(ledger)
    }
}


final class ImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

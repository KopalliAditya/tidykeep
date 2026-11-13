import CoreGraphics
import Foundation

public struct ScanProgress: Sendable, Equatable {
    /// Photos in the chosen time range, screenshots included.
    public var photosInRange = 0
    /// Photos that needed analysis this run (not cached).
    public var toAnalyze = 0
    public var analyzed = 0
    /// Photos that couldn't be read. `skippedInCloud` of them are only in iCloud.
    public var skipped = 0
    public var skippedInCloud = 0

    public init() {}

    public var fraction: Double { toAnalyze == 0 ? 1 : Double(analyzed + skipped) / Double(toAnalyze) }
    /// Photos in range that have been looked at, this run or before.
    public var checked: Int { photosInRange - (toAnalyze - analyzed) }
}

/// What a check found so far.
public struct PhotoResults: Sendable, Equatable {
    /// Series and near-identical frames of one moment, newest first.
    public var similar: [PhotoGroup] = []
    /// Copy sets spread over time, newest first.
    public var copies: [PhotoGroup] = []
    /// False until every photo has been analyzed, so more copies may still turn up.
    public var copiesComplete = false

    public init(similar: [PhotoGroup] = [], copies: [PhotoGroup] = [], copiesComplete: Bool = false) {
        self.similar = similar
        self.copies = copies
        self.copiesComplete = copiesComplete
    }
}

public enum ScanEvent: Sendable {
    case progress(ScanProgress)
    /// The phone is too hot; scanning resumes on its own once it cools.
    case paused
    /// Every photo in range, oldest first, as soon as the library is read. Screenshots are
    /// listed from this, without waiting for analysis.
    case library([AssetMeta])
    /// Everything found so far. Sent as the scan goes: similar shots first, copies once the
    /// photos close in time are done.
    case results(PhotoResults)
    case finished(ScanProgress)
}

/// Finds and ranks groups in a library, analyzing only what the cache lacks.
public final class Scanner: Sendable {
    public static let analysisPixelSize = 1024
    static let groupsEvery = 60

    let source: any PhotoSource
    let analyzer: any FrameAnalyzing
    let store: AnalysisStore
    let conditions: @Sendable () -> DeviceConditions
    let pauseInterval: Duration
    let findsCopies: Bool

    public init(
        source: any PhotoSource,
        analyzer: any FrameAnalyzing,
        store: AnalysisStore,
        conditions: @escaping @Sendable () -> DeviceConditions = { .current() },
        pauseInterval: Duration = .seconds(3),
        findsCopies: Bool = true
    ) {
        self.source = source
        self.analyzer = analyzer
        self.store = store
        self.conditions = conditions
        self.pauseInterval = pauseInterval
        self.findsCopies = findsCopies
    }

    public func scan(scope: ScanScope, config: GroupingConfig, now: Date = Date()) -> AsyncThrowingStream<ScanEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(scope: scope, config: config, now: now) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        scope: ScanScope,
        config: GroupingConfig,
        now: Date,
        emit: @Sendable (ScanEvent) -> Void
    ) async throws {
        let metas = try await source.fetchAssets(since: scope.startDate(now: now))
        if scope == .everything {
            await store.retainOnly(Set(metas.map(\.id)))
        }
        emit(.library(metas))

        // Phase 1 is the photos with a neighbour close in time, newest first, so recent similar
        // shots show up first. Screenshots never form a series. Phase 2 is everything else,
        // which only the copy pass needs.
        let candidates = SeriesBuilder.candidates(metas.filter { !$0.isScreenshot }, maxGap: config.maxGap)
        let candidateIDs = Set(candidates.map(\.id))
        var pending: [AssetMeta] = []
        for meta in candidates.reversed() where await store.signals(for: meta) == nil {
            pending.append(meta)
        }
        let firstPhase = pending.count
        for meta in metas.reversed() where !candidateIDs.contains(meta.id) {
            if await store.signals(for: meta) == nil { pending.append(meta) }
        }

        var progress = ScanProgress()
        progress.photosInRange = metas.count
        progress.toAnalyze = pending.count
        emit(.progress(progress))

        var grouping = Grouping(metas: metas, candidates: candidates, config: config, findsCopies: findsCopies)
        if pending.count < metas.count {
            emit(.results(try await grouping.results(from: store, withCopies: firstPhase == 0, complete: pending.isEmpty)))
        }

        var queue = pending[...]
        // Groups are rebuilt from the whole cache and the cache is written whole, so both
        // happen less often as the scan goes on. Otherwise a big library costs O(n²).
        var nextFlush = Self.groupsEvery
        var phaseOneReported = firstPhase == 0
        try await withThrowingTaskGroup(of: Analyzed.self) { group in
            var inFlight = 0
            while true {
                var limit = ScanGovernor.concurrency(for: conditions())
                var paused = false
                while limit == 0 && inFlight == 0 && !queue.isEmpty {
                    emit(.paused)
                    paused = true
                    try await Task.sleep(for: pauseInterval)
                    limit = ScanGovernor.concurrency(for: conditions())
                }
                if paused { emit(.progress(progress)) }
                while inFlight < limit, let meta = queue.popFirst() {
                    group.addTask { [source, analyzer] in
                        try Task.checkCancellation()
                        do {
                            let image = try await source.analysisImage(for: meta.id, maxPixelSize: Self.analysisPixelSize)
                            let signals = try await analyzer.analyze(image)
                            // Vision may cut a cancelled request short; don't trust what came back.
                            try Task.checkCancellation()
                            return Analyzed(meta: meta, signals: signals)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch PhotoSourceError.notAvailableLocally {
                            return Analyzed(meta: meta, signals: nil, inCloud: true)
                        } catch {
                            return Analyzed(meta: meta, signals: nil)
                        }
                    }
                    inFlight += 1
                }
                guard let result = try await group.next() else { break }
                inFlight -= 1

                try Task.checkCancellation()
                if let signals = result.signals {
                    await store.put(signals, for: result.meta)
                    progress.analyzed += 1
                } else {
                    progress.skipped += 1
                    if result.inCloud { progress.skippedInCloud += 1 }
                }
                let done = progress.analyzed + progress.skipped
                if done % 10 == 0 { emit(.progress(progress)) }
                let phaseOneDone = done >= firstPhase
                if done >= nextFlush || (phaseOneDone && !phaseOneReported) {
                    nextFlush = done + max(Self.groupsEvery, done / 4)
                    phaseOneReported = phaseOneReported || phaseOneDone
                    try? await store.save()
                    emit(.results(try await grouping.results(from: store, withCopies: phaseOneDone, complete: false)))
                }
            }
        }

        try? await store.save()
        emit(.progress(progress))
        emit(.results(try await grouping.results(from: store, withCopies: true, complete: true)))
        emit(.finished(progress))
    }
}

private struct Analyzed: Sendable {
    let meta: AssetMeta
    let signals: FrameSignals?
    var inCloud = false
}

/// Builds results from whatever the cache holds. The copy pass looks at every photo, so until
/// phase 1 is done it is skipped and the last copy clusters are reused.
struct Grouping {
    let metas: [AssetMeta]
    let candidates: [AssetMeta]
    let config: GroupingConfig
    let findsCopies: Bool
    private var clusters: [[AssetMeta]] = []

    init(metas: [AssetMeta], candidates: [AssetMeta], config: GroupingConfig, findsCopies: Bool) {
        self.metas = metas
        self.candidates = candidates
        self.config = config
        self.findsCopies = findsCopies
    }

    /// Groups where some photo could go. Series where every photo is always kept (all
    /// favorites, or all pages of a document) are left out, as are copy sets that would only
    /// ever say "keep all".
    ///
    /// Document-like photos still join groups, but only as photos that are always kept.
    /// Leaving them out instead would be worse: Vision sometimes calls the sharp frame of a
    /// plain-background shot a document and its blurred copies not, so the best frame would
    /// drop out of its own group.
    mutating func results(from store: AnalysisStore, withCopies: Bool, complete: Bool) async throws -> PhotoResults {
        var signals: [String: FrameSignals] = [:]
        for meta in metas {
            if let s = await store.signals(for: meta) { signals[meta.id] = s }
        }
        try Task.checkCancellation()
        let analyzed = candidates.compactMap { meta in signals[meta.id].map { SeriesBuilder.Item(meta: meta, signals: $0) } }
        let series = SeriesBuilder.build(analyzed, config: config)
            .filter { group in !group.allSatisfy { $0.isProtected || signals[$0.id]?.isUtility == true } }
        if withCopies && findsCopies {
            clusters = CopyFinder.clusters(metas.compactMap { meta in signals[meta.id].map { CopyFinder.Item(meta: meta, signals: $0) } })
        }
        try Task.checkCancellation()
        let library = LibraryGroups.combine(series: series, copyClusters: clusters, maxSpan: config.maxSpan)
        func members(_ group: [AssetMeta]) -> [(meta: AssetMeta, signals: FrameSignals)] {
            group.compactMap { meta in signals[meta.id].map { (meta, $0) } }
        }
        let similar = (library.series + library.similarShots)
            .map { PhotoGroup(members: members($0)) }
            .filter { !$0.isFullyProtected }
        let copies = library.copies
            .map { PhotoGroup(copies: members($0)) }
            .filter { $0.hasSuggestions }
        return PhotoResults(
            similar: similar.sorted { $0.startDate > $1.startDate },
            copies: copies.sorted { $0.startDate > $1.startDate },
            copiesComplete: complete
        )
    }
}

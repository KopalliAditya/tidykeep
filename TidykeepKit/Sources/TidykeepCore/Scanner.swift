import CoreGraphics
import Foundation

public struct ScanProgress: Sendable, Equatable {
    /// Photos in the chosen time range.
    public var photosInRange = 0
    /// Photos that needed analysis this run (not cached, and close in time to another photo).
    public var toAnalyze = 0
    public var analyzed = 0
    /// Photos that couldn't be read, usually because they're only in iCloud.
    public var skipped = 0

    public init() {}

    public var fraction: Double { toAnalyze == 0 ? 1 : Double(analyzed + skipped) / Double(toAnalyze) }
}

public enum ScanEvent: Sendable {
    case progress(ScanProgress)
    /// The phone is too hot; scanning resumes on its own once it cools.
    case paused
    /// Every group found so far. Sent as the scan goes, newest photos first.
    case groups([PhotoGroup])
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

    public init(
        source: any PhotoSource,
        analyzer: any FrameAnalyzing,
        store: AnalysisStore,
        conditions: @escaping @Sendable () -> DeviceConditions = { .current() },
        pauseInterval: Duration = .seconds(3)
    ) {
        self.source = source
        self.analyzer = analyzer
        self.store = store
        self.conditions = conditions
        self.pauseInterval = pauseInterval
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

        let candidates = SeriesBuilder.candidates(metas, maxGap: config.maxGap)
        var pending: [AssetMeta] = []
        for meta in candidates.reversed() {  // newest first, so recent groups show up first
            if await store.signals(for: meta) == nil { pending.append(meta) }
        }

        var progress = ScanProgress()
        progress.photosInRange = metas.count
        progress.toAnalyze = pending.count
        emit(.progress(progress))
        if pending.count < candidates.count {
            emit(.groups(try await groups(from: candidates, config: config)))
        }

        var queue = pending[...]
        // Groups are rebuilt from the whole cache and the cache is written whole, so both
        // happen less often as the scan goes on. Otherwise a big library costs O(n²).
        var nextFlush = Self.groupsEvery
        try await withThrowingTaskGroup(of: (AssetMeta, FrameSignals?).self) { group in
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
                            return (meta, signals)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            return (meta, nil)
                        }
                    }
                    inFlight += 1
                }
                guard let (meta, signals) = try await group.next() else { break }
                inFlight -= 1

                try Task.checkCancellation()
                if let signals {
                    await store.put(signals, for: meta)
                    progress.analyzed += 1
                } else {
                    progress.skipped += 1
                }
                let done = progress.analyzed + progress.skipped
                if done % 10 == 0 { emit(.progress(progress)) }
                if done >= nextFlush {
                    nextFlush = done + max(Self.groupsEvery, done / 4)
                    try? await store.save()
                    emit(.groups(try await groups(from: candidates, config: config)))
                }
            }
        }

        try? await store.save()
        emit(.progress(progress))
        emit(.groups(try await groups(from: candidates, config: config)))
        emit(.finished(progress))
    }

    /// Groups among the candidates analyzed so far, leaving out groups where every photo is
    /// always kept (all favorites, or all pages of a document).
    ///
    /// Document-like photos still join groups, but only as photos that are always kept.
    /// Leaving them out instead would be worse: Vision sometimes calls the sharp frame of a
    /// plain-background shot a document and its blurred copies not, so the best frame would
    /// drop out of its own group.
    func groups(from candidates: [AssetMeta], config: GroupingConfig) async throws -> [PhotoGroup] {
        var analyzed: [(meta: AssetMeta, signals: FrameSignals)] = []
        for meta in candidates {
            if let signals = await store.signals(for: meta) { analyzed.append((meta, signals)) }
        }
        try Task.checkCancellation()
        let signalsByID = Dictionary(uniqueKeysWithValues: analyzed.map { ($0.meta.id, $0.signals) })
        let series = SeriesBuilder.build(analyzed.map { .init(meta: $0.meta, embedding: $0.signals.embedding) }, config: config)
        return series
            .map { members in PhotoGroup(members: members.map { ($0, signalsByID[$0.id]!) }) }
            .filter { !$0.isFullyProtected }
            .sorted { $0.startDate > $1.startDate }
    }
}

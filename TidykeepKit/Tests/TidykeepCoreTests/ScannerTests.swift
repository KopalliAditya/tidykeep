import Foundation
@testable import TidykeepCore
import Synchronization
import Testing

@Suite struct ScannerTests {
    /// A moment shot three times (one sharp), another shot twice, a different scene seconds
    /// after the first, and an old photo with nothing near it in time.
    func library(unreadable: Set<String> = []) -> FakeLibrary {
        FakeLibrary([
            (meta("a1", 0), signals(scene(0), sharpness: 3)),
            (meta("a2", 2), signals(scene(0, nudge: 0.05), sharpness: 7)),
            (meta("a3", 4), signals(scene(0, nudge: 0.1), sharpness: 2)),
            (meta("other", 10), signals(scene(6))),
            (meta("b1", 3_600), signals(scene(3), sharpness: 6)),
            (meta("b2", 3_603), signals(scene(3, nudge: 0.05), sharpness: 4)),
            (meta("alone", -100_000), signals(scene(9))),
        ], unreadable: unreadable)
    }

    struct Result {
        var events: [ScanEvent] = []
        var groups: [PhotoGroup] { events.reduce(into: []) { if case .groups(let g) = $1 { $0 = g } } }
        var finished: ScanProgress? { events.compactMap { if case .finished(let p) = $0 { p } else { nil } }.last }
        var paused: Bool { events.contains { if case .paused = $0 { true } else { false } } }
    }

    func scan(
        _ source: FakeLibrary, analyzer: FakeAnalyzer? = nil, store: AnalysisStore? = nil, scope: ScanScope = .everything,
        now: Date = t0, conditions: @escaping @Sendable () -> DeviceConditions = { DeviceConditions(thermal: .nominal, lowPowerMode: false) }
    ) async throws -> Result {
        let analyzer = analyzer ?? FakeAnalyzer(source)
        let scanner = Scanner(
            source: source, analyzer: analyzer, store: store ?? AnalysisStore(url: nil, analyzerVersion: analyzer.version),
            conditions: conditions, pauseInterval: .milliseconds(5)
        )
        var result = Result()
        for try await event in scanner.scan(scope: scope, config: Sensitivity.balanced.config, now: now) {
            result.events.append(event)
        }
        return result
    }

    @Test func findsAndRanksGroups() async throws {
        let source = library()
        let analyzer = FakeAnalyzer(source)
        let result = try await scan(source, analyzer: analyzer)
        #expect(result.groups.map { $0.members.map(\.id) } == [["b1", "b2"], ["a2", "a1", "a3"]])
        #expect(result.groups.last?.keeper.id == "a2")
        // "alone" has nothing near it in time, so it's never analyzed.
        #expect(analyzer.callCount == 6)
        #expect(result.finished?.photosInRange == 7)
        #expect(result.finished?.analyzed == 6)
    }

    @Test func aSecondScanUsesTheCache() async throws {
        let source = library()
        let analyzer = FakeAnalyzer(source)
        let store = AnalysisStore(url: nil, analyzerVersion: analyzer.version)
        let first = try await scan(source, analyzer: analyzer, store: store)
        let second = try await scan(source, analyzer: analyzer, store: store)
        #expect(analyzer.callCount == 6)
        #expect(second.finished?.toAnalyze == 0)
        #expect(second.groups.map(\.id) == first.groups.map(\.id))
    }

    @Test func anEditedPhotoIsAnalyzedAgain() async throws {
        let source = library()
        let analyzer = FakeAnalyzer(source)
        let store = AnalysisStore(url: nil, analyzerVersion: analyzer.version)
        _ = try await scan(source, analyzer: analyzer, store: store)
        source.replace("a3", with: meta("a3", 4, edited: true, version: t0.addingTimeInterval(99)))
        let second = try await scan(source, analyzer: analyzer, store: store)
        #expect(analyzer.callCount == 7)
        #expect(second.finished?.toAnalyze == 1)
    }

    @Test func photosOnlyInICloudAreSkipped() async throws {
        let result = try await scan(library(unreadable: ["a1", "b2"]))
        #expect(result.finished?.skipped == 2)
        #expect(result.groups.map { Set($0.members.map(\.id)) } == [["a2", "a3"]])
    }

    @Test func pagesOfADocumentAreNotAGroupToReview() async throws {
        let pages = FakeLibrary([
            (meta("page1", 0), signals(scene(0), utility: true)),
            (meta("page2", 5), signals(scene(0, nudge: 0.02), utility: true)),
            (meta("page3", 10), signals(scene(0, nudge: 0.04), utility: true)),
        ])
        #expect(try await scan(pages).groups.isEmpty)
    }

    /// From real photos: Vision called the sharp frame of a guitar on a plain background a
    /// document, and the blurred frames not. The sharp frame must stay in its group, kept.
    @Test func aDocumentLikeFrameStaysInItsGroupAndIsKept() async throws {
        let shots = FakeLibrary([
            (meta("sharp", 0), signals(scene(0), sharpness: 7.2, utility: true)),
            (meta("blurred", 3), signals(scene(0, nudge: 0.1), sharpness: 4.6)),
        ])
        let group = try #require(try await scan(shots).groups.first)
        #expect(group.keeper.id == "sharp")
        #expect(group.isProtected("sharp"))
        #expect(ReviewDecisions().removals(in: group).map(\.id) == ["blurred"])
    }

    @Test func allFavoritesIsNotAGroupToReview() async throws {
        let loved = FakeLibrary([
            (meta("a", 0, favorite: true), signals(scene(0))),
            (meta("b", 2, favorite: true), signals(scene(0, nudge: 0.05))),
        ])
        #expect(try await scan(loved).groups.isEmpty)
    }

    @Test func pausesWhenThePhoneIsHotAndCarriesOn() async throws {
        let checks = Mutex(0)
        let result = try await scan(library()) {
            let n = checks.withLock { $0 += 1; return $0 }
            return DeviceConditions(thermal: n <= 3 ? .critical : .nominal, lowPowerMode: false)
        }
        #expect(result.paused)
        #expect(result.groups.count == 2)
    }

    @Test func scopeLeavesOutOlderPhotos() async throws {
        let result = try await scan(library(), scope: .last30Days, now: t0.addingTimeInterval(31 * 86_400))
        #expect(result.finished?.photosInRange == 0)
        #expect(result.groups.isEmpty)
    }

    @Test func aFullScanForgetsDeletedPhotos() async throws {
        let source = library()
        let analyzer = FakeAnalyzer(source)
        let store = AnalysisStore(url: nil, analyzerVersion: analyzer.version)
        _ = try await scan(source, analyzer: analyzer, store: store)
        _ = await source.delete(["a3", "other"])
        _ = try await scan(source, analyzer: analyzer, store: store)
        #expect(await store.count == 4)
    }

    @Test func showsCachedGroupsBeforeAnalyzingNewPhotos() async throws {
        let source = library()
        let analyzer = FakeAnalyzer(source)
        let store = AnalysisStore(url: nil, analyzerVersion: analyzer.version)
        _ = try await scan(source, analyzer: analyzer, store: store)
        source.replace("b2", with: meta("b2", 3_603, version: t0))
        let second = try await scan(source, analyzer: analyzer, store: store)
        // The first groups event arrives before any progress beyond the start.
        let firstGroups = second.events.firstIndex { if case .groups = $0 { true } else { false } }
        let firstAnalyzed = second.events.firstIndex { if case .progress(let p) = $0 { p.analyzed > 0 } else { false } }
        #expect(firstGroups != nil)
        #expect(firstAnalyzed == nil || firstGroups! < firstAnalyzed!)
    }

    @Test func stopsWhenCancelled() async throws {
        let source = library()
        let analyzer = FakeAnalyzer(source)
        let scanner = Scanner(source: source, analyzer: analyzer, store: AnalysisStore(url: nil, analyzerVersion: "x"),
                              conditions: { DeviceConditions(thermal: .critical, lowPowerMode: false) }, pauseInterval: .milliseconds(5))
        let task = Task {
            var events = 0
            for try await _ in scanner.scan(scope: .everything, config: Sensitivity.balanced.config, now: t0) { events += 1 }
            return events
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        _ = try? await task.value
        #expect(analyzer.callCount == 0)
    }
}

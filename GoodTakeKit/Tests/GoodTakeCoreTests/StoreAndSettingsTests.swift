import Foundation
@testable import GoodTakeCore
import Testing

@Suite struct AnalysisStoreTests {
    @Test func savesAndLoads() async throws {
        let url = temporaryDirectory().appendingPathComponent("analysis.plist")
        let store = AnalysisStore(url: url, analyzerVersion: "v1")
        let photo = meta("a", 0)
        await store.put(signals(sharpness: 3), for: photo)
        try await store.save()

        let reopened = AnalysisStore(url: url, analyzerVersion: "v1")
        #expect(await reopened.signals(for: photo) == signals(sharpness: 3))
    }

    @Test func anEditedPhotoIsAnalyzedAgain() async {
        let store = AnalysisStore(url: nil, analyzerVersion: "v1")
        await store.put(signals(), for: meta("a", 0, version: nil))
        #expect(await store.signals(for: meta("a", 0, version: nil)) != nil)
        #expect(await store.signals(for: meta("a", 0, version: t0)) == nil)
    }

    @Test func aNewAnalyzerVersionStartsFresh() async throws {
        let url = temporaryDirectory().appendingPathComponent("analysis.plist")
        let store = AnalysisStore(url: url, analyzerVersion: "v1")
        await store.put(signals(), for: meta("a", 0))
        try await store.save()

        let upgraded = AnalysisStore(url: url, analyzerVersion: "v2")
        #expect(await upgraded.count == 0)
    }

    @Test func aDamagedFileStartsFresh() async throws {
        let url = temporaryDirectory().appendingPathComponent("analysis.plist")
        try Data("not a plist".utf8).write(to: url)
        #expect(await AnalysisStore(url: url, analyzerVersion: "v1").count == 0)
    }

    @Test func retainOnlyDropsPhotosThatAreGone() async {
        let store = AnalysisStore(url: nil, analyzerVersion: "v1")
        for id in ["a", "b", "c"] { await store.put(signals(), for: meta(id, 0)) }
        await store.retainOnly(["b"])
        #expect(await store.count == 1)
        #expect(await store.signals(for: meta("b", 0)) != nil)
        await store.remove(["b"])
        #expect(await store.count == 0)
    }

    @Test func jsonFileRoundTrips() throws {
        let file = JSONFile<ReviewLedger>(url: temporaryDirectory().appendingPathComponent("nested/review.json"))
        #expect(file.load() == nil)
        var ledger = ReviewLedger()
        ledger.photosRemoved = 3
        try file.save(ledger)
        #expect(file.load() == ledger)
    }
}

@Suite struct FingerprintTests {
    @Test func ignoresOrder() {
        #expect(Fingerprint.of(["a", "b", "c"]) == Fingerprint.of(["c", "a", "b"]))
    }

    @Test func differsForDifferentSets() {
        #expect(Fingerprint.of(["a", "b"]) != Fingerprint.of(["a", "b", "c"]))
        // The separator keeps ["ab", "c"] and ["a", "bc"] apart.
        #expect(Fingerprint.of(["ab", "c"]) != Fingerprint.of(["a", "bc"]))
    }

    /// Fingerprints are saved (dismissed groups), so they must never change between versions.
    @Test func isStableAcrossReleases() {
        #expect(Fingerprint.of([]) == "cbf29ce484222325")
        #expect(Fingerprint.of(["a"]) == "af63dc4c8601ec8c")
    }
}

@Suite struct ScanGovernorTests {
    @Test(arguments: [
        (ProcessInfo.ThermalState.nominal, false, 3),
        (.fair, false, 2),
        (.serious, false, 1),
        (.critical, false, 0),
        (.nominal, true, 1),
        (.critical, true, 0),
    ])
    func backsOffAsThePhoneWarms(thermal: ProcessInfo.ThermalState, lowPower: Bool, expected: Int) {
        #expect(ScanGovernor.concurrency(for: DeviceConditions(thermal: thermal, lowPowerMode: lowPower)) == expected)
    }
}

@Suite struct ScopeTests {
    @Test func startDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_793_836_800)  // 2026-11-05
        #expect(ScanScope.everything.startDate(now: now, calendar: calendar) == nil)
        #expect(ScanScope.last30Days.startDate(now: now, calendar: calendar) == now.addingTimeInterval(-30 * 86_400))
        let year = ScanScope.last12Months.startDate(now: now, calendar: calendar)!
        #expect(calendar.dateComponents([.year, .month, .day], from: year) == DateComponents(year: 2025, month: 11, day: 5))
    }

    @Test func accessCanRead() {
        #expect(LibraryAccess.full.canRead)
        #expect(LibraryAccess.limited.canRead)
        #expect(!LibraryAccess.denied.canRead)
        #expect(!LibraryAccess.notDetermined.canRead)
    }

    @Test func protectedMeansFavoriteOrEdited() {
        #expect(meta("a", 0, favorite: true).isProtected)
        #expect(meta("a", 0, edited: true).isProtected)
        #expect(!meta("a", 0).isProtected)
    }
}

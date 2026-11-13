import Foundation
@testable import GoodTakeCore
import Testing

@Suite struct ReviewDecisionsTests {
    /// keeper "best", then "ok", "meh"; "fav" is a favorite that ranks low unless favorites win.
    let plain = group([
        (meta("meh", 0), signals(sharpness: 2)),
        (meta("best", 1), signals(sharpness: 8)),
        (meta("ok", 2), signals(sharpness: 5)),
    ])

    @Test func byDefaultKeepsTheKeeperAndSuggestsTheRest() {
        let d = ReviewDecisions()
        #expect(d.keptIDs(in: plain) == ["best"])
        #expect(d.removals(in: plain).map(\.id) == ["ok", "meh"])
    }

    @Test func protectedPhotosAreAlwaysKept() {
        let g = group([
            (meta("best", 0), signals(sharpness: 8)),
            (meta("edited", 1, edited: true), signals(sharpness: 2)),
            (meta("other", 2), signals(sharpness: 3)),
        ])
        var d = ReviewDecisions()
        #expect(d.keptIDs(in: g) == ["best", "edited"])
        #expect(d.setKeep(false, "edited", in: g) == .protected)
        d.keepOnly("other", in: g)
        #expect(d.keptIDs(in: g) == ["other", "edited"])
    }

    @Test func documentsAreAlwaysKept() {
        let g = group([
            (meta("photo", 0), signals(sharpness: 8)),
            (meta("page", 1), signals(sharpness: 2, utility: true)),
            (meta("blurry", 2), signals(sharpness: 1)),
        ])
        var d = ReviewDecisions()
        #expect(g.documentIDs == ["page"])
        #expect(d.keptIDs(in: g) == ["photo", "page"])
        #expect(d.setKeep(false, "page", in: g) == .protected)
        d.keepOnly("blurry", in: g)
        #expect(d.keptIDs(in: g) == ["blurry", "page"])
        #expect(!g.isFullyProtected)
    }

    @Test func theLastKeptPhotoCantBeRemoved() {
        var d = ReviewDecisions()
        #expect(d.setKeep(false, "best", in: plain) == .lastKept)
        #expect(d.keptIDs(in: plain) == ["best"])
        #expect(d.setKeep(true, "ok", in: plain) == nil)
        #expect(d.setKeep(false, "best", in: plain) == nil)
        #expect(d.keptIDs(in: plain) == ["ok"])
    }

    @Test func keepOnlyKeepsOne() {
        var d = ReviewDecisions()
        d.keepOnly("meh", in: plain)
        #expect(d.keptIDs(in: plain) == ["meh"])
        #expect(d.removals(in: plain).map(\.id) == ["best", "ok"])
    }

    @Test func choicesFollowPhotosIntoReshapedGroups() {
        var d = ReviewDecisions()
        d.setKeep(true, "ok", in: plain)
        // A rescan drops "meh" and adds a new photo; "ok" is still kept.
        let reshaped = group([
            (meta("best", 1), signals(sharpness: 8)),
            (meta("ok", 2), signals(sharpness: 5)),
            (meta("new", 3), signals(sharpness: 1)),
        ])
        #expect(d.keptIDs(in: reshaped) == ["best", "ok"])
    }

    @Test func aGroupNeverEndsUpWithNothingKept() {
        var d = ReviewDecisions()
        d.setKeep(true, "ok", in: plain)
        d.setKeep(false, "best", in: plain)
        // "ok" is deleted elsewhere; the group re-forms without it.
        let without = group([(meta("meh", 0), signals(sharpness: 2)), (meta("best", 1), signals(sharpness: 8))])
        #expect(d.keptIDs(in: without) == ["best"])
    }

    @Test func forgetDropsChoices() {
        var d = ReviewDecisions()
        d.setKeep(true, "ok", in: plain)
        d.forget(["ok"])
        #expect(d.overrides.isEmpty)
    }

    @Test func pinnedPhotosAreKeptInAnyGroup() {
        var d = ReviewDecisions()
        d.pin(["ok"])
        #expect(d.keptIDs(in: plain).contains("ok"))
        #expect(d.keptIDs(in: plain).contains(plain.keeper.id))
    }

    @Test func unknownPhotosAreIgnored() {
        var d = ReviewDecisions()
        #expect(d.setKeep(false, "nope", in: plain) == nil)
        #expect(d.overrides.isEmpty)
    }

    @Test func ledgerRoundTrips() throws {
        var ledger = ReviewLedger()
        ledger.dismissedGroups = ["abc"]
        ledger.decisions.setKeep(true, "ok", in: plain)
        ledger.photosRemoved = 12
        ledger.lastScan = t0
        let decoded = try JSONDecoder().decode(ReviewLedger.self, from: JSONEncoder().encode(ledger))
        #expect(decoded == ledger)
    }

    @Test func ledgerWithMissingFieldsStillLoads() throws {
        let decoded = try JSONDecoder().decode(ReviewLedger.self, from: Data(#"{"photosRemoved": 3}"#.utf8))
        #expect(decoded.photosRemoved == 3)
        #expect(decoded.dismissedGroups.isEmpty && decoded.decisions.overrides.isEmpty)
    }
}

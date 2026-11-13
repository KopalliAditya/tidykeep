import Foundation
@testable import GoodTakeCore
import Testing

@Suite struct SeriesBuilderTests {
    let balanced = Sensitivity.balanced.config

    func build(_ items: [(AssetMeta, QuantizedEmbedding)], config: GroupingConfig? = nil) -> [[String]] {
        SeriesBuilder.build(items.map { .init(meta: $0.0, embedding: $0.1) }, config: config ?? balanced).map { $0.map(\.id) }
    }

    @Test func candidatesAreOnlyPhotosWithANeighborInTime() {
        let metas = [
            meta("lonely", 0),
            meta("a", 1_000), meta("b", 1_030),
            meta("burst", 5_000, burst: "B"),
            meta("late", 9_000),
        ]
        let ids = SeriesBuilder.candidates(metas.shuffled(), maxGap: 60).map(\.id)
        #expect(ids == ["a", "b", "burst"])
    }

    @Test func groupsNearIdenticalShotsTakenSecondsApart() {
        let groups = build([
            (meta("a", 0), scene(0)),
            (meta("b", 2), scene(0, nudge: 0.1)),
            (meta("c", 4), scene(0, nudge: 0.2)),
        ])
        #expect(groups == [["a", "b", "c"]])
    }

    @Test func differentScenesTakenTogetherStayApart() {
        let groups = build([
            (meta("a1", 0), scene(0)),
            (meta("b1", 3), scene(4)),
            (meta("a2", 5), scene(0, nudge: 0.1)),
            (meta("b2", 8), scene(4, nudge: 0.1)),
        ])
        #expect(Set(groups.map(Set.init)) == [["a1", "a2"], ["b1", "b2"]])
    }

    @Test func aLongPauseEndsAGroup() {
        let groups = build([
            (meta("a", 0), scene(0)),
            (meta("b", 2), scene(0, nudge: 0.05)),
            (meta("c", 2 + balanced.maxGap + 1), scene(0, nudge: 0.1)),
            (meta("d", 4 + balanced.maxGap + 1), scene(0, nudge: 0.1)),
        ])
        #expect(groups == [["a", "b"], ["c", "d"]])
    }

    @Test func aGroupCantRunLongerThanMaxSpan() {
        // A shot every 30 seconds of the same view: never a pause longer than maxGap.
        let items = (0..<20).map { (meta("p\($0)", Double($0) * 30), scene(0, nudge: Double($0 % 2) * 0.05)) }
        let groups = build(items)
        #expect(groups.count > 1)
        for g in groups {
            let first = Double(g.first!.dropFirst())! * 30, last = Double(g.last!.dropFirst())! * 30
            #expect(last - first <= balanced.maxSpan)
        }
    }

    @Test func aSlowPanDoesNotChainIntoOneGroup() {
        // Each step is small, but by the fourth shot the view has moved well away from the first.
        let step = 0.3
        let items = (0..<6).map { (meta("p\($0)", Double($0) * 2), QuantizedEmbedding(vector(axis: 0, angle: Double($0) * step))) }
        let groups = build(items)
        #expect(groups == [["p0", "p1", "p2"], ["p3", "p4", "p5"]])
    }

    @Test func burstFramesStayTogetherEvenWhenTheyLookDifferent() {
        let groups = build([
            (meta("b1", 0, burst: "X"), scene(0)),
            (meta("b2", 0.2, burst: "X"), scene(7)),
            (meta("b3", 0.4, burst: "X"), scene(9)),
        ])
        #expect(groups == [["b1", "b2", "b3"]])
    }

    @Test func aBurstThatJoinedAnotherGroupStaysInIt() {
        // b1 looks like a and joins its group; b2 looks like neither but is the same burst.
        let groups = build([
            (meta("a", 0), scene(0)),
            (meta("b1", 0.5, burst: "X"), scene(0, nudge: 0.05)),
            (meta("b2", 0.7, burst: "X"), scene(7)),
        ])
        #expect(groups == [["a", "b1", "b2"]])
    }

    @Test func singlePhotosAreNotGroups() {
        let groups = build([
            (meta("a", 0), scene(0)),
            (meta("b", 2), scene(5)),
        ])
        #expect(groups.isEmpty)
    }

    @Test func groupsComeInCaptureOrderWhateverTheInputOrder() {
        let items = [
            (meta("late2", 1_002), scene(1)),
            (meta("early2", 2), scene(0, nudge: 0.1)),
            (meta("late1", 1_000), scene(1, nudge: 0.1)),
            (meta("early1", 0), scene(0)),
        ]
        #expect(build(items) == [["early1", "early2"], ["late1", "late2"]])
    }

    @Test func sameSecondShotsHaveAStableOrder() {
        let items = [(meta("b", 0), scene(0)), (meta("a", 0), scene(0, nudge: 0.05))]
        #expect(build(items) == [["a", "b"]])
        #expect(build(items.reversed()) == [["a", "b"]])
    }

    @Test func stricterSettingsGroupLess() {
        // Two shots 0.5 apart: together when balanced, apart when strict.
        let items = [
            (meta("a", 0), QuantizedEmbedding(vector(axis: 0, angle: 0))),
            (meta("b", 2), QuantizedEmbedding(vector(axis: 0, angle: 2 * asin(0.25)))),
        ]
        #expect(build(items, config: Sensitivity.balanced.config) == [["a", "b"]])
        #expect(build(items, config: Sensitivity.strict.config).isEmpty)
    }

    @Test func presetsGetLooserInEveryRespect() {
        let s = Sensitivity.strict.config, b = Sensitivity.balanced.config, l = Sensitivity.loose.config
        #expect(s.maxGap < b.maxGap && b.maxGap < l.maxGap)
        #expect(s.maxSpan < b.maxSpan && b.maxSpan < l.maxSpan)
        #expect(s.linkDistance < b.linkDistance && b.linkDistance < l.linkDistance)
        #expect(s.anchorDistance < b.anchorDistance && b.anchorDistance < l.anchorDistance)
        for c in [s, b, l] { #expect(c.linkDistance <= c.anchorDistance) }
    }
}

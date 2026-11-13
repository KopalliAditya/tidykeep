import Foundation
@testable import GoodTakeCore
import Testing

@Suite struct ShotScorerTests {
    func rank(_ members: [(AssetMeta, FrameSignals)]) -> Ranking {
        ShotScorer.rank(members.map { (meta: $0.0, signals: $0.1) })
    }

    /// From calibration on real photos: Vision's aesthetics score sometimes likes a blurred
    /// frame a little more. A plainly sharper frame must still win.
    @Test func plainlySharperBeatsSlightlyPrettier() {
        let r = rank([
            (meta("blurred", 0), signals(sharpness: 4.13, aesthetics: 0.697)),
            (meta("sharp", 2), signals(sharpness: 6.75, aesthetics: 0.544)),
        ])
        #expect(r.keeperID == "sharp")
        #expect(r.reasons.contains(.sharpest))
        #expect(!r.isCloseCall)
    }

    @Test func lookDecidesBetweenEquallySharpShots() {
        let r = rank([
            (meta("plain", 0), signals(sharpness: 5.0, aesthetics: 0.1)),
            (meta("lovely", 2), signals(sharpness: 5.05, aesthetics: 0.6)),
        ])
        #expect(r.keeperID == "lovely")
        #expect(r.reasons == [.bestLook])
    }

    @Test func aBlinkLosesAGroupShot() {
        let r = rank([
            (meta("blink", 0), signals(sharpness: 5, aesthetics: 0.5, faces: [0.9, 0.15, 0.85])),
            (meta("eyesOpen", 1), signals(sharpness: 5, aesthetics: 0.5, faces: [0.8, 0.75, 0.8])),
        ])
        #expect(r.keeperID == "eyesOpen")
        #expect(r.reasons.contains(.bestFaces))
    }

    @Test func aFrameMissingSomeoneScoresLower() {
        let r = rank([
            (meta("oneFace", 0), signals(faces: [0.95])),
            (meta("bothFaces", 1), signals(faces: [0.8, 0.8])),
        ])
        #expect(r.keeperID == "bothFaces")
    }

    @Test func faceScoreWeighsTheWorstFaceAndMissingFaces() {
        #expect(abs(ShotScorer.faceScore([0.5, 1.0], groupMaxFaces: 2) - (0.6 * 0.5 + 0.4 * 0.75)) < 1e-6)
        #expect(abs(ShotScorer.faceScore([0.8], groupMaxFaces: 2) - 0.4) < 1e-6)
        #expect(ShotScorer.faceScore([], groupMaxFaces: 2) == 0)
    }

    @Test func aFavoriteIsAlwaysTheKeeper() {
        let r = rank([
            (meta("better", 0), signals(sharpness: 9, aesthetics: 0.9)),
            (meta("loved", 2, favorite: true), signals(sharpness: 2, aesthetics: -0.5)),
        ])
        #expect(r.keeperID == "loved")
        #expect(r.orderedIDs == ["loved", "better"])
        #expect(r.reasons == [.favorite])
        #expect(!r.isCloseCall)
    }

    @Test func nearlyIdenticalShotsAreACloseCall() {
        let r = rank([
            (meta("a", 0), signals(sharpness: 5.00, aesthetics: 0.50)),
            (meta("b", 1), signals(sharpness: 5.02, aesthetics: 0.51)),
        ])
        #expect(r.isCloseCall)
        #expect(r.reasons == [.bestOverall])
    }

    @Test func tinyDifferencesStayTiny() {
        let r = rank([
            (meta("a", 0), signals(sharpness: 5.00, aesthetics: 0.50)),
            (meta("b", 1), signals(sharpness: 5.10, aesthetics: 0.52)),
        ])
        let spread = r.scores[0].total - r.scores[1].total
        #expect(spread > 0 && spread < 0.1)
    }

    @Test func missingAestheticsDoesNotDecide() {
        let r = rank([
            (meta("unknown", 0), signals(sharpness: 5, aesthetics: nil)),
            (meta("sharper", 1), signals(sharpness: 7, aesthetics: 0.5)),
        ])
        #expect(r.keeperID == "sharper")
    }

    @Test func tiesKeepCaptureOrder() {
        let same = signals()
        let r = rank([(meta("first", 0), same), (meta("second", 1), same), (meta("third", 2), same)])
        #expect(r.orderedIDs == ["first", "second", "third"])
    }

    @Test func scoresStayBetweenZeroAndOne() {
        let r = rank([
            (meta("a", 0), signals(sharpness: 1, aesthetics: -1, faces: [0.1])),
            (meta("b", 1), signals(sharpness: 9, aesthetics: 1, faces: [1.0])),
            (meta("c", 2), signals(sharpness: 4, aesthetics: 0, faces: [])),
        ])
        for s in r.scores { #expect(s.total >= 0 && s.total <= 1) }
        #expect(r.keeperID == "b")
    }

    @Test func groupOrdersMembersBestFirstAndCountsInCaptureOrder() {
        let g = group([
            (meta("a", 0), signals(sharpness: 2)),
            (meta("b", 1), signals(sharpness: 8)),
            (meta("c", 2), signals(sharpness: 4)),
        ])
        #expect(g.members.map(\.id) == ["b", "c", "a"])
        #expect(g.keeper.id == "b")
        #expect(g.captureIndex(of: "a") == 1)
        #expect(g.captureIndex(of: "b") == 2)
        #expect(g.startDate == t0)
    }
}

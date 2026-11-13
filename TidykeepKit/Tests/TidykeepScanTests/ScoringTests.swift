import Foundation
import TidykeepCore
import TidykeepTestSupport
import Testing

/// tkscan's scorers must measure what the bench's do (bench/evaluate.py), or its numbers can't be
/// put next to the bench's.
@Suite struct UnscoredScenesTests {
    func member(_ id: String) -> (meta: AssetMeta, signals: FrameSignals) {
        (AssetMeta(id: id, creationDate: Date(timeIntervalSince1970: 0)),
         FrameSignals(embedding: QuantizedEmbedding([1, 0]), aesthetics: 0, isUtility: false, sharpness: 1, faceQualities: []))
    }

    /// Two moments of one clip, and a photo of another scene.
    func truth(scenes: Bool) -> SyntheticLibrary.Truth {
        .init(series: [.init(files: ["m1a", "m1b"], best: "m1a"), .init(files: ["m2a", "m2b"], best: "m2a")], singles: ["x"],
              scenes: scenes ? ["m1a": "clip", "m1b": "clip", "m2a": "clip", "m2b": "clip"] : nil)
    }

    @Test func pairsAcrossMomentsOfOneSceneCountNeitherWay() {
        let groups = [PhotoGroup(members: ["m1a", "m1b", "m2a", "m2b"].map(member))]
        let lenient = GroupingEval.score(groups: groups, truth: truth(scenes: true))
        #expect(lenient.pairPrecision == 1 && lenient.pairRecall == 1)
        #expect(lenient.unscoredPairs == 4)
        let strict = GroupingEval.score(groups: groups, truth: truth(scenes: false))
        #expect(strict.pairPrecision == 2.0 / 6.0 && strict.unscoredPairs == 0)
    }

    @Test func aPhotoOfAnotherSceneIsStillAWrongPair() {
        let groups = [PhotoGroup(members: ["m1a", "m1b", "x"].map(member))]
        let eval = GroupingEval.score(groups: groups, truth: truth(scenes: true))
        #expect(eval.pairPrecision == 1.0 / 3.0)
        #expect(eval.unscoredPairs == 0)
    }

    @Test func scenesAreOptionalInTruthFiles() throws {
        let old = try JSONDecoder().decode(SyntheticLibrary.Truth.self, from: Data(#"{"series": [], "singles": ["a"]}"#.utf8))
        #expect(old.scenes == nil)
        let folder = temporaryDirectory()
        try truth(scenes: true).write(to: folder)
        #expect(try SyntheticLibrary.Truth.read(from: folder).scenes?["m2b"] == "clip")
    }
}

@Suite struct CopyEvalTests {
    /// Three photos with their copies, and one unrelated photo.
    let truth = SyntheticLibrary.Truth(
        series: [.init(files: ["a", "a1", "a2"], best: "a"), .init(files: ["b", "b1"], best: "b"), .init(files: ["c", "c1"], best: "c")],
        singles: ["s"]
    )

    /// `a` is the original: the most pixels. Days apart unless `sameMoment`.
    func meta(_ id: String, sameMoment: Bool = false) -> AssetMeta {
        let day: [String: Double] = ["a": 0, "a1": 3, "a2": 9, "b": 1, "b1": 5, "s": 2]
        return AssetMeta(id: id, creationDate: Date(timeIntervalSince1970: sameMoment ? 0 : (day[id] ?? 0) * 86_400),
                         pixelWidth: id == "a" ? 4032 : 1024, pixelHeight: id == "a" ? 3024 : 768)
    }

    @Test func scoresAsTheBenchDoes() {
        // One set found exactly; one cluster holds a copy pair and an unrelated photo; c is missed.
        let clusters = [["a", "a1", "a2"], ["b", "b1", "s"]].map { $0.map { meta($0) } }
        let shown = LibraryGroups.combine(series: [], copyClusters: clusters, maxSpan: 240)
        let e = CopyEval.score(clusters: clusters, shown: shown, truth: truth)
        #expect(e.pairPrecision == 4.0 / 6.0)
        #expect(e.pairRecall == 4.0 / 5.0)
        #expect(e.falsePairs == 2)
        #expect(e.setsExact == 1 && e.setsTotal == 3)
        #expect(e.keepersRight == 1 && e.keepersScored == 1)
    }

    @Test func similarShotsAreNotScoredForTheKeeper() {
        // Taken together, the set is ranked by ShotScorer like a series, so no metadata keeper.
        let clusters = [["a", "a1", "a2"].map { meta($0, sameMoment: true) }]
        let shown = LibraryGroups.combine(series: [], copyClusters: clusters, maxSpan: 240)
        #expect(shown.similarShots.count == 1)
        let e = CopyEval.score(clusters: clusters, shown: shown, truth: truth)
        #expect(e.setsExact == 1 && e.keepersScored == 0)
    }

    @Test func nothingFoundIsPrecisePerfectlyAndRecallsNothing() {
        let e = CopyEval.score(clusters: [], shown: LibraryGroups.combine(series: [], copyClusters: [], maxSpan: 240), truth: truth)
        #expect(e.pairPrecision == 1 && e.pairRecall == 0 && e.setsExact == 0)
    }
}

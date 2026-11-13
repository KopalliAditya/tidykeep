import Foundation
@testable import TidykeepCore
import Testing

/// The series rule with both signals, as bench/rules.py fits and runs it: the weighted score
/// or the soft arm to link and to anchor, the softened print alone when a photo has no
/// content embedding, the last 8 members, and the closest of the groups that pass.
@Suite struct SeriesFusionTests {
    /// The angle between two points of the fixture circle that are `d` apart.
    static func apart(_ d: Double) -> Double { 2 * asin(d / 2) }

    /// A photo whose softened print and patch mean sit at these angles on their circles.
    /// Two photos are `2·sin(Δangle / 2)` apart in each signal; `apart` turns a distance into
    /// an angle. A nil `mean` is a photo analyzed before the content model shipped.
    func photo(_ id: String, _ t: Double, soft: Double, mean: Double?, burst: String? = nil) -> SeriesBuilder.Item {
        SeriesBuilder.Item(
            meta: meta(id, t, burst: burst),
            embedding: QuantizedEmbedding(vector(axis: 0, angle: soft)),
            content: mean.map { QuantizedEmbedding(vector(axis: 2, toward: 3, angle: $0)) }
        )
    }

    /// Two photos 2 s apart, the second `soft` and `mean` away from the first.
    func pair(soft: Double, mean: Double?, firstHasMean: Bool = true) -> [SeriesBuilder.Item] {
        [
            photo("a", 0, soft: 0, mean: firstHasMean ? 0 : nil),
            photo("b", 2, soft: Self.apart(soft), mean: mean.map(Self.apart)),
        ]
    }

    func ids(_ items: [SeriesBuilder.Item], _ config: GroupingConfig) -> [[String]] {
        SeriesBuilder.build(items, config: config).map { $0.map(\.id) }
    }

    /// The patch-mean distance that puts the weighted score at `score` for this softened distance.
    static func mean(forScore score: Double, soft: Double) -> Double {
        (score - Double(GroupingConfig.softWeight) * soft) / Double(GroupingConfig.dinoWeight)
    }

    // MARK: - Constants

    @Test func presetsAreTheFittedConstants() {
        #expect(GroupingConfig.softWeight == 0.3115 && GroupingConfig.dinoWeight == 0.6885)
        let expected: [(Sensitivity, TimeInterval, TimeInterval, Float, Float, Float, Float)] = [
            (.strict, 30, 120, 0.50, 0.5909, 0.50, 0.5909),
            (.balanced, 60, 240, 0.55, 0.65, 0.55, 0.65),
            (.loose, 180, 900, 0.65, 0.7682, 0.58, 0.6855),
        ]
        for (preset, gap, span, link, anchor, softOnlyLink, softOnlyAnchor) in expected {
            let c = preset.config
            #expect(c.maxGap == gap && c.maxSpan == span, "\(preset)")
            #expect(c.link == link && c.anchor == anchor, "\(preset)")
            #expect(c.softLink == 0.35 && c.softAnchor == 0.4136, "\(preset)")
            #expect(c.softOnlyLink == softOnlyLink && c.softOnlyAnchor == softOnlyAnchor, "\(preset)")
            #expect(c.lookback == 8, "\(preset)")
        }
    }

    @Test(arguments: Sensitivity.allCases)
    func scoresAreTheBenchFormula(_ preset: Sensitivity) {
        let c = preset.config
        let soft: Float = 0.45, mean: Float = 0.5
        let w = 0.3115 * soft + 0.6885 * mean
        #expect(abs(c.linkScore(soft: soft, content: mean) - min(w / c.link, soft / 0.35)) < 1e-6)
        #expect(abs(c.anchorScore(soft: soft, content: mean) - min(w / c.anchor, soft / 0.4136)) < 1e-6)
        #expect(abs(c.linkScore(soft: soft, content: nil) - soft / c.softOnlyLink) < 1e-6)
        #expect(abs(c.anchorScore(soft: soft, content: nil) - soft / c.softOnlyAnchor) < 1e-6)
        // Vectors of different length: no usable content distance, so the softened print decides.
        #expect(c.linkScore(soft: soft, content: .infinity) == c.linkScore(soft: soft, content: nil))
        #expect(c.linkScore(soft: .infinity, content: 0) == .infinity)
    }

    // MARK: - The weighted score

    @Test(arguments: Sensitivity.allCases)
    func theWeightedScoreDecidesAtEachPreset(_ preset: Sensitivity) {
        // A softened distance past the soft arm (0.35), so only the weighted score can link.
        let c = preset.config, soft = 0.45
        let under = Self.mean(forScore: Double(c.link) - 0.03, soft: soft)
        let over = Self.mean(forScore: Double(c.link) + 0.03, soft: soft)
        #expect(ids(pair(soft: soft, mean: under), c) == [["a", "b"]])
        #expect(ids(pair(soft: soft, mean: over), c).isEmpty)
    }

    @Test func aPairCanJoinAtOnePresetAndNotAStricterOne() {
        // Weighted score 0.60: past strict (0.50) and balanced (0.55), within loose (0.65).
        let items = pair(soft: 0.45, mean: Self.mean(forScore: 0.60, soft: 0.45))
        #expect(ids(items, Sensitivity.strict.config).isEmpty)
        #expect(ids(items, Sensitivity.balanced.config).isEmpty)
        #expect(ids(items, Sensitivity.loose.config) == [["a", "b"]])
    }

    @Test(arguments: Sensitivity.allCases)
    func theSoftArmKeepsBlurryFramesTheContentModelPullsApart(_ preset: Sensitivity) {
        // Patch means far apart (a blurred frame), softened prints close: linked by the arm alone.
        let c = preset.config
        #expect(ids(pair(soft: 0.30, mean: 1.2), c) == [["a", "b"]])
        // Just past the arm, the far patch means keep them apart (score 0.95 > every link).
        #expect(ids(pair(soft: 0.40, mean: 1.2), c).isEmpty)
    }

    // MARK: - Without a content embedding

    @Test(arguments: Sensitivity.allCases)
    func withoutAPatchMeanTheSoftenedPrintDecidesAlone(_ preset: Sensitivity) {
        let c = preset.config
        let under = Double(c.softOnlyLink) - 0.03, over = Double(c.softOnlyLink) + 0.03
        // The second photo has none, the first has none, or neither has one.
        for firstHasMean in [true, false] {
            #expect(ids(pair(soft: under, mean: nil, firstHasMean: firstHasMean), c) == [["a", "b"]])
            #expect(ids(pair(soft: over, mean: nil, firstHasMean: firstHasMean), c).isEmpty)
        }
        #expect(ids(pair(soft: under, mean: 0, firstHasMean: false), c) == [["a", "b"]])
        #expect(ids(pair(soft: over, mean: 0, firstHasMean: false), c).isEmpty)
    }

    @Test func theSoftOnlyThresholdIsNotTheWeightedOne() {
        let loose = Sensitivity.loose.config
        // Softened distance 0.62: past loose's soft-only link (0.58), but with identical patch
        // means the weighted score is 0.19, well within loose's 0.65.
        #expect(ids(pair(soft: 0.62, mean: nil), loose).isEmpty)
        #expect(ids(pair(soft: 0.62, mean: 0), loose) == [["a", "b"]])
        // Softened distance 0.50 with far patch means: apart. Without a patch mean: together.
        let balanced = Sensitivity.balanced.config
        #expect(ids(pair(soft: 0.50, mean: 1.2), balanced).isEmpty)
        #expect(ids(pair(soft: 0.50, mean: nil), balanced) == [["a", "b"]])
    }

    @Test func eachPairUsesTheRuleItsTwoPhotosAllow() {
        // a and c have patch means, far apart; b has none. c links through b on the softened
        // print alone, but its anchor test against a has both signals, and fails.
        let balanced = Sensitivity.balanced.config
        let a = photo("a", 0, soft: 0, mean: 0)
        let b = photo("b", 2, soft: Self.apart(0.2), mean: nil)
        let c = photo("c", 4, soft: Self.apart(0.45), mean: Self.apart(1.0))
        #expect(ids([a, b, c], balanced) == [["a", "b"]])
        // Without its patch mean, c's anchor test is the softened print alone (0.45 <= 0.65).
        let plainC = photo("c", 4, soft: Self.apart(0.45), mean: nil)
        #expect(ids([a, b, plainC], balanced) == [["a", "b", "c"]])
    }

    @Test func groupingTakesThePatchMeanNotTheClassToken() {
        // Close patch means, far class tokens: the series step uses the patch mean.
        let near = QuantizedEmbedding(vector(axis: 2, toward: 3, angle: 0))
        let farCLS = QuantizedEmbedding(vector(axis: 5))
        let soft = QuantizedEmbedding(vector(axis: 0, angle: Self.apart(0.45)))
        let first = FrameSignals(
            embedding: scene(0), aesthetics: 0.5, isUtility: false, sharpness: 5, faceQualities: [],
            dinoCLS: QuantizedEmbedding(vector(axis: 4)), dinoMean: near
        )
        let second = FrameSignals(
            embedding: soft, aesthetics: 0.5, isUtility: false, sharpness: 5, faceQualities: [],
            dinoCLS: farCLS, dinoMean: near
        )
        let items = [SeriesBuilder.Item(meta: meta("a", 0), signals: first), .init(meta: meta("b", 2), signals: second)]
        #expect(ids(items, Sensitivity.strict.config) == [["a", "b"]])
    }

    // MARK: - Building groups

    @Test func theAnchorStopsASlowPan() {
        // Each step moves the softened print 0.2 (inside the soft arm, so every step links) and
        // the patch mean 0.25. Three steps from the first photo the softened print is 0.59 away
        // and the weighted score 0.69, past balanced's anchor (0.65): a new group starts.
        let balanced = Sensitivity.balanced.config
        let pan = (0..<6).map { k in
            photo("p\(k)", Double(k) * 2, soft: Double(k) * Self.apart(0.2), mean: Double(k) * Self.apart(0.25))
        }
        #expect(ids(pan, balanced) == [["p0", "p1", "p2"], ["p3", "p4", "p5"]])
        // With the anchor test off, the same pan chains into one group.
        var noAnchor = balanced
        noAnchor.anchor = 100
        noAnchor.softAnchor = 100
        #expect(ids(pan, noAnchor) == [["p0", "p1", "p2", "p3", "p4", "p5"]])
    }

    @Test func onlyTheLastEightMembersAreComparedForTheLink() {
        // p1...p8 sit 0.4 to one side of p0, p9 0.4 to the other: close to p0, 0.78 from the
        // rest. p0 is the ninth most recent member when p9 arrives, so p9 doesn't link.
        let balanced = Sensitivity.balanced.config
        var items = [photo("p0", 0, soft: 0, mean: nil)]
        items += (1...8).map { photo("p\($0)", Double($0), soft: Self.apart(0.4), mean: nil) }
        items.append(photo("p9", 9, soft: -Self.apart(0.4), mean: nil))
        let first9 = (0...8).map { "p\($0)" }
        #expect(ids(items, balanced) == [first9])
        var nine = balanced
        nine.lookback = 9
        #expect(ids(items, nine) == [first9 + ["p9"]])
    }

    @Test func aPhotoJoinsTheClosestOfTheGroupsItPasses() {
        // Groups A and B are 0.8 apart; x passes the link and anchor tests of both.
        let balanced = Sensitivity.balanced.config
        let b = Self.apart(0.8)
        func items(x: Double) -> [SeriesBuilder.Item] {
            [
                photo("a1", 0, soft: 0, mean: nil), photo("b1", 1, soft: b, mean: nil),
                photo("a2", 2, soft: 0, mean: nil), photo("b2", 3, soft: b, mean: nil),
                photo("x", 4, soft: x, mean: nil),
            ]
        }
        // 0.45 from A, 0.37 from B: joins B. Mirrored: joins A.
        #expect(ids(items(x: 0.45), balanced) == [["a1", "a2"], ["b1", "b2", "x"]])
        #expect(ids(items(x: b - 0.45), balanced) == [["a1", "a2", "x"], ["b1", "b2"]])
    }

    @Test(arguments: Sensitivity.allCases)
    func timingLimitsHoldAtEachPreset(_ preset: Sensitivity) {
        let c = preset.config
        // A pause of exactly maxGap keeps the group open; a moment longer closes it.
        let same = { (id: String, t: Double) in self.photo(id, t, soft: 0, mean: 0) }
        #expect(ids([same("a", 0), same("b", c.maxGap)], c) == [["a", "b"]])
        #expect(ids([same("a", 0), same("b", c.maxGap + 0.5)], c).isEmpty)
        // One shot every maxGap: the group takes the n shots up to maxSpan after its first,
        // then the next two start a new group.
        let n = Int(c.maxSpan / c.maxGap) + 1
        let shots = (0..<(n + 2)).map { same("s\($0)", Double($0) * c.maxGap) }
        #expect(ids(shots, c).map(\.count) == [n, 2])
    }

    @Test func burstFramesStayTogetherWhateverBothSignalsSay() {
        let groups = ids([
            photo("b1", 0, soft: 0, mean: 0, burst: "X"),
            photo("b2", 0.2, soft: Self.apart(1.5), mean: Self.apart(1.5), burst: "X"),
            photo("b3", 0.4, soft: Self.apart(1.9), mean: nil, burst: "X"),
        ], Sensitivity.strict.config)
        #expect(groups == [["b1", "b2", "b3"]])
    }

    // MARK: - Boundaries

    @Test(arguments: Sensitivity.allCases)
    func aScoreOfExactlyOnePasses(_ preset: Sensitivity) {
        let c = preset.config
        #expect(c.linkScore(soft: c.softLink, content: 2) == 1)
        #expect(c.anchorScore(soft: c.softAnchor, content: 2) == 1)
        #expect(c.linkScore(soft: c.softOnlyLink, content: nil) == 1)
        #expect(c.anchorScore(soft: c.softOnlyAnchor, content: nil) == 1)
        let w = GroupingConfig.weighted(soft: 1, content: 0.3)
        var atLink = c
        atLink.link = w
        atLink.anchor = w
        #expect(atLink.linkScore(soft: 1, content: 0.3) == 1)
        #expect(atLink.anchorScore(soft: 1, content: 0.3) == 1)
    }

    @Test func aPairRightAtEachThresholdJoinsAndOneStepPastDoesNot() {
        let items = pair(soft: 0.45, mean: 0.5)
        let soft = items[0].embedding.distance(to: items[1].embedding)
        let mean = items[0].content!.distance(to: items[1].content!)
        let w = GroupingConfig.weighted(soft: soft, content: mean)
        var c = Sensitivity.balanced.config
        c.softLink = 0  // the arm off, so the weighted score decides
        c.softAnchor = 0

        c.link = w
        c.anchor = 2
        #expect(ids(items, c) == [["a", "b"]])
        c.link = w.nextDown
        #expect(ids(items, c).isEmpty)

        c.link = 2
        c.anchor = w
        #expect(ids(items, c) == [["a", "b"]])
        c.anchor = w.nextDown
        #expect(ids(items, c).isEmpty)

        // The soft arm alone, and the softened print alone for a pair without patch means.
        c = Sensitivity.balanced.config
        c.link = 0
        c.anchor = 0
        c.softLink = soft
        c.softAnchor = soft
        #expect(ids(items, c) == [["a", "b"]])
        c.softLink = soft.nextDown
        #expect(ids(items, c).isEmpty)

        let plain = pair(soft: 0.45, mean: nil, firstHasMean: false)
        c = Sensitivity.balanced.config
        c.softOnlyLink = soft
        c.softOnlyAnchor = soft
        #expect(ids(plain, c) == [["a", "b"]])
        c.softOnlyAnchor = soft.nextDown
        #expect(ids(plain, c).isEmpty)
    }
}

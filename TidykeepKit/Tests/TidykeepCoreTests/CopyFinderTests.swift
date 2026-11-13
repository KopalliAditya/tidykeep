import Foundation
@testable import TidykeepCore
import Testing

/// A photo for the copy pass: `days` after t0, of the given shape.
private func photo(
    _ id: String, days: Double = 0, seconds: Double = 0, width: Int = 4032, height: Int = 3024,
    screenshot: Bool = false, favorite: Bool = false
) -> AssetMeta {
    AssetMeta(
        id: id, creationDate: t0.addingTimeInterval(days * 86_400 + seconds), pixelWidth: width, pixelHeight: height,
        isFavorite: favorite, isScreenshot: screenshot
    )
}

/// A point on the circle from `axis` toward the next axis, `distance` from the axis itself.
private func at(_ axis: Int, _ distance: Double) -> QuantizedEmbedding {
    QuantizedEmbedding(vector(axis: axis, toward: (axis + 1) % 16, angle: 2 * asin(distance / 2)))
}

private func item(_ meta: AssetMeta, cls: QuantizedEmbedding?, soft: QuantizedEmbedding? = nil) -> CopyFinder.Item {
    CopyFinder.Item(meta: meta, cls: cls, soft: soft ?? at(0, 0))
}

private func ids(_ groups: [[AssetMeta]]) -> [[String]] { groups.map { $0.map(\.id) } }

/// The same numbers every run.
private struct Generator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}

/// A unit vector in the direction of `v`.
private func unit(_ v: [Float]) -> [Float] {
    let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return v.map { $0 / n }
}

/// The process's peak resident memory so far, in bytes.
private func peakMemory() -> Int {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return usage.ru_maxrss
}

@Suite struct CompleteLinkageTests {
    /// A matrix of `count` points with the given pairs set.
    private func matrix(_ count: Int, _ pairs: [(Int, Int, Float)]) -> CompleteLinkage.Matrix {
        var m = CompleteLinkage.Matrix(count: count)
        for (a, b, d) in pairs { m[a, b] = d }
        return m
    }

    @Test func aChainDoesNotMakeOneCluster() {
        // 0-1 and 1-2 are close, 0-2 is not: only the closer pair merges.
        let pairs: [(Int, Int, Float)] = [(0, 1, 0.2), (1, 2, 0.3)]
        #expect(CompleteLinkage.clusters(matrix(3, pairs)) == [[0, 1]])
        #expect(CompleteLinkage.clusters(matrix(3, pairs + [(2, 0, 0.9)])) == [[0, 1, 2]])
    }

    @Test func pairsOverOneInfiniteOrNaNNeverLinkAndOneItselfDoes() {
        let pairs: [(Int, Int, Float)] = [(0, 1, 1.01), (2, 3, .infinity), (3, 4, .nan), (6, 5, 0.5), (7, 8, 1)]
        #expect(CompleteLinkage.clusters(matrix(9, pairs)) == [[5, 6], [7, 8]])
        // A NaN farthest pair must not be lost when its cluster merges.
        #expect(CompleteLinkage.clusters(matrix(3, [(0, 1, 0.1), (0, 2, 0.2), (1, 2, .nan)])) == [[0, 1]])
        #expect(CompleteLinkage.clusters(matrix(0, [])).isEmpty && CompleteLinkage.clusters(matrix(1, [])).isEmpty)
    }

    @Test func clustersAreSortedAndOrderedByFirstPoint() {
        let pairs: [(Int, Int, Float)] = [(7, 3, 0.1), (5, 1, 0.2), (1, 8, 0.3), (5, 8, 0.3)]
        #expect(CompleteLinkage.clusters(matrix(9, pairs)) == [[1, 5, 8], [3, 7]])
    }

    @Test func aTieGoesTheSameWayEveryRun() {
        // 1 is as close to 0 as to 2: the chain from 0 keeps it, as scipy's would.
        #expect(CompleteLinkage.clusters(matrix(3, [(0, 1, 0.5), (1, 2, 0.5)])) == [[0, 1]])
        #expect(CompleteLinkage.clusters(matrix(4, [(0, 1, 0.5), (1, 2, 0.5), (2, 3, 0.5)])) == [[0, 1], [2, 3]])
    }

    /// Against the textbook method on full distance matrices: merge the two clusters whose
    /// farthest pair is closest, until that is over 1.
    @Test func matchesCompleteLinkageOnTheFullMatrix() {
        var rng = Generator(state: 42)
        for _ in 0..<20 {
            let n = 30
            let points = (0..<n).map { _ in (Double.random(in: 0..<4, using: &rng), Double.random(in: 0..<4, using: &rng)) }
            func d(_ i: Int, _ j: Int) -> Double { hypot(points[i].0 - points[j].0, points[i].1 - points[j].1) }
            var m = CompleteLinkage.Matrix(count: n)
            for i in 0..<n { for j in (i + 1)..<n { m[i, j] = Float(d(i, j)) } }

            var clusters = (0..<n).map { [$0] }
            while true {
                var best: (Double, Int, Int)?
                for x in clusters.indices {
                    for y in (x + 1)..<clusters.count {
                        let far = clusters[x].flatMap { i in clusters[y].map { d(i, $0) } }.max()!
                        if far <= 1, best.map({ far < $0.0 }) ?? true { best = (far, x, y) }
                    }
                }
                guard let (_, x, y) = best else { break }
                clusters[x] += clusters[y]
                clusters.remove(at: y)
            }
            let expected = clusters.filter { $0.count >= 2 }.map { $0.sorted() }.sorted { $0[0] < $1[0] }
            #expect(CompleteLinkage.clusters(m) == expected)
        }
    }

    @Test func unionFindGroupsEverythingLinkedByAnyChain() {
        var links = UnionFind(count: 8)
        for (a, b) in [(6, 2), (2, 4), (1, 7), (5, 5)] { links.link(a, b) }
        #expect(links.connected(6, 4) && !links.connected(6, 1))
        #expect(links.groups() == [[1, 7], [2, 4, 6]])
    }
}

@Suite struct CopyFinderTests {
    @Test func aCopyMonthsLaterIsFoundAndAnotherSceneIsNot() {
        let items = [
            item(photo("copy", days: 40), cls: at(0, 0.3)),
            item(photo("original"), cls: at(0, 0)),
            item(photo("other", days: 1), cls: at(4, 0)),
        ]
        #expect(ids(CopyFinder.clusters(items)) == [["original", "copy"]])
    }

    @Test func theCLSThresholdIsTheFittedOne() {
        #expect(CopyFinder.clsLink == 0.59 && CopyFinder.screenSoftLink == 0.07 && CopyFinder.tallAspect == 1.9)
        let original = item(photo("a"), cls: at(0, 0))
        #expect(CopyFinder.score(original, item(photo("b"), cls: at(0, 0.57))) < 1)
        #expect(CopyFinder.score(original, item(photo("c"), cls: at(0, 0.61))) > 1)
    }

    @Test func twoScreensMustAlsoMatchOnTheSoftenedPrint() {
        let screen = item(photo("s", screenshot: true), cls: at(0, 0), soft: at(2, 0))
        let near = item(photo("n", screenshot: true), cls: at(0, 0.2), soft: at(2, 0.05))
        let far = item(photo("f", screenshot: true), cls: at(0, 0.2), soft: at(2, 0.1))
        #expect(CopyFinder.score(screen, near) < 1)
        #expect(CopyFinder.score(screen, far) > 1)
        // A screenshot of a photo: only one is a screen, so the print isn't asked.
        let photoOfIt = item(photo("p"), cls: at(0, 0.2), soft: at(2, 0.5))
        #expect(CopyFinder.score(screen, photoOfIt) < 1)
    }

    @Test(arguments: [
        (1000, 1900, false, true), (1900, 1000, false, true), (1000, 1899, false, false),
        (4032, 3024, true, true), (0, 0, false, false),
    ])
    func screenShapeOrMarkMakesAScreen(width: Int, height: Int, marked: Bool, expected: Bool) {
        #expect(CopyFinder.isScreenLike(photo("x", width: width, height: height, screenshot: marked)) == expected)
    }

    @Test func noContentEmbeddingOrAnotherModelIsNeverACopy() {
        let a = item(photo("a"), cls: at(0, 0))
        #expect(CopyFinder.score(a, item(photo("b"), cls: nil)) == .infinity)
        let longer = item(photo("c"), cls: QuantizedEmbedding(vector(axis: 0) + [Float](repeating: 0, count: 16)))
        #expect(CopyFinder.clusters([a, item(photo("b"), cls: nil), longer]).isEmpty)
    }

    @Test func clustersAreCompleteLinkage() {
        // a-b and b-c are copy-close, a-c is not: b goes with the nearer one.
        let items = [item(photo("a"), cls: at(0, 0)), item(photo("b", days: 1), cls: at(0, 0.25)), item(photo("c", days: 2), cls: at(0, 0.62))]
        #expect(ids(CopyFinder.clusters(items)) == [["a", "b"]])
    }

    /// More photos than one block, so pairs across blocks are searched too, and a fifth are
    /// screens, which are shortlisted on the print. Every pair within reach must be visited once,
    /// with the score it gets measured one by one.
    @Test func theBlockSearchFindsEveryClosePair() {
        var rng = Generator(state: 7)
        var items: [CopyFinder.Item] = []
        while items.count < EmbeddingRows.block + 200 {
            let base = (0..<16).map { _ in Float.random(in: -1...1, using: &rng) }
            let print = (0..<16).map { _ in Float.random(in: -1...1, using: &rng) }
            for _ in 0..<Int.random(in: 1...4, using: &rng) {
                let v = unit(base.map { $0 + Float.random(in: -0.25...0.25, using: &rng) })
                let p = unit(print.map { $0 + Float.random(in: -0.03...0.03, using: &rng) })
                let screen = Int.random(in: 0..<5, using: &rng) == 0
                let meta = photo("p\(items.count)", days: Double(items.count), screenshot: screen)
                items.append(item(meta, cls: QuantizedEmbedding(v), soft: QuantizedEmbedding(p)))
            }
        }
        var found: [[Int]: Float] = [:], visited = Set<[Int]>()
        CopyFinder.forEachCandidate(items) { a, b, score in
            #expect(a < b && visited.insert([a, b]).inserted)
            let s = score()
            if s <= 1 { found[[a, b]] = s }
        }
        var expected: [[Int]: Float] = [:]
        for i in items.indices {
            for j in (i + 1)..<items.count {
                let s = CopyFinder.score(items[i], items[j])
                if s <= 1 { expected[[i, j]] = s }
            }
        }
        #expect(expected.count > 300)
        #expect(expected.keys.contains { items[$0[0]].meta.isScreenshot && items[$0[1]].meta.isScreenshot })
        #expect(found == expected)
    }

    /// The two passes against complete linkage on every pair's score at once, for random
    /// libraries with screens, photos without a CLS embedding, and copy sets that overlap.
    @Test func clustersAreCompleteLinkageOverEveryPair() {
        var rng = Generator(state: 11)
        for _ in 0..<10 {
            var items: [CopyFinder.Item] = []
            let spread = Float.random(in: 0.05...0.35, using: &rng)
            for _ in 0..<Int.random(in: 5...20, using: &rng) {
                let base = (0..<16).map { _ in Float.random(in: -1...1, using: &rng) }
                let print = (0..<16).map { _ in Float.random(in: -1...1, using: &rng) }
                for _ in 0..<Int.random(in: 1...8, using: &rng) {
                    let v = unit(base.map { $0 + Float.random(in: -spread...spread, using: &rng) })
                    let p = unit(print.map { $0 + Float.random(in: -0.03...0.03, using: &rng) })
                    let meta = photo("p\(items.count)", seconds: .random(in: 0..<1e6, using: &rng), screenshot: Int.random(in: 0..<4, using: &rng) == 0)
                    let cls = Int.random(in: 0..<30, using: &rng) == 0 ? nil : QuantizedEmbedding(v)
                    items.append(item(meta, cls: cls, soft: QuantizedEmbedding(p)))
                }
            }
            let sorted = items.sorted { SeriesBuilder.captureOrder($0.meta, $1.meta) }
            let n = sorted.count
            var d = (0..<n).map { i in (0..<n).map { j in i == j ? 0 : CopyFinder.score(sorted[i], sorted[j]) } }
            var members = (0..<n).map { [$0] }, alive = [Bool](repeating: true, count: n)
            while true {
                var best: (Float, Int, Int)?
                for i in 0..<n where alive[i] {
                    for j in (i + 1)..<n where alive[j] && d[i][j] <= 1 && (best.map { d[i][j] < $0.0 } ?? true) { best = (d[i][j], i, j) }
                }
                guard let (_, i, j) = best else { break }
                members[i] += members[j]
                members[j] = []
                alive[j] = false
                for k in 0..<n where alive[k] && k != i { (d[i][k], d[k][i]) = (max(d[i][k], d[j][k]), max(d[i][k], d[j][k])) }
            }
            let expected = members.filter { $0.count >= 2 }.map { $0.sorted().map { sorted[$0].meta.id } }
            #expect(expected.contains { $0.count > 2 })
            #expect(ids(CopyFinder.clusters(items)) == expected)
        }
    }

    @Test func aGroupTooBigToClusterAtOnceIsSplitInCaptureOrder() {
        let items = (0..<10).reversed().map { item(photo("p\($0)", days: Double($0)), cls: at(0, 0)) }
        #expect(ids(CopyFinder.clusters(items)).map(\.count) == [10])
        let split = [["p0", "p1", "p2"], ["p3", "p4", "p5"], ["p6", "p7", "p8", "p9"]]
        #expect(ids(CopyFinder.clusters(items, maxClustered: 4)) == split)
        #expect(CopyFinder.maxClustered == 4096)
        #expect(CopyFinder.runs(of: Array(0..<10_000), atMost: 4096).map(\.count) == [3333, 3333, 3334])
        #expect(CopyFinder.runs(of: Array(0..<8192), atMost: 4096).map(\.count) == [4096, 4096])
        #expect(CopyFinder.runs(of: [7, 9], atMost: 4096) == [[7, 9]])
    }

    /// A library's worth of look-alikes (dark pocket shots, document scans, a re-imported
    /// folder) has to stay quick and small. Keeping a link per close pair took 3.5 s and 530 MB
    /// for 2000 such photos even optimized, and 877 MB for 3000. Screens that are close in CLS
    /// but not on the print took 8.8 s for 6000, measuring every pair.
    @Test func twoThousandLookAlikesTakeLittleTimeAndMemory() {
        var rng = Generator(state: 3)
        let base = (0..<384).map { _ in Float.random(in: -1...1, using: &rng) }
        let alike = (0..<2000).map { i in
            item(photo("p\(i)", seconds: Double(i) * 3600), cls: QuantizedEmbedding(unit(base.map { $0 + Float.random(in: -0.05...0.05, using: &rng) })))
        }
        let screens = alike.enumerated().map { i, a in
            let print = QuantizedEmbedding(unit((0..<768).map { _ in Float.random(in: -1...1, using: &rng) }))
            return item(photo("s\(i)", seconds: Double(i) * 3600, width: 1179, height: 2556), cls: a.cls, soft: print)
        }
        let before = peakMemory()
        let clock = ContinuousClock(), start = clock.now
        #expect(CopyFinder.clusters(alike).map(\.count) == [2000])
        #expect(CopyFinder.clusters(screens).isEmpty)
        // Test builds are unoptimized, so this is far slower than in the app.
        #expect(clock.now - start < .seconds(30))
        // The peak is the whole test process's, so this only sees growth past an earlier peak, and
        // tests running alongside add to it. Linking every pair added about 500 MB here.
        #expect(peakMemory() - before < 250_000_000)
    }
}

@Suite struct LibraryGroupsTests {
    let span: TimeInterval = 240

    @Test func aLoneCopyJoinsTheSeriesItsPartnersAreIn() {
        let s = [photo("s1"), photo("s2", seconds: 2)]
        let copy = photo("c", days: 30)
        let out = LibraryGroups.combine(series: [s], copyClusters: [[s[1], copy]], maxSpan: span)
        #expect(ids(out.series) == [["s1", "s2", "c"]] && out.joined == 1)
        #expect(out.copies.isEmpty && out.similarShots.isEmpty)
    }

    @Test func aLoneCopyOfTwoSeriesIsDropped() {
        let a = [photo("a1"), photo("a2", seconds: 2)], b = [photo("b1", days: 1), photo("b2", days: 1, seconds: 2)]
        let out = LibraryGroups.combine(series: [a, b], copyClusters: [[a[0], b[0], photo("c", days: 9)]], maxSpan: span)
        #expect(ids(out.series) == [["a1", "a2"], ["b1", "b2"]] && out.joined == 0)
        #expect(out.copies.isEmpty && out.similarShots.isEmpty)
    }

    @Test func leftoversMakeSetsByHowFarApartTheyWereTaken() {
        let series = [photo("s1"), photo("s2", seconds: 2)]
        let spread = [series[0], photo("small", days: 20, width: 1024, height: 768), photo("big", days: 10)]
        let moment = [photo("m2", days: 5, seconds: 100), photo("m1", days: 5)]
        let out = LibraryGroups.combine(series: [series], copyClusters: [spread, moment], maxSpan: span)
        #expect(ids(out.copies) == [["big", "small"]])  // keeper first, the series photo left out
        #expect(ids(out.similarShots) == [["m1", "m2"]])  // capture order
        #expect(ids(out.series) == [["s1", "s2"]] && out.joined == 0)
    }

    @Test func theKeeperIsProtectedThenNotAScreenshotThenBiggestThenFirst() {
        let order = [
            photo("favorite", days: 9, width: 10, height: 10, favorite: true),
            photo("photo", days: 8, width: 100, height: 100),
            photo("earlier", days: 1, width: 50, height: 50),
            photo("later-a", days: 2, width: 50, height: 50),
            photo("later-b", days: 2, width: 50, height: 50),
            photo("screenshot", days: 0, width: 4000, height: 4000, screenshot: true),
        ]
        #expect(order.reversed().sorted(by: LibraryGroups.keepsBefore).map(\.id) == order.map(\.id))
    }

    static func signals(_ shown: QuantizedEmbedding, utility: Bool = false) -> FrameSignals {
        FrameSignals(embedding: shown, aesthetics: nil, isUtility: utility, sharpness: 1, faceQualities: [], dinoCLS: shown, dinoMean: shown)
    }

    @Test func buildRunsTheWindowThenTheCopyPass() {
        let burst = (0..<3).map { (photo("f\($0)", seconds: Double($0) * 2), Self.signals(at(0, Double($0) * 0.01))) }
        let photos = burst + [
            (photo("f-copy", days: 30), Self.signals(at(0, 0.02))),
            (photo("g", days: 100), Self.signals(at(3, 0))),
            (photo("g-small", days: 200, width: 640, height: 480), Self.signals(at(3, 0.1))),
            (photo("alone", days: 300), Self.signals(at(6, 0))),
        ]
        let out = LibraryGroups.build(photos, config: Sensitivity.balanced.config)
        #expect(ids(out.series) == [["f0", "f1", "f2", "f-copy"]] && out.joined == 1)
        #expect(ids(out.copies) == [["g", "g-small"]] && out.similarShots.isEmpty)
    }

    /// A series with nothing to review isn't shown, so its photos are free for a copy set.
    @Test func aFullyProtectedSeriesLeavesItsPhotosToTheCopyPass() {
        let burst = (0..<2).map { (photo("f\($0)", seconds: Double($0) * 2, favorite: true), Self.signals(at(0, Double($0) * 0.01))) }
        let out = LibraryGroups.build(burst + [(photo("f-copy", days: 30), Self.signals(at(0, 0.02)))], config: Sensitivity.balanced.config)
        #expect(out.series.isEmpty && out.joined == 0)
        #expect(ids(out.copies) == [["f0", "f1", "f-copy"]])
    }
}

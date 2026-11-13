import Foundation

/// The library-wide copy pass: re-saved, resized, re-encoded, lightly cropped, rotated,
/// mirrored or recoloured copies of a photo, and screenshots of it, however far apart in time.
/// The time window (`SeriesBuilder`) can't find these: a copy is usually made days later.
///
/// The test is the DINOv2 CLS embedding (`FrameSignals.dinoCLS`): a pair's score is
/// `dCLS / clsLink`, and the two can be copies when it is at most 1. Different app screens all
/// look alike to the content model, so when both photos are screen-like the softened print must
/// also be as close as a re-save: the score becomes `max(score, dSoft / screenSoftLink)`.
/// Clusters are complete linkage cut at 1 (`CompleteLinkage`), so every pair in one passes.
///
/// Distances are Euclidean between the stored int8 unit vectors, as everywhere else. The
/// constants were fitted on the bench's dev halves (`CopyRule` in bench/rules.py), so keep the
/// two in step and never tune them by hand. No second signal is checked: none raised dev
/// precision, which was already 1.000.
public enum CopyFinder {
    public struct Item: Sendable {
        public let meta: AssetMeta
        /// The content model's CLS embedding. A photo without one is never a copy.
        public let cls: QuantizedEmbedding?
        /// The softened Vision feature print, for the screen rule.
        public let soft: QuantizedEmbedding

        public init(meta: AssetMeta, cls: QuantizedEmbedding?, soft: QuantizedEmbedding) {
            self.meta = meta
            self.cls = cls
            self.soft = soft
        }

        public init(meta: AssetMeta, signals: FrameSignals) {
            self.init(meta: meta, cls: signals.dinoCLS, soft: signals.embedding)
        }
    }

    /// CLS distance at which two photos can be copies.
    public static let clsLink: Float = 0.59
    /// Softened-print distance two screen-like photos must also be within.
    public static let screenSoftLink: Float = 0.07
    /// A long side at least this many times the short side is shaped like a phone screen.
    public static let tallAspect: Double = 1.9
    /// The most photos clustered at once. A group of photos linked by any chain of close pairs
    /// is clustered on its own, with a 4-byte distance for each of its pairs: 32 MB for 4096.
    /// A bigger group is split into runs in capture order, and copies across runs are missed.
    /// Such a group is a library's worth of look-alikes (dark pocket shots, document scans,
    /// time-lapse frames), not a copy set, and without the split it could take gigabytes.
    public static let maxClustered = 4096

    /// Marked as a screenshot by Photos, or shaped like a phone screen. The shape catches
    /// screenshots that lost the mark when another app saved them.
    public static func isScreenLike(_ meta: AssetMeta) -> Bool {
        if meta.isScreenshot { return true }
        let long = max(meta.pixelWidth, meta.pixelHeight), short = min(meta.pixelWidth, meta.pixelHeight)
        return short > 0 && Double(long) >= tallAspect * Double(short)
    }

    /// The pair's copy score: they can be copies when it is at most 1. Infinite when either
    /// photo has no CLS embedding, or the two came from different models.
    public static func score(_ a: Item, _ b: Item) -> Float {
        guard let ca = a.cls, let cb = b.cls else { return .infinity }
        let general = ca.distance(to: cb) / clsLink
        guard isScreenLike(a.meta), isScreenLike(b.meta) else { return general }
        return max(general, a.soft.distance(to: b.soft) / screenSoftLink)
    }

    /// Copy clusters of two or more photos, each in capture order, ordered by first capture.
    ///
    /// Two passes, so that no list of every close pair is ever kept: a big set of look-alikes
    /// has millions. The first finds which photos are linked by any chain of close pairs
    /// (`UnionFind`, skipping pairs already linked). No cluster spans two of those groups, so
    /// the second clusters each group alone on a full matrix of its pairs, measured again.
    public static func clusters(_ items: [Item]) -> [[AssetMeta]] {
        clusters(items, maxClustered: maxClustered)
    }

    static func clusters(_ items: [Item], maxClustered: Int) -> [[AssetMeta]] {
        let sorted = items.sorted { SeriesBuilder.captureOrder($0.meta, $1.meta) }
        var links = UnionFind(count: sorted.count)
        forEachCandidate(sorted) { a, b, score in
            if !links.connected(a, b), score() <= 1 { links.link(a, b) }
        }
        var found: [[Int]] = []
        for group in links.groups() {
            for run in runs(of: group, atMost: maxClustered) {
                found += CompleteLinkage.clusters(matrix(run.map { sorted[$0] })).map { $0.map { run[$0] } }
            }
        }
        return found.sorted { $0[0] < $1[0] }.map { $0.map { sorted[$0].meta } }
    }

    /// The scores of every pair of `items` that can be copies.
    private static func matrix(_ items: [Item]) -> CompleteLinkage.Matrix {
        var matrix = CompleteLinkage.Matrix(count: items.count)
        forEachCandidate(items) { a, b, score in matrix[a, b] = score() }
        return matrix
    }

    /// `points` cut into the fewest runs of at most `limit` in a row, all about the same size.
    static func runs(of points: [Int], atMost limit: Int) -> [[Int]] {
        let parts = (points.count + limit - 1) / limit
        return (0..<parts).map { k in Array(points[k * points.count / parts..<(k + 1) * points.count / parts]) }
    }

    /// Calls `visit(a, b, score)`, `a < b`, for every pair of `items` that may score at most 1;
    /// `score()` measures it exactly, as `score(_:_:)` would. Pairs it skips score over 1.
    ///
    /// Pairs are shortlisted by CLS distance (`EmbeddingRows`). A pair of screens must also be as
    /// close as a re-save on the softened print, which few are, though thousands of screenshots
    /// can be close in CLS. So screens are shortlisted among themselves by the print instead.
    static func forEachCandidate(_ items: [Item], _ visit: (_ a: Int, _ b: Int, _ score: () -> Float) -> Void) {
        let screen = items.map { isScreenLike($0.meta) }
        let withCLS = items.indices.filter { (items[$0].cls?.count ?? 0) > 0 }
        // Vectors of different length (another model) are never compared.
        for index in grouped(withCLS, by: { [items[$0].cls!.count] }) {
            let cls = EmbeddingRows(index.map { items[$0].cls! })
            cls.forEachPair(within: clsLink) { i, j in
                let (a, b) = (index[i], index[j])
                if screen[a] && screen[b] { return }
                visit(a, b) { cls.distance(i, j) / clsLink }
            }
        }
        let screens = withCLS.filter { screen[$0] && items[$0].soft.count > 0 }
        for index in grouped(screens, by: { [items[$0].cls!.count, items[$0].soft.count] }) {
            let cls = EmbeddingRows(index.map { items[$0].cls! }), soft = EmbeddingRows(index.map { items[$0].soft })
            soft.forEachPair(within: screenSoftLink) { i, j in
                visit(index[i], index[j]) { max(cls.distance(i, j) / clsLink, soft.distance(i, j) / screenSoftLink) }
            }
        }
    }

    /// `indices` split by `key`, each part ascending, ordered by first index.
    private static func grouped(_ indices: [Int], by key: (Int) -> [Int]) -> [[Int]] {
        Dictionary(grouping: indices, by: key).values.sorted { $0[0] < $1[0] }
    }
}

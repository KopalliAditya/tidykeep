import Foundation

/// Everything the review shows: series from the time window and copy sets from the copy pass,
/// with no photo in two groups.
///
/// Keep and remove choices are stored per photo (`ReviewDecisions`). A photo in two groups could
/// be the kept photo of one and a removal in the other, so the groups must not overlap. The
/// series step runs first. Then each copy cluster loses its series photos:
/// - two or more left make a copy set;
/// - exactly one left, whose partners all sit in one series, joins that series (it is a copy of
///   a photo there);
/// - anything else is dropped.
///
/// This is `app_groups` in bench/rules.py, so keep the two in step.
public struct LibraryGroups: Sendable, Equatable {
    /// Series in capture order, each with any copy that joined it.
    public var series: [[AssetMeta]]
    /// Copy sets taken within `maxSpan` of each other: near-identical frames of one moment that
    /// the window missed. They are ranked like series (ShotScorer), not by metadata.
    public var similarShots: [[AssetMeta]]
    /// Copy sets spread over time, keeper first (`keepsBefore`).
    public var copies: [[AssetMeta]]
    /// How many copies joined a series.
    public var joined: Int

    /// Series and copy clusters into disjoint groups. `series` should already leave out groups
    /// with nothing to review, as `Scanner` does, so their photos are free for copy sets.
    public static func combine(series: [[AssetMeta]], copyClusters: [[AssetMeta]], maxSpan: TimeInterval) -> LibraryGroups {
        var series = series
        var home: [String: Int] = [:]
        for (k, group) in series.enumerated() { for meta in group { home[meta.id] = k } }

        var sets: [[AssetMeta]] = []
        var joined = 0
        for cluster in copyClusters where cluster.count >= 2 {
            let rest = cluster.filter { home[$0.id] == nil }
            let homes = Set(cluster.compactMap { home[$0.id] })
            if rest.count >= 2 {
                sets.append(rest)
            } else if rest.count == 1, homes.count == 1, let k = homes.first {
                series[k].append(rest[0])
                joined += 1
            }
        }

        var out = LibraryGroups(series: series.map { $0.sorted(by: SeriesBuilder.captureOrder) }, similarShots: [], copies: [], joined: joined)
        for set in sets {
            let dates = set.map(\.creationDate)
            if let first = dates.min(), let last = dates.max(), last.timeIntervalSince(first) <= maxSpan {
                out.similarShots.append(set.sorted(by: SeriesBuilder.captureOrder))
            } else {
                out.copies.append(set.sorted(by: keepsBefore))
            }
        }
        return out
    }

    /// The whole pass over analyzed photos: the window over photos with a neighbour within
    /// `maxGap` (as `Scanner` does, leaving out series with nothing to review), then the copy pass
    /// over every photo.
    public static func build(_ photos: [(meta: AssetMeta, signals: FrameSignals)], config: GroupingConfig) -> LibraryGroups {
        let signals = Dictionary(photos.map { ($0.meta.id, $0.signals) }, uniquingKeysWith: { first, _ in first })
        let candidates = SeriesBuilder.candidates(photos.map(\.meta), maxGap: config.maxGap)
        let series = SeriesBuilder.build(candidates.compactMap { meta in signals[meta.id].map { .init(meta: meta, signals: $0) } }, config: config)
            // PhotoGroup.isFullyProtected: every photo a favorite, an edit or a document.
            .filter { group in !group.allSatisfy { $0.isProtected || signals[$0.id]?.isUtility == true } }
        let clusters = CopyFinder.clusters(photos.map { CopyFinder.Item(meta: $0.meta, signals: $0.signals) })
        return combine(series: series, copyClusters: clusters, maxSpan: config.maxSpan)
    }

    /// Which copy to keep: true when `a` should be kept over `b`.
    ///
    /// - Protected (favorite or edited) first. Those are always kept anyway; this makes one of
    ///   them the photo that favorites and albums are merged onto.
    /// - Then not a screenshot: a screenshot of a photo can have more pixels than the photo.
    ///   Only Photos' mark counts here, not the screen shape, so a panorama original is never
    ///   sorted below its copies.
    /// - Then the most pixels, so a downscaled copy dated earlier doesn't win.
    /// - Then the earliest capture date, then the ID, so the choice repeats.
    ///
    /// File format is not used: it picked the wrong photo for JPEG originals with HEIC copies.
    /// On the bench this order was the only one with no wrong pick (bench/rules.py, keeper table).
    public static func keepsBefore(_ a: AssetMeta, _ b: AssetMeta) -> Bool {
        if a.isProtected != b.isProtected { return a.isProtected }
        if a.isScreenshot != b.isScreenshot { return !a.isScreenshot }
        let pa = a.pixelWidth * a.pixelHeight, pb = b.pixelWidth * b.pixelHeight
        if pa != pb { return pa > pb }
        if a.creationDate != b.creationDate { return a.creationDate < b.creationDate }
        return a.id < b.id
    }
}

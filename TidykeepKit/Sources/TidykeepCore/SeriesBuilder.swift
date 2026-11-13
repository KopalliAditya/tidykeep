import Accelerate
import Foundation

/// Finds series: runs of photos of the same moment.
///
/// Photos are walked in capture order. Each one joins the open group it is closest to,
/// if it is within `linkDistance` of one of that group's recent members and within
/// `anchorDistance` of the group's first photo. Groups close after `maxGap` seconds
/// of silence or `maxSpan` seconds in total. Burst frames always stay together.
public enum SeriesBuilder {
    public struct Item: Sendable {
        public let meta: AssetMeta
        public let embedding: QuantizedEmbedding

        public init(meta: AssetMeta, embedding: QuantizedEmbedding) {
            self.meta = meta
            self.embedding = embedding
        }
    }

    /// Photos worth analyzing: those with another photo within `maxGap` seconds, or in a burst.
    /// Everything else can't be part of a series, so it costs nothing.
    public static func candidates(_ metas: [AssetMeta], maxGap: TimeInterval) -> [AssetMeta] {
        let sorted = metas.sorted(by: captureOrder)
        var keep = [Bool](repeating: false, count: sorted.count)
        for i in sorted.indices {
            if sorted[i].burstID != nil { keep[i] = true }
            if i > 0, sorted[i].creationDate.timeIntervalSince(sorted[i - 1].creationDate) <= maxGap {
                keep[i] = true
                keep[i - 1] = true
            }
        }
        return sorted.indices.filter { keep[$0] }.map { sorted[$0] }
    }

    /// Groups of two or more photos, each in capture order, groups ordered by first capture.
    public static func build(_ items: [Item], config: GroupingConfig) -> [[AssetMeta]] {
        let sorted = items.sorted { captureOrder($0.meta, $1.meta) }
        // Only photos in open groups are compared, so vectors are expanded when first needed
        // and dropped when their group closes. A big library never holds them all at once.
        var vectors = [[Float]?](repeating: nil, count: sorted.count)

        final class Open {
            var members: [Int]
            var first: Date
            var last: Date
            /// Every burst with a frame here, so later frames of a burst find it.
            var burstIDs: Set<String> = []
            init(_ i: Int, date: Date) {
                members = [i]
                first = date
                last = date
            }
        }

        var open: [Open] = []
        var done: [[Int]] = []

        func vector(_ i: Int) -> [Float] {
            if let v = vectors[i] { return v }
            let v = sorted[i].embedding.dequantized()
            vectors[i] = v
            return v
        }

        func distance(_ a: Int, _ b: Int) -> Float {
            let va = vector(a), vb = vector(b)
            guard va.count == vb.count, !va.isEmpty else { return .infinity }
            return vDSP.distanceSquared(va, vb).squareRoot()
        }

        for (i, item) in sorted.enumerated() {
            let date = item.meta.creationDate
            open.removeAll { group in
                let stale = date.timeIntervalSince(group.last) > config.maxGap
                if stale {
                    done.append(group.members)
                    for m in group.members { vectors[m] = nil }
                }
                return stale
            }

            var target: Open?
            if let burst = item.meta.burstID {
                target = open.first { $0.burstIDs.contains(burst) }
            }
            if target == nil {
                var best = Float.infinity
                for group in open where date.timeIntervalSince(group.first) <= config.maxSpan {
                    let recent = group.members.suffix(config.lookback)
                    let nearest = recent.map { distance(i, $0) }.min() ?? .infinity
                    guard nearest <= config.linkDistance, nearest < best else { continue }
                    guard distance(i, group.members[0]) <= config.anchorDistance else { continue }
                    best = nearest
                    target = group
                }
            }

            let joined = target ?? Open(i, date: date)
            if target == nil {
                open.append(joined)
            } else {
                joined.members.append(i)
                joined.last = date
            }
            if let burst = item.meta.burstID { joined.burstIDs.insert(burst) }
        }
        done.append(contentsOf: open.map(\.members))

        return done
            .filter { $0.count >= 2 }
            .map { $0.sorted().map { sorted[$0].meta } }
            .sorted { captureOrder($0[0], $1[0]) }
    }

    static func captureOrder(_ a: AssetMeta, _ b: AssetMeta) -> Bool {
        a.creationDate != b.creationDate ? a.creationDate < b.creationDate : a.id < b.id
    }
}

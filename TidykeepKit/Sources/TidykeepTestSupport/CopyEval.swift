import Foundation
import TidykeepCore

/// Scores the copy pass against ground truth in `truth.json`'s format, where each "series" is
/// one photo and its copies and `best` is the original.
///
/// The measures are the bench's (`score_components` in bench/evaluate.py), so the two can be
/// compared number for number.
public struct CopyEval: Codable, Sendable, Equatable {
    /// Of photo pairs put in one cluster, the share that truly are copies.
    public var pairPrecision: Double
    /// Of photo pairs that truly are copies, the share put in one cluster.
    public var pairRecall: Double
    public var falsePairs: Int
    /// Copy sets found exactly: one cluster holding the set and nothing else.
    public var setsExact: Int
    public var setsTotal: Int
    /// Of exact sets shown as copies (not similar shots), how many keep the original.
    public var keepersRight: Int
    public var keepersScored: Int

    public static func score(clusters: [[AssetMeta]], shown: LibraryGroups, truth: SyntheticLibrary.Truth) -> CopyEval {
        let label = Dictionary(uniqueKeysWithValues: clusters.enumerated().flatMap { k, c in c.map { ($0.id, k) } })
        let truthSet = Dictionary(uniqueKeysWithValues: truth.series.enumerated().flatMap { k, s in s.files.map { ($0, k) } })
        var predicted = 0, hit = 0
        for cluster in clusters {
            for (n, a) in cluster.enumerated() {
                for b in cluster[(n + 1)...] {
                    predicted += 1
                    if let ta = truthSet[a.id], ta == truthSet[b.id] { hit += 1 }
                }
            }
        }
        let actual = truth.series.reduce(0) { $0 + $1.files.count * ($1.files.count - 1) / 2 }

        let sizes = Dictionary(grouping: label.values, by: { $0 }).mapValues(\.count)
        var exact = 0, right = 0, scored = 0
        let keepers = Dictionary(uniqueKeysWithValues: shown.copies.map { (Set($0.map(\.id)), $0[0].id) })
        for series in truth.series {
            guard let k = label[series.files[0]], series.files.allSatisfy({ label[$0] == k }), sizes[k] == series.files.count
            else { continue }
            exact += 1
            if let keeper = keepers[Set(series.files)] {
                scored += 1
                if keeper == series.best { right += 1 }
            }
        }
        return CopyEval(
            pairPrecision: predicted == 0 ? 1 : Double(hit) / Double(predicted),
            pairRecall: actual == 0 ? 1 : Double(hit) / Double(actual),
            falsePairs: predicted - hit,
            setsExact: exact,
            setsTotal: truth.series.count,
            keepersRight: right,
            keepersScored: scored
        )
    }
}

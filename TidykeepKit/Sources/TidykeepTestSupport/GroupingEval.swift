import Foundation
import TidykeepCore

/// Scores found groups against ground truth (`SyntheticLibrary.Truth`, or a hand-labeled
/// `truth.json` for real photos in the same format).
///
/// The measures are the bench's (`score_window` in bench/evaluate.py), so tkscan's numbers and
/// the bench's can be compared directly.
public struct GroupingEval: Codable, Sendable, Equatable {
    /// Of photo pairs put in one group, the share that truly belong together. Pairs the truth
    /// leaves unscored (`Truth.scenes`) count neither way.
    public var pairPrecision: Double
    /// Of photo pairs that truly belong together, the share put in one group.
    public var pairRecall: Double
    /// Pairs put in one group that the truth leaves unscored.
    public var unscoredPairs: Int
    /// Of true series that were found (best Jaccard ≥ 0.5), the share whose keeper is the true best.
    public var keeperAccuracy: Double
    public var seriesFound: Int
    public var seriesTotal: Int
    /// True series whose keeper was wrong: (series index, picked, expected).
    public var wrongKeepers: [String]

    public static func score(groups: [PhotoGroup], truth: SyntheticLibrary.Truth) -> GroupingEval {
        struct Pair: Hashable { var a, b: String }
        func pairs(_ sets: [[String]]) -> Set<Pair> {
            var out = Set<Pair>()
            for set in sets {
                let s = set.sorted()
                for i in s.indices { for j in s.indices where j > i { out.insert(Pair(a: s[i], b: s[j])) } }
            }
            return out
        }
        let actual = pairs(truth.series.map(\.files))
        var predicted = pairs(groups.map { $0.members.map(\.id) })
        let scenes = truth.scenes ?? [:]
        let unscored = predicted.filter { !actual.contains($0) && scenes[$0.a] != nil && scenes[$0.a] == scenes[$0.b] }
        predicted.subtract(unscored)
        let hit = predicted.intersection(actual).count

        var found = 0, right = 0
        var wrong: [String] = []
        for (index, series) in truth.series.enumerated() {
            let truthSet = Set(series.files)
            let best = groups.max { jaccard(Set($0.members.map(\.id)), truthSet) < jaccard(Set($1.members.map(\.id)), truthSet) }
            guard let best, jaccard(Set(best.members.map(\.id)), truthSet) >= 0.5 else { continue }
            found += 1
            if best.keeper.id == series.best {
                right += 1
            } else {
                wrong.append("series \(index): picked \(best.keeper.id), expected \(series.best)")
            }
        }

        return GroupingEval(
            pairPrecision: predicted.isEmpty ? 1 : Double(hit) / Double(predicted.count),
            pairRecall: actual.isEmpty ? 1 : Double(hit) / Double(actual.count),
            unscoredPairs: unscored.count,
            keeperAccuracy: found == 0 ? 0 : Double(right) / Double(found),
            seriesFound: found,
            seriesTotal: truth.series.count,
            wrongKeepers: wrong
        )
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b).count
        return union == 0 ? 0 : Double(a.intersection(b).count) / Double(union)
    }
}

extension SyntheticLibrary.Truth {
    public static let fileName = "truth.json"

    public func write(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    public static func read(from folder: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: folder.appendingPathComponent(fileName)))
    }
}

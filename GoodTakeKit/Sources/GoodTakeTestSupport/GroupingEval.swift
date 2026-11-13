import Foundation
import GoodTakeCore

/// Scores found groups against ground truth (`SyntheticLibrary.Truth`, or a hand-labeled
/// `truth.json` for real photos in the same format).
public struct GroupingEval: Codable, Sendable, Equatable {
    /// Of photo pairs put in one group, the share that truly belong together.
    public var pairPrecision: Double
    /// Of photo pairs that truly belong together, the share put in one group.
    public var pairRecall: Double
    /// Of true series that were found (best Jaccard ≥ 0.5), the share whose keeper is the true best.
    public var keeperAccuracy: Double
    public var seriesFound: Int
    public var seriesTotal: Int
    /// True series whose keeper was wrong: (series index, picked, expected).
    public var wrongKeepers: [String]

    public static func score(groups: [PhotoGroup], truth: SyntheticLibrary.Truth) -> GroupingEval {
        func pairs(_ sets: [[String]]) -> Set<String> {
            var out = Set<String>()
            for set in sets {
                let s = set.sorted()
                for i in s.indices { for j in s.indices where j > i { out.insert(s[i] + "|" + s[j]) } }
            }
            return out
        }
        let predicted = pairs(groups.map { $0.members.map(\.id) })
        let actual = pairs(truth.series.map(\.files))
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

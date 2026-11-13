import Foundation

/// Complete-linkage clustering cut at a distance of 1.
///
/// Clusters are merged closest first, and a cluster's distance to another is its farthest pair,
/// so two clusters only merge when every pair across them is at most 1 apart. That is why one
/// look-alike photo can't chain two copy sets into one, as single linkage would.
///
/// It gives the clusters bench/rules.py does (scipy's `linkage(method="complete")`, then
/// `fcluster(1, "distance")`), by scipy's own method, the nearest-neighbour chain: follow each
/// cluster to its nearest until two are each other's nearest, and merge those. A merge never
/// brings a cluster closer to the rest, so that pair is a merge the closest-first order makes
/// too, and the walk takes time that grows with the square of the points rather than the cube.
/// Pairs over 1 can't affect a cut at 1, so they are all stored as too far, and a cluster with
/// nothing within 1 is set aside for good.
///
/// Ties go as scipy's chain sends them: to the cluster just before in the chain, then to the
/// lowest number. scipy walks the whole library in the bench's order, so it can still break a
/// tie the other way, which changes a cluster only when tied merges compete for one photo.
enum CompleteLinkage {
    /// Distances between the points `0..<count`. A pair that is never set, or is set to more
    /// than 1 (or NaN), is too far to link.
    struct Matrix: Sendable {
        let count: Int
        /// The upper triangle, row by row: 4 bytes a pair, so 4096 points take 32 MB.
        private var values: [Float]

        init(count: Int) {
            self.count = count
            values = [Float](repeating: .infinity, count: count * max(count - 1, 0) / 2)
        }

        subscript(i: Int, j: Int) -> Float {
            get { values[index(i, j)] }
            set { values[index(i, j)] = newValue <= 1 ? newValue : .infinity }
        }

        private func index(_ i: Int, _ j: Int) -> Int {
            precondition(i != j && min(i, j) >= 0 && max(i, j) < count, "no such pair")
            let (a, b) = i < j ? (i, j) : (j, i)
            return a * (2 * count - a - 1) / 2 + b - a - 1
        }
    }

    /// Clusters of two or more of the points, each sorted, ordered by first point. The matrix
    /// is used up: merges overwrite it.
    static func clusters(_ distances: consuming Matrix) -> [[Int]] {
        let n = distances.count
        // A cluster lives in the slot of one of its points; a merge keeps the higher, as in scipy.
        var members: [[Int]] = (0..<n).map { [$0] }
        // Slots that can still merge: not merged away, and not set aside.
        var open = [Bool](repeating: true, count: n)
        var chain: [Int] = []
        var first = 0
        while true {
            if chain.isEmpty {
                while first < n, !open[first] { first += 1 }
                guard first < n else { break }
                chain.append(first)
            }
            let x = chain[chain.count - 1]
            let previous = chain.count > 1 ? chain[chain.count - 2] : -1
            // The nearest open cluster to x, keeping the one before x in the chain on a tie. That
            // one is within 1, so only a chain of one can find nothing.
            var y = previous
            var nearest = previous >= 0 ? distances[x, previous] : .infinity
            for i in 0..<n where open[i] && i != x {
                let d = distances[x, i]
                if d < nearest { (y, nearest) = (i, d) }
            }
            if y < 0 {
                // Nothing within 1, and merges only move clusters apart: x is done.
                open[x] = false
                chain.removeLast()
            } else if y == previous {
                chain.removeLast(2)
                let (gone, kept) = (min(x, y), max(x, y))
                open[gone] = false
                for i in 0..<n where open[i] && i != kept {
                    distances[kept, i] = max(distances[kept, i], distances[gone, i])
                }
                if members[kept].count < members[gone].count { members.swapAt(kept, gone) }
                members[kept] += members[gone]
                members[gone] = []
            } else {
                chain.append(y)
            }
        }
        return members.filter { $0.count >= 2 }.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }
}

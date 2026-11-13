/// Which of the points `0..<count` are linked to each other, through any chain of links.
///
/// The duplicate finder links cards that share a key, so A–B by phone and B–C by email put
/// all three in one group. Each group's points are kept at its root, so the finder can look at
/// a whole group before it links two.
struct UnionFind {
    private var parent: [Int]
    private var members: [[Int]]

    init(count: Int) {
        parent = Array(0..<count)
        members = (0..<count).map { [$0] }
    }

    /// The lowest point linked to `x`, which stands for its group.
    mutating func root(_ x: Int) -> Int {
        var root = x
        while parent[root] != root { root = parent[root] }
        // Point every step of the path straight at the root, so the next lookup is one step.
        var x = x
        while parent[x] != root {
            let next = parent[x]
            parent[x] = root
            x = next
        }
        return root
    }

    /// Every point in `x`'s group, `x` included.
    mutating func members(of x: Int) -> [Int] {
        members[root(x)]
    }

    mutating func link(_ a: Int, _ b: Int) {
        let (ra, rb) = (root(a), root(b))
        guard ra != rb else { return }
        let (kept, joined) = (min(ra, rb), max(ra, rb))
        parent[joined] = kept
        members[kept] += members[joined]
        members[joined] = []
    }

    /// Groups of two or more, each ascending, ordered by first point.
    mutating func groups() -> [[Int]] {
        var slot: [Int: Int] = [:]
        var out: [[Int]] = []
        for x in parent.indices {
            let r = root(x)
            if let k = slot[r] {
                out[k].append(x)
            } else {
                slot[r] = out.count
                out.append([x])
            }
        }
        return out.filter { $0.count >= 2 }
    }
}

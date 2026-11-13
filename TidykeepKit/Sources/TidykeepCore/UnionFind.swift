/// Which of the points `0..<count` are linked to each other, through any chain of links.
///
/// The copy pass uses it to split a library into groups that can be clustered one at a time,
/// keeping only a parent per photo instead of every close pair.
struct UnionFind {
    private var parent: [Int]

    init(count: Int) {
        parent = Array(0..<count)
    }

    /// The lowest point linked to `x`, which stands for its group.
    mutating func root(_ x: Int) -> Int {
        var root = x
        while parent[root] != root { root = parent[root] }
        var x = x
        while parent[x] != root { (x, parent[x]) = (parent[x], root) }
        return root
    }

    mutating func connected(_ a: Int, _ b: Int) -> Bool {
        root(a) == root(b)
    }

    mutating func link(_ a: Int, _ b: Int) {
        let (ra, rb) = (root(a), root(b))
        if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
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

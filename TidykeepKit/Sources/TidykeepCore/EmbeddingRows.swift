import Accelerate

/// Embeddings of one length, dequantized one per row, for finding the close pairs among many.
///
/// Comparing every pair one by one would take minutes for a big library, so rows are compared a
/// block at a time with one matrix product: d² = |a|² + |b|² − 2 a·b. That float32 shortcut only
/// shortlists, with a margin for its rounding. `distance` then measures a pair exactly as
/// `QuantizedEmbedding.distance` does, so what is found doesn't depend on block boundaries.
struct EmbeddingRows {
    /// Rows per block: two 1024 x 384 blocks and their 4 MB product.
    static let block = 1024

    let count: Int
    let dim: Int
    private let rows: [Float]
    private let norms: [Float]

    /// `vectors` must all have the same, nonzero length.
    init(_ vectors: [QuantizedEmbedding]) {
        count = vectors.count
        dim = vectors.first?.count ?? 0
        var rows: [Float] = []
        rows.reserveCapacity(count * dim)
        for v in vectors {
            precondition(v.count == dim, "rows must all be one length")
            rows += v.dequantized()
        }
        let dim = dim
        norms = rows.withUnsafeBufferPointer { p in
            (0..<vectors.count).map { i in
                var sum: Float = 0
                vDSP_svesq(p.baseAddress! + i * dim, 1, &sum, vDSP_Length(dim))
                return sum
            }
        }
        self.rows = rows
    }

    /// The exact distance between rows `i` and `j`.
    func distance(_ i: Int, _ j: Int) -> Float {
        var sum: Float = 0
        rows.withUnsafeBufferPointer { p in
            vDSP_distancesq(p.baseAddress! + i * dim, 1, p.baseAddress! + j * dim, 1, &sum, vDSP_Length(dim))
        }
        return sum.squareRoot()
    }

    /// Calls `visit(i, j)`, `i < j`, for every pair that may be within `reach`: all that are,
    /// and a few just past it. Pairs it skips are farther apart than `reach`.
    func forEachPair(within reach: Float, _ visit: (Int, Int) -> Void) {
        guard count > 1, dim > 0 else { return }
        let reach2 = reach * reach
        let starts = Array(stride(from: 0, to: count, by: Self.block))
        for bi in starts {
            let rowCount = min(Self.block, count - bi)
            for bj in starts where bj >= bi {
                let colCount = min(Self.block, count - bj)
                let dots = products(bi, rowCount, bj, colCount)
                for i in 0..<rowCount {
                    let ni = norms[bi + i]
                    for j in (bi == bj ? i + 1 : 0)..<colCount {
                        let nj = norms[bj + j]
                        // The rounding error of a float32 dot product grows with the lengths.
                        let estimate = ni + nj - 2 * dots[i * colCount + j]
                        if estimate <= reach2 + 1e-3 * (ni + nj) { visit(bi + i, bj + j) }
                    }
                }
            }
        }
    }

    /// Row-major `rowCount x colCount` dot products of two runs of rows.
    private func products(_ r: Int, _ rowCount: Int, _ c: Int, _ colCount: Int) -> [Float] {
        var transposed = [Float](repeating: 0, count: colCount * dim)
        var out = [Float](repeating: 0, count: rowCount * colCount)
        rows.withUnsafeBufferPointer { p in
            vDSP_mtrans(p.baseAddress! + c * dim, 1, &transposed, 1, vDSP_Length(dim), vDSP_Length(colCount))
            vDSP_mmul(p.baseAddress! + r * dim, 1, transposed, 1, &out, 1, vDSP_Length(rowCount), vDSP_Length(colCount), vDSP_Length(dim))
        }
        return out
    }
}

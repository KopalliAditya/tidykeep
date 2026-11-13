import Foundation
@testable import TidykeepCore
import Testing

@Suite struct EmbeddingTests {
    /// 768 values like a revision-2 feature print: unit length, mostly small.
    func randomPrint(_ rng: inout some RandomNumberGenerator) -> [Float] {
        let raw = (0..<768).map { _ in Float.random(in: -1...1, using: &rng) * Float.random(in: 0...1, using: &rng) }
        let norm = raw.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return raw.map { $0 / norm }
    }

    func exactDistance(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }.squareRoot()
    }

    @Test func quantizingAddsLessErrorThanTheThresholdsCouldNotice() {
        var rng = SystemRandomNumberGenerator()
        var worst: Float = 0
        for _ in 0..<200 {
            let a = randomPrint(&rng)
            // A near neighbor and a far one.
            let near = zip(a, randomPrint(&rng)).map { $0 + 0.01 * $1 }
            for b in [near, randomPrint(&rng)] {
                let error = abs(QuantizedEmbedding(a).distance(to: QuantizedEmbedding(b)) - exactDistance(a, b))
                worst = max(worst, error)
            }
        }
        // Grouping thresholds are 0.4 to 0.8 apart; an error of 0.01 can't flip a decision that matters.
        #expect(worst < 0.01)
    }

    @Test func roundTripsThroughCodable() throws {
        let original = QuantizedEmbedding(vector(axis: 2, toward: 5, angle: 0.4))
        let data = try PropertyListEncoder().encode(original)
        let decoded = try PropertyListDecoder().decode(QuantizedEmbedding.self, from: data)
        #expect(decoded == original)
        #expect(decoded.distance(to: original) == 0)
    }

    @Test func storesOneBytePerValue() throws {
        var rng = SystemRandomNumberGenerator()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let size = try encoder.encode(QuantizedEmbedding(randomPrint(&rng))).count
        #expect(size < 900)
    }

    @Test func mismatchedOrEmptyVectorsAreInfinitelyFar() {
        let a = QuantizedEmbedding([1, 0, 0])
        #expect(a.distance(to: QuantizedEmbedding([1, 0])) == .infinity)
        #expect(QuantizedEmbedding([]).distance(to: QuantizedEmbedding([])) == .infinity)
    }

    @Test func zeroVectorDoesNotDivideByZero() {
        let zero = QuantizedEmbedding([0, 0, 0])
        #expect(zero.dequantized() == [0, 0, 0])
        #expect(zero.distance(to: QuantizedEmbedding([0, 0, 0])) == 0)
    }

    @Test func nonFiniteValuesBecomeZero() {
        let e = QuantizedEmbedding([.nan, 1, .infinity])
        #expect(e.dequantized() == [0, 1, 0])
    }

    @Test func circleFixtureHasTheExpectedGeometry() {
        let a = QuantizedEmbedding(vector(axis: 0, angle: 0))
        let b = QuantizedEmbedding(vector(axis: 0, angle: 0.3))
        #expect(abs(a.distance(to: b) - Float(2 * sin(0.15))) < 0.01)
        #expect(abs(scene(0).distance(to: scene(5)) - Float(2).squareRoot()) < 0.01)
    }
}

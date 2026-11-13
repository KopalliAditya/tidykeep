import Accelerate
import Foundation

/// A feature vector stored as int8 with one scale per vector.
///
/// A revision-2 feature print is 768 floats (3 KB). Stored this way it is 772 bytes,
/// so a 50,000-photo library caches in under 40 MB. The distance error this adds is
/// far below the grouping thresholds (see `TidykeepCoreTests`).
public struct QuantizedEmbedding: Sendable, Hashable, Codable {
    public let scale: Float
    public let codes: [Int8]

    public init(_ vector: [Float]) {
        // A NaN or infinity would trap in the Int conversion below.
        let vector = vector.map { $0.isFinite ? $0 : 0 }
        let peak = vector.reduce(Float(0)) { max($0, abs($1)) }
        let scale = peak > 0 ? peak / 127 : 1
        self.scale = scale
        self.codes = vector.map { Int8(clamping: Int(($0 / scale).rounded())) }
    }

    public init(scale: Float, codes: [Int8]) {
        self.scale = scale
        self.codes = codes
    }

    public var count: Int { codes.count }

    public func dequantized() -> [Float] {
        var out = [Float](repeating: 0, count: codes.count)
        vDSP.convertElements(of: codes, to: &out)
        vDSP.multiply(scale, out, result: &out)
        return out
    }

    /// Euclidean distance. Vectors of different length are infinitely far apart.
    public func distance(to other: QuantizedEmbedding) -> Float {
        guard count == other.count, count > 0 else { return .infinity }
        return vDSP.distanceSquared(dequantized(), other.dequantized()).squareRoot()
    }

    private enum CodingKeys: String, CodingKey { case scale, codes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scale = try c.decode(Float.self, forKey: .scale)
        let data = try c.decode(Data.self, forKey: .codes)
        codes = data.map { Int8(bitPattern: $0) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(scale, forKey: .scale)
        try c.encode(Data(codes.map { UInt8(bitPattern: $0) }), forKey: .codes)
    }
}

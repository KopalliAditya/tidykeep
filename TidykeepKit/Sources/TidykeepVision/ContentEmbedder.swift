import Accelerate
import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import Synchronization

/// What a photo shows, as two unit vectors from DINOv2-small (Apache-2.0, bundled).
///
/// One run of the model gives both: the CLS embedding, which finds copies of a picture across
/// the whole library (re-encoded, resized, cropped, rotated, mirrored, recolored, or a
/// screenshot of it), and the mean of the patch embeddings, which tells neighbouring moments
/// of a series apart. The model is a Core ML program with 8-bit palettized weights (about 23 MB);
/// ImageNet normalization and the final L2 normalization are inside it.
///
/// Runs entirely on the device. The first load of the model takes a while (Core ML compiles it
/// for the Neural Engine: 1.5 s on a Mac, then 25 ms once cached), so it starts in the background
/// as soon as the embedder is made and `embed` waits for it. The app's launch never waits.
/// MLModel's async prediction may be called concurrently, so one embedder serves every task.
public final class ContentEmbedder: Sendable {
    public struct Output: Sendable, Equatable {
        /// CLS token after the final layer norm, unit length, 384 floats.
        public let cls: [Float]
        /// Mean of the 256 patch tokens after the final layer norm, unit length, 384 floats.
        public let mean: [Float]
    }

    public enum Failure: Error, Equatable {
        /// The model's `weights` metadata isn't the variant it was loaded as, so `version` would lie.
        case wrongModel(expected: String, found: String?)
        /// An output was missing, the wrong shape, or not a unit vector of finite numbers.
        case badOutput(String)
    }

    public static let dimension = 384
    static let modelName = "DINOv2Small"
    /// The bundled model's weights, as its metadata names them.
    static let bundledVariant = "pal8g"

    /// The compiled model shipped in this package's resources.
    public static var bundledModelURL: URL? { Bundle.module.url(forResource: modelName, withExtension: "mlmodelc") }

    /// The bundled model, shared by every analyzer. It starts loading the first time it is
    /// asked for. Nil only if the package was built without it.
    public static let bundled: ContentEmbedder? = bundledModelURL.map { ContentEmbedder(modelURL: $0, variant: bundledVariant) }

    /// Changes whenever the embeddings would: the weights variant and the framing. Part of
    /// `VisionFrameAnalyzer.version`, so a new model invalidates cached analysis. Known before
    /// the model has loaded, so asking for it never waits.
    public let version: String

    private let modelURL: URL
    private let variant: String
    private let loading: Task<Loaded, any Error>
    private let cpuLoading = Mutex<Task<Loaded, any Error>?>(nil)

    /// Starts loading a compiled model (`.mlmodelc`) with the same inputs and outputs.
    /// `variant` is its `weights` metadata (`pal8g`, `fp16`); a model that says otherwise is
    /// refused, and loading failures show up when `embed` is called.
    public init(modelURL: URL, variant: String, computeUnits: MLComputeUnits = .all) {
        self.modelURL = modelURL
        self.variant = variant
        version = "dinos-\(variant).\(ContentFraming.version)"
        loading = Task.detached(priority: .utility) { try Self.load(modelURL, variant, computeUnits) }
    }

    /// The compute units the model was loaded for: `.all` (Neural Engine, GPU or CPU, as Core
    /// ML sees fit) unless loading for them failed and the CPU-only fallback was used.
    /// Waits for the load, and throws what it threw.
    public var computeUnits: MLComputeUnits {
        get async throws { try await loading.value.computeUnits }
    }

    /// Embeds an upright image of any size. Throws rather than return anything partial or odd:
    /// the result is cached for good.
    public func embed(_ image: CGImage) async throws -> Output {
        let buffer = try ContentFraming.pixelBuffer(for: image)
        let loaded = try await loading.value
        do {
            return try await Self.predict(loaded.model, buffer)
        } catch where loaded.computeUnits != .cpuOnly {
            // The Neural Engine or GPU can refuse work at run time, for instance in the
            // background. The CPU gives nearly the same embedding, so try it once.
            return try await Self.predict(try await cpuFallback().model, buffer)
        }
    }

    // MARK: -

    /// A loaded model. MLModel's prediction is safe to call from many threads at once, but
    /// the class isn't marked Sendable, hence the unchecked box.
    final class Loaded: @unchecked Sendable {
        let model: MLModel
        let computeUnits: MLComputeUnits

        init(model: MLModel, computeUnits: MLComputeUnits) {
            self.model = model
            self.computeUnits = computeUnits
        }
    }

    /// The CPU-only model, loaded the first time it is needed.
    private func cpuFallback() async throws -> Loaded {
        let task = cpuLoading.withLock { task in
            if let task { return task }
            let new = Task.detached(priority: .userInitiated) { [modelURL, variant] in try Self.load(modelURL, variant, .cpuOnly) }
            task = new
            return new
        }
        return try await task.value
    }

    /// Falls back to the CPU when loading for `units` fails, since the CPU can always run it.
    private static func load(_ url: URL, _ variant: String, _ units: MLComputeUnits) throws -> Loaded {
        let loaded: Loaded
        do {
            loaded = Loaded(model: try load(url, units), computeUnits: units)
        } catch where units != .cpuOnly {
            loaded = Loaded(model: try load(url, .cpuOnly), computeUnits: .cpuOnly)
        }
        let metadata = loaded.model.modelDescription.metadata[.creatorDefinedKey] as? [String: String]
        guard metadata?["weights"] == variant else { throw Failure.wrongModel(expected: variant, found: metadata?["weights"]) }
        return loaded
    }

    private static func load(_ url: URL, _ units: MLComputeUnits) throws -> MLModel {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units
        return try MLModel(contentsOf: url, configuration: configuration)
    }

    private static func predict(_ model: MLModel, _ buffer: CVPixelBuffer) async throws -> Output {
        let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)])
        let output = try await model.prediction(from: input)
        return Output(cls: try unitVector(output, "cls_embedding"), mean: try unitVector(output, "mean_embedding"))
    }

    /// A model output as a unit vector. The model normalizes in float16, so the length is
    /// checked loosely and then made exact.
    static func unitVector(_ output: MLFeatureProvider, _ name: String) throws -> [Float] {
        guard let array = output.featureValue(for: name)?.multiArrayValue,
              array.dataType == .float32, array.count == dimension
        else { throw Failure.badOutput(name) }
        let vector = array.withUnsafeBufferPointer(ofType: Float.self) { Array($0.prefix(dimension)) }
        return try normalized(vector, name)
    }

    static func normalized(_ vector: [Float], _ name: String) throws -> [Float] {
        guard vector.count == dimension, vector.allSatisfy(\.isFinite) else { throw Failure.badOutput(name) }
        let length = vDSP.sumOfSquares(vector).squareRoot()
        guard abs(length - 1) < 0.02 else { throw Failure.badOutput(name) }
        return vDSP.divide(vector, length)
    }
}

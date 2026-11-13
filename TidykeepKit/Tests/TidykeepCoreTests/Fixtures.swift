import CoreGraphics
import Foundation
@testable import TidykeepCore
import Synchronization

let t0 = Date(timeIntervalSince1970: 1_767_225_600)

func meta(
    _ id: String, _ seconds: Double, burst: String? = nil, favorite: Bool = false, edited: Bool = false, version: Date? = nil
) -> AssetMeta {
    AssetMeta(
        id: id, creationDate: t0.addingTimeInterval(seconds), contentVersion: version,
        pixelWidth: 4032, pixelHeight: 3024, burstID: burst, isFavorite: favorite, hasAdjustments: edited
    )
}

/// A unit vector on the circle between scene axes `a` and `b`, in 16 dimensions.
/// Two points at angles θ1 and θ2 are 2·sin(|θ1 − θ2| / 2) apart.
func vector(axis a: Int, toward b: Int = 1, angle: Double = 0) -> [Float] {
    var v = [Float](repeating: 0, count: 16)
    v[a] += Float(cos(angle))
    v[b] += Float(sin(angle))
    return v
}

/// A scene: unit vector along one axis, nudged a little so frames aren't identical.
func scene(_ axis: Int, nudge: Double = 0) -> QuantizedEmbedding {
    QuantizedEmbedding(vector(axis: axis, toward: (axis + 1) % 16, angle: nudge))
}

func signals(
    _ embedding: QuantizedEmbedding = scene(0), sharpness: Float = 5, aesthetics: Float? = 0.5,
    faces: [Float] = [], utility: Bool = false
) -> FrameSignals {
    FrameSignals(embedding: embedding, aesthetics: aesthetics, isUtility: utility, sharpness: sharpness, faceQualities: faces)
}

func group(_ members: [(AssetMeta, FrameSignals)]) -> PhotoGroup {
    PhotoGroup(members: members.map { (meta: $0.0, signals: $0.1) })
}

/// An in-memory library. Each photo's image is a 1-pixel-high strip whose width encodes
/// the photo, so `FakeAnalyzer` can return that photo's signals.
final class FakeLibrary: PhotoSource {
    let photos: Mutex<[(meta: AssetMeta, signals: FrameSignals)]>
    let unreadable: Set<String>
    let deletedIDs = Mutex<[String]>([])

    init(_ photos: [(AssetMeta, FrameSignals)], unreadable: Set<String> = []) {
        self.photos = Mutex(photos.map { (meta: $0.0, signals: $0.1) })
        self.unreadable = unreadable
    }

    func replace(_ id: String, with meta: AssetMeta) {
        photos.withLock { list in
            if let i = list.firstIndex(where: { $0.meta.id == id }) { list[i].meta = meta }
        }
    }

    func signals(forWidth width: Int) -> FrameSignals? {
        photos.withLock { list in width >= 1 && width <= list.count ? list[width - 1].signals : nil }
    }

    func access() async -> LibraryAccess { .full }
    func requestAccess() async -> LibraryAccess { .full }
    func changes() -> AsyncStream<Void> { AsyncStream { $0.finish() } }

    func fetchAssets(since: Date?) async throws -> [AssetMeta] {
        photos.withLock { $0.map(\.meta) }.filter { since == nil || $0.creationDate >= since! }
    }

    func analysisImage(for id: String, maxPixelSize: Int) async throws -> CGImage {
        guard !unreadable.contains(id) else { throw PhotoSourceError.notAvailableLocally }
        guard let index = photos.withLock({ $0.firstIndex { $0.meta.id == id } }) else { throw PhotoSourceError.notFound }
        return strip(width: index + 1)
    }

    func thumbnail(for id: String, pixelSize: Int) async -> CGImage? { nil }

    func delete(_ ids: [String]) async -> Set<String> {
        deletedIDs.withLock { $0.append(contentsOf: ids) }
        photos.withLock { $0.removeAll { ids.contains($0.meta.id) } }
        return Set(ids)
    }

    private func strip(width: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        return ctx.makeImage()!
    }
}

final class FakeAnalyzer: FrameAnalyzing {
    let library: FakeLibrary
    let calls = Mutex(0)

    init(_ library: FakeLibrary) { self.library = library }

    var version: String { "fake1" }
    var callCount: Int { calls.withLock { $0 } }

    func analyze(_ image: CGImage) async throws -> FrameSignals {
        calls.withLock { $0 += 1 }
        guard let signals = library.signals(forWidth: image.width) else { throw PhotoSourceError.unreadable }
        return signals
    }
}

func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tidykeep-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

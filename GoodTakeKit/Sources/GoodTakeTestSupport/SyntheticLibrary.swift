import CoreGraphics
import Foundation
import GoodTakeCore

/// Writes a folder that looks like a camera roll with known answers: several series of
/// near-identical frames where exactly one is sharp, plus unrelated single photos,
/// some taken seconds after a series (so time alone can't separate them).
public enum SyntheticLibrary {
    public struct Truth: Codable, Sendable {
        public struct Series: Codable, Sendable {
            public var files: [String]
            public var best: String

            public init(files: [String], best: String) {
                self.files = files
                self.best = best
            }
        }

        public var series: [Series]
        public var singles: [String]

        public init(series: [Series], singles: [String]) {
            self.series = series
            self.singles = singles
        }
    }

    public static func write(
        to folder: URL,
        seriesCount: Int = 6,
        framesPerSeries: ClosedRange<Int> = 3...5,
        singles: Int = 8,
        start: Date = Date(timeIntervalSince1970: 1_767_225_600),  // 2026-01-01
        seed: UInt64 = 42,
        blur: ClosedRange<Double> = 1.0...2.5,
        size: (width: Int, height: Int) = (1024, 768)
    ) throws -> Truth {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var rng = SplitMix64(seed: seed)
        var manifest: [String: FolderPhotoManifestEntry] = [:]
        var truth = Truth(series: [], singles: [])

        for s in 0..<seriesCount {
            let scene = SyntheticScene(seed: seed &+ UInt64(s) &* 1_000)
            let base = start.addingTimeInterval(Double(s) * 3_600)
            let n = Int.random(in: framesPerSeries, using: &rng)
            let bestIndex = Int.random(in: 0..<n, using: &rng)
            var files: [String] = []
            for f in 0..<n {
                let name = String(format: "series%02d_frame%d.jpg", s, f)
                let shift = CGPoint(x: Double.random(in: -8...8, using: &rng), y: Double.random(in: -8...8, using: &rng))
                let image = f == bestIndex
                    ? scene.render(width: size.width, height: size.height)
                    : scene.render(width: size.width, height: size.height, shift: shift, blur: Double.random(in: blur, using: &rng))
                try SyntheticScene.writeJPEG(image, to: folder.appendingPathComponent(name))
                manifest[name] = FolderPhotoManifestEntry(date: base.addingTimeInterval(Double(f) * 2))
                files.append(name)
            }
            truth.series.append(.init(files: files, best: files[bestIndex]))

            // A different scene seconds after the series: close in time, nothing alike.
            if s < singles {
                let name = String(format: "single%02d.jpg", s)
                let image = SyntheticScene(seed: seed &+ 77_777 &+ UInt64(s)).render(width: size.width, height: size.height)
                try SyntheticScene.writeJPEG(image, to: folder.appendingPathComponent(name))
                manifest[name] = FolderPhotoManifestEntry(date: base.addingTimeInterval(Double(n) * 2 + 6))
                truth.singles.append(name)
            }
        }
        for k in seriesCount..<max(seriesCount, singles) {
            let name = String(format: "single%02d.jpg", k)
            let image = SyntheticScene(seed: seed &+ 77_777 &+ UInt64(k)).render(width: size.width, height: size.height)
            try SyntheticScene.writeJPEG(image, to: folder.appendingPathComponent(name))
            manifest[name] = FolderPhotoManifestEntry(date: start.addingTimeInterval(-Double(k + 1) * 86_400))
            truth.singles.append(name)
        }

        try writeManifest(manifest, to: folder)
        return truth
    }
}

/// Mirrors `FolderPhotoSource.Manifest` without depending on that target.
struct FolderPhotoManifestEntry: Codable {
    var date: Date
    var burst: String?
    var favorite: Bool?
    var edited: Bool?

    init(date: Date) { self.date = date }
}

func writeManifest(_ files: [String: FolderPhotoManifestEntry], to folder: URL) throws {
    struct Manifest: Codable { var files: [String: FolderPhotoManifestEntry] }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(Manifest(files: files)).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
}

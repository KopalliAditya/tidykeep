import Foundation
import TidykeepCore
import TidykeepFolderSource
import TidykeepTestSupport
import TidykeepVision
import Testing

func temporaryDirectory(_ name: String = UUID().uuidString) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tidykeep-\(name)", isDirectory: true)
    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct ScanRun {
    var groups: [PhotoGroup] = []
    var copies: [PhotoGroup] = []
    var finished: ScanProgress?
}

func scanFolder(_ folder: URL, sensitivity: Sensitivity, store: AnalysisStore? = nil) async throws -> ScanRun {
    let analyzer = VisionFrameAnalyzer()
    // Drawn shapes all look alike to the content model, so the copy pass would join the
    // single photos to series. It is measured on real photos instead (bench/rules.py).
    let scanner = Scanner(
        source: FolderPhotoSource(folder: folder), analyzer: analyzer,
        store: store ?? AnalysisStore(url: nil, analyzerVersion: analyzer.version), findsCopies: false
    )
    var run = ScanRun()
    for try await event in scanner.scan(scope: .everything, config: sensitivity.config) {
        switch event {
        case .results(let r): (run.groups, run.copies) = (r.similar, r.copies)
        case .finished(let p): run.finished = p
        default: break
        }
    }
    return run
}

/// The whole engine — folder source, Vision, cache, grouping, ranking — on generated photos
/// with known answers. Drawn shapes all look alike to Vision, so these use Strict; the
/// thresholds themselves are checked on real photos below.
@Suite(.serialized) struct SyntheticLibraryTests {
    @Test func findsEverySeriesAndItsSharpFrame() async throws {
        let folder = temporaryDirectory("synthetic")
        let truth = try SyntheticLibrary.write(to: folder)
        let run = try await scanFolder(folder, sensitivity: .strict)
        let eval = GroupingEval.score(groups: run.groups, truth: truth)
        #expect(eval.pairPrecision == 1)
        #expect(eval.pairRecall == 1)
        #expect(eval.keeperAccuracy == 1, "wrong keepers: \(eval.wrongKeepers)")
        #expect(eval.seriesFound == truth.series.count)
    }

    @Test func aSecondScanAnalyzesNothing() async throws {
        let folder = temporaryDirectory("cache")
        _ = try SyntheticLibrary.write(to: folder, seriesCount: 3, singles: 2)
        let cache = folder.appendingPathComponent(".analysis.plist")
        let version = VisionFrameAnalyzer().version

        let first = try await scanFolder(folder, sensitivity: .strict, store: AnalysisStore(url: cache, analyzerVersion: version))
        let second = try await scanFolder(folder, sensitivity: .strict, store: AnalysisStore(url: cache, analyzerVersion: version))
        #expect((first.finished?.toAnalyze ?? 0) > 0)
        #expect(second.finished?.toAnalyze == 0)
        #expect(second.groups.map(\.id) == first.groups.map(\.id))
    }
}

/// The calibration check, as a test: real photos made into handheld bursts with shake and
/// focus blur, at the shipping (Balanced) setting. Uses the profile pictures that ship with
/// macOS, so it runs only where they exist.
@Suite(.serialized, .enabled(if: RealPhotos.available)) struct RealPhotoTests {
    @Test func balancedGroupsRealBurstsAndPicksTheSharpFrame() async throws {
        let folder = temporaryDirectory("real")
        let (series, singles) = RealPhotos.sources()
        let truth = try BurstLibrary.write(series: series, singles: singles, to: folder)
        let run = try await scanFolder(folder, sensitivity: .balanced)
        let eval = GroupingEval.score(groups: run.groups, truth: truth)
        print(String(
            format: "real photos, balanced: precision %.3f  recall %.3f  keeper %.3f  series %d/%d",
            eval.pairPrecision, eval.pairRecall, eval.keeperAccuracy, eval.seriesFound, eval.seriesTotal
        ))
        #expect(eval.pairPrecision >= 0.98)
        #expect(eval.pairRecall >= 0.98)
        #expect(eval.keeperAccuracy >= 0.95, "wrong keepers: \(eval.wrongKeepers)")
        // A single photo must never be offered for removal.
        let grouped = Set(run.groups.flatMap { $0.members.map(\.id) })
        #expect(grouped.isDisjoint(with: truth.singles))
    }
}

enum RealPhotos {
    static let folder = URL(fileURLWithPath: "/Library/User Pictures")

    static var available: Bool { !all().isEmpty }

    static func all() -> [URL] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { ["heic", "jpg", "jpeg", "png", "tif"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.path < $1.path }
    }

    /// Every third picture is a one-off photo; the rest become bursts.
    static func sources() -> (series: [BurstLibrary.Source], singles: [URL]) {
        var series: [BurstLibrary.Source] = [], singles: [URL] = []
        for (i, url) in all().enumerated() {
            if i % 3 == 2 {
                singles.append(url)
            } else {
                let name = url.deletingLastPathComponent().lastPathComponent + "-" + url.deletingPathExtension().lastPathComponent
                series.append(.init(name: name, frames: [url]))
            }
        }
        return (series, singles)
    }
}

@Suite struct FolderSourceTests {
    @Test func readsDatesAndFlagsFromTheManifestAndDeletesIntoABin() async throws {
        let folder = temporaryDirectory()
        let image = SyntheticScene(seed: 1).render(width: 320, height: 240)
        for name in ["a.jpg", "b.jpg", "c.jpg"] { try SyntheticScene.writeJPEG(image, to: folder.appendingPathComponent(name)) }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        try FolderPhotoSource.Manifest(files: [
            "a.jpg": .init(date: date, favorite: true),
            "b.jpg": .init(date: date.addingTimeInterval(1), burst: "X", edited: true),
        ]).write(to: folder)

        let source = FolderPhotoSource(folder: folder)
        let metas = try await source.fetchAssets(since: nil)
        #expect(metas.map(\.id).sorted() == ["a.jpg", "b.jpg", "c.jpg"])
        let a = try #require(metas.first { $0.id == "a.jpg" }), b = try #require(metas.first { $0.id == "b.jpg" })
        #expect(a.creationDate == date && a.isFavorite && !a.hasAdjustments)
        #expect(b.burstID == "X" && b.hasAdjustments)
        #expect(a.pixelWidth == 320 && a.pixelHeight == 240)
        #expect(try await source.fetchAssets(since: date.addingTimeInterval(0.5)).map(\.id).contains("b.jpg"))

        let image2 = try await source.analysisImage(for: "a.jpg", maxPixelSize: 160)
        #expect(max(image2.width, image2.height) <= 160)

        // The favorite and the edited photo are kept, like PhotoKit's source does.
        #expect(await source.delete(["a.jpg", "b.jpg", "c.jpg", "missing.jpg"]) == ["c.jpg"])
        #expect(try await source.fetchAssets(since: nil).map(\.id).sorted() == ["a.jpg", "b.jpg"])
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".removed/c.jpg").path))
        #expect(await source.existing(["a.jpg", "c.jpg"]) == ["a.jpg"])
    }
}

@Suite struct GroupingEvalTests {
    func member(_ id: String, sharpness: Float) -> (meta: AssetMeta, signals: FrameSignals) {
        (AssetMeta(id: id, creationDate: Date(timeIntervalSince1970: 0)),
         FrameSignals(embedding: QuantizedEmbedding([1, 0]), aesthetics: 0, isUtility: false, sharpness: sharpness, faceQualities: []))
    }

    let truth = SyntheticLibrary.Truth(series: [.init(files: ["a", "b", "c"], best: "a"), .init(files: ["x", "y"], best: "y")], singles: ["s"])

    @Test func perfectGroupsScorePerfectly() {
        let groups = [
            PhotoGroup(members: [member("a", sharpness: 9), member("b", sharpness: 1), member("c", sharpness: 1)]),
            PhotoGroup(members: [member("x", sharpness: 1), member("y", sharpness: 9)]),
        ]
        let eval = GroupingEval.score(groups: groups, truth: truth)
        #expect(eval.pairPrecision == 1 && eval.pairRecall == 1 && eval.keeperAccuracy == 1 && eval.seriesFound == 2)
    }

    @Test func mergedAndMissedGroupsAreCaught() {
        // One group swallows a single and half of another series; the rest is missed.
        let groups = [PhotoGroup(members: [member("a", sharpness: 1), member("b", sharpness: 9), member("c", sharpness: 1), member("s", sharpness: 1)])]
        let eval = GroupingEval.score(groups: groups, truth: truth)
        #expect(eval.pairPrecision == 0.5)
        #expect(eval.pairRecall == 0.75)
        #expect(eval.seriesFound == 1)
        #expect(eval.wrongKeepers.count == 1)
    }

    @Test func truthRoundTrips() throws {
        let folder = temporaryDirectory()
        try truth.write(to: folder)
        let read = try SyntheticLibrary.Truth.read(from: folder)
        #expect(read.series.map(\.files) == truth.series.map(\.files))
        #expect(read.singles == truth.singles)
    }
}

import AVFoundation
import Foundation
import TidykeepCore
import TidykeepFolderSource
import TidykeepTestSupport
import TidykeepVision

/// tkscan: run the app's engine on a folder of images, on a Mac.
///
///   tkscan scan <folder> [--sensitivity strict|balanced|loose] [--json]
///   tkscan eval <folder> [--sensitivity ...]     folder must contain truth.json
///     scan, eval and sweep also take --features <file.jsonl> (signals to use instead of analyzing)
///     and --link / --anchor (override the preset's distances)
///   tkscan distances <folder>                    feature-print distances between neighbors in time
///   tkscan demo <folder>                         write a synthetic library with truth.json
///   tkscan frames <video> <folder>               consecutive frames at several moments, one subfolder each
///   tkscan bursts <folder> <sources>             a library with truth.json built from real photos
///   tkscan calibrate <folder>                    distance distributions against truth.json
///   tkscan sweep <folder>                        eval across grouping thresholds (analyzes once)
///   tkscan features <folder|list.txt> <out.jsonl> the app's analysis of each image, one JSON line each
///   tkscan rank <folder> <groups.json> <out.json> rank given groups with the app's scorer, best first
let usage = """
usage:
  tkscan scan <folder> [--sensitivity strict|balanced|loose] [--json] [--features <file.jsonl>] [--link <d>] [--anchor <d>]
  tkscan eval <folder> [--sensitivity strict|balanced|loose] [--features <file.jsonl>] [--link <d>] [--anchor <d>]
  tkscan distances <folder>
  tkscan demo <folder>
  tkscan frames <video> <folder> [--moments 8] [--frames 3] [--step 0.3]
  tkscan bursts <folder> <sources> [--singles-every 3]
  tkscan calibrate <folder>
  tkscan sweep <folder>
  tkscan features <folder|list.txt> <out.jsonl>
  tkscan rank <folder> <groups.json> <out.json>

features: list.txt has one image path per line, relative to the list's folder or absolute.
--features: lines as written by `tkscan features` ({"id", "embedding", "sharpness", "aesthetics",
  "isUtility", "faceQualities"}), one per image in the folder. Those signals fill the cache, so
  nothing is analyzed and the scan groups with that embedding: to try another embedding in the
  app's pipeline. --link / --anchor are Euclidean distances in that embedding's space.
rank: groups.json is [[file, ...], ...] or {"groups": [[file, ...], ...]}, files in <folder>.
GT_SOFTEN=<fraction> overrides the analyzer's softening (0 turns it off).
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// The sensitivity preset, with --link and --anchor overriding its distances.
func groupingConfig(_ sensitivity: Sensitivity) -> GroupingConfig {
    var config = sensitivity.config
    if let raw = option("--link", in: args) {
        guard let value = Float(raw), value > 0 else { fail("bad --link \(raw)") }
        config.linkDistance = value
    }
    if let raw = option("--anchor", in: args) {
        guard let value = Float(raw), value > 0 else { fail("bad --anchor \(raw)") }
        config.anchorDistance = value
    }
    return config
}

/// An in-memory cache, filled from --features when given, so the scan uses those signals
/// instead of analyzing. Every image in the folder needs a line.
func makeStore(for folder: URL, analyzerVersion: String) async throws -> AnalysisStore {
    let store = AnalysisStore(url: nil, analyzerVersion: analyzerVersion)
    guard let path = option("--features", in: args) else { return store }
    struct Line: Decodable {
        var id: String
        var embedding: [Float]
        var sharpness: Float
        var aesthetics: Float?
        var isUtility: Bool
        var faceQualities: [Float]
    }
    var lines: [String: Line] = [:]
    for raw in try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isNewline) where !raw.isEmpty {
        let line = try JSONDecoder().decode(Line.self, from: Data(raw.utf8))
        lines[line.id] = line
    }
    for meta in try await FolderPhotoSource(folder: folder).fetchAssets(since: nil) {
        guard let line = lines[meta.id] else { fail("--features has no line for \(meta.id)") }
        let signals = FrameSignals(embedding: QuantizedEmbedding(line.embedding), aesthetics: line.aesthetics,
                                   isUtility: line.isUtility, sharpness: line.sharpness, faceQualities: line.faceQualities)
        await store.put(signals, for: meta)
    }
    return store
}

func scanFolder(_ folder: URL, config: GroupingConfig) async throws -> (groups: [PhotoGroup], progress: ScanProgress) {
    let analyzer = makeAnalyzer()
    let scanner = Scanner(
        source: FolderPhotoSource(folder: folder),
        analyzer: analyzer,
        store: try await makeStore(for: folder, analyzerVersion: analyzer.version)
    )
    var groups: [PhotoGroup] = []
    var progress = ScanProgress()
    for try await event in scanner.scan(scope: .everything, config: config) {
        switch event {
        case .groups(let g): groups = g
        case .finished(let p): progress = p
        default: break
        }
    }
    return (groups.sorted { $0.startDate < $1.startDate }, progress)
}

/// Every image in a folder, by name; each subfolder of images is one multi-frame source.
func burstSources(_ folder: URL) throws -> (series: [BurstLibrary.Source], singles: [URL], everyN: Int) {
    let fm = FileManager.default
    let images: Set<String> = ["jpg", "jpeg", "heic", "png"]
    func list(_ url: URL) throws -> [URL] {
        try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    var series: [BurstLibrary.Source] = []
    var singles: [URL] = []
    let everyN = Int(option("--singles-every", in: args) ?? "3") ?? 3
    var stills = 0
    for url in try list(folder) {
        let name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: " ", with: "-")
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let frames = try list(url).filter { images.contains($0.pathExtension.lowercased()) }
            if frames.count > 1 { series.append(.init(name: name, frames: frames)) }
        } else if images.contains(url.pathExtension.lowercased()) {
            stills += 1
            if stills % everyN == 0 { singles.append(url) } else { series.append(.init(name: name, frames: [url])) }
        }
    }
    return (series, singles, everyN)
}

func percentiles(_ values: [Float]) -> String {
    guard !values.isEmpty else { return "none" }
    let s = values.sorted()
    func p(_ q: Double) -> Float { s[min(s.count - 1, Int((Double(s.count - 1) * q).rounded()))] }
    return String(format: "n=%3d  min %.3f  p10 %.3f  p50 %.3f  p90 %.3f  max %.3f", s.count, p(0), p(0.1), p(0.5), p(0.9), p(1))
}

/// GT_SOFTEN overrides the analyzer's softening, for calibration.
func makeAnalyzer() -> VisionFrameAnalyzer {
    guard let raw = ProcessInfo.processInfo.environment["GT_SOFTEN"], let value = Double(raw) else { return VisionFrameAnalyzer() }
    return VisionFrameAnalyzer(softening: value)
}

/// One ranked group, best first, as JSON.
struct RankedGroup: Encodable {
    var keeper: String
    var reasons: [String]
    var closeCall: Bool
    var ranked: [String]
    var scores: [Double]

    init(_ g: PhotoGroup) {
        keeper = g.keeper.id
        reasons = g.ranking.reasons.map { $0.rawValue }
        closeCall = g.ranking.isCloseCall
        ranked = g.ranking.orderedIDs
        scores = g.ranking.scores.map { ($0.total * 1000).rounded() / 1000 }
    }
}

func prettyJSON(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(value)
}

/// The images of a folder (what the app would see), or the paths listed in a text file.
/// Each comes with a folder source for its own folder, so it is read exactly as the app reads it.
func imageList(_ url: URL) async throws -> [(source: FolderPhotoSource, id: String)] {
    if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
        let source = FolderPhotoSource(folder: url)
        return try await source.fetchAssets(since: nil).map { (source, $0.id) }
    }
    let base = url.deletingLastPathComponent()
    return try String(contentsOf: url, encoding: .utf8)
        .split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .map { line in
            let file = line.hasPrefix("/") ? URL(fileURLWithPath: line) : base.appendingPathComponent(line)
            return (FolderPhotoSource(folder: file.deletingLastPathComponent()), file.lastPathComponent)
        }
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { fail(usage) }
let command = args[0]
let folder = URL(fileURLWithPath: args[1], isDirectory: true)
func parseSensitivity(_ raw: String?) -> Sensitivity {
    guard let raw else { return .balanced }
    guard let value = Sensitivity(rawValue: raw) else { fail("unknown sensitivity \(raw)") }
    return value
}
let sensitivity = parseSensitivity(option("--sensitivity", in: args))

switch command {
case "scan":
    let config = groupingConfig(sensitivity)
    let (groups, progress) = try await scanFolder(folder, config: config)
    if args.contains("--json") {
        struct Out: Encodable {
            var photos: Int
            var analyzed: Int
            var config: GroupingConfig
            var groups: [RankedGroup]
        }
        let out = Out(photos: progress.photosInRange, analyzed: progress.analyzed, config: config,
                      groups: groups.map(RankedGroup.init))
        print(String(decoding: try prettyJSON(out), as: UTF8.self))
    } else {
        print("\(progress.photosInRange) photos, \(progress.analyzed) analyzed, \(groups.count) groups")
        for (i, g) in groups.enumerated() {
            let others = g.members.dropFirst().map { $0.id }.joined(separator: ", ")
            let reasons = g.ranking.reasons.map { $0.phrase }.joined(separator: ", ")
            print("\(i + 1). keep \(g.keeper.id) (\(reasons))\(g.ranking.isCloseCall ? " [close call]" : "")\n   remove \(others)")
        }
    }

case "eval":
    let truth = try SyntheticLibrary.Truth.read(from: folder)
    let (groups, _) = try await scanFolder(folder, config: groupingConfig(sensitivity))
    let eval = GroupingEval.score(groups: groups, truth: truth)
    print(String(format: "pair precision %.3f  pair recall %.3f  keeper accuracy %.3f  series found %d/%d",
                 eval.pairPrecision, eval.pairRecall, eval.keeperAccuracy, eval.seriesFound, eval.seriesTotal))
    eval.wrongKeepers.forEach { print("  wrong keeper: \($0)") }

case "distances":
    let source = FolderPhotoSource(folder: folder)
    let analyzer = makeAnalyzer()
    let metas = try await source.fetchAssets(since: nil)
    var previous: (AssetMeta, FrameSignals)?
    for meta in metas {
        let signals = try await analyzer.analyze(try await source.analysisImage(for: meta.id, maxPixelSize: Scanner.analysisPixelSize))
        if let (pm, ps) = previous {
            let gap = meta.creationDate.timeIntervalSince(pm.creationDate)
            print(String(format: "%-28@ -> %-28@ gap %7.1fs  distance %.3f", pm.id, meta.id, gap, ps.embedding.distance(to: signals.embedding)))
        }
        print(String(format: "    %@: sharpness %.2f  aesthetics %@  faces %d%@", meta.id, signals.sharpness,
                     signals.aesthetics.map { String(format: "%.3f", $0) } ?? "n/a", signals.faceQualities.count,
                     signals.isUtility ? "  UTILITY" : ""))
        previous = (meta, signals)
    }

case "demo":
    let truth = try SyntheticLibrary.write(to: folder)
    try truth.write(to: folder)
    print("wrote \(truth.series.count) series and \(truth.singles.count) single photos to \(folder.path)")

case "frames":
    guard args.count >= 3 else { fail(usage) }
    let out = URL(fileURLWithPath: args[2], isDirectory: true)
    let asset = AVURLAsset(url: folder)
    let duration = try await asset.load(.duration).seconds
    let moments = Int(option("--moments", in: args) ?? "8") ?? 8
    let frames = Int(option("--frames", in: args) ?? "3") ?? 3
    let step = Double(option("--step", in: args) ?? "0.3") ?? 0.3
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    generator.maximumSize = CGSize(width: 1920, height: 1920)
    for m in 0..<moments {
        let base = duration * (Double(m) + 0.5) / Double(moments)
        let dir = out.appendingPathComponent(String(format: "video%02d", m), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in 0..<frames {
            let (image, _) = try await generator.image(at: CMTime(seconds: base + Double(f) * step, preferredTimescale: 600))
            try SyntheticScene.writeJPEG(image, to: dir.appendingPathComponent("frame\(f).jpg"))
        }
    }
    print("wrote \(moments) moments of \(frames) frames from a \(Int(duration))s video to \(out.path)")

case "bursts":
    guard args.count >= 3 else { fail(usage) }
    let (series, singles, _) = try burstSources(URL(fileURLWithPath: args[2], isDirectory: true))
    let truth = try BurstLibrary.write(series: series, singles: singles, to: folder)
    try truth.write(to: folder)
    print("wrote \(truth.series.count) series and \(truth.singles.count) single photos to \(folder.path)")

case "sweep":
    let truth = try SyntheticLibrary.Truth.read(from: folder)
    let analyzer = makeAnalyzer()
    let scanner = Scanner(source: FolderPhotoSource(folder: folder), analyzer: analyzer,
                          store: try await makeStore(for: folder, analyzerVersion: analyzer.version))
    let base = sensitivity.config
    for link in stride(from: 0.25, through: 0.751, by: 0.05) {
        for slack in [0.05, 0.10, 0.15] {
            var config = base
            config.linkDistance = Float(link)
            config.anchorDistance = Float(link + slack)
            var groups: [PhotoGroup] = []
            for try await event in scanner.scan(scope: .everything, config: config) {
                if case .groups(let g) = event { groups = g }
            }
            let e = GroupingEval.score(groups: groups, truth: truth)
            print(String(format: "link %.2f anchor %.2f   precision %.3f  recall %.3f  keeper %.3f  found %d/%d",
                         link, link + slack, e.pairPrecision, e.pairRecall, e.keeperAccuracy, e.seriesFound, e.seriesTotal))
        }
    }

case "calibrate":
    let truth = try SyntheticLibrary.Truth.read(from: folder)
    let source = FolderPhotoSource(folder: folder)
    let analyzer = makeAnalyzer()
    let metas = try await source.fetchAssets(since: nil).sorted { $0.creationDate < $1.creationDate }
    var signals: [String: FrameSignals] = [:]
    for meta in metas {
        signals[meta.id] = try await analyzer.analyze(try await source.analysisImage(for: meta.id, maxPixelSize: Scanner.analysisPixelSize))
    }
    var seriesOf: [String: Int] = [:]
    for (i, s) in truth.series.enumerated() { s.files.forEach { seriesOf[$0] = i } }
    func d(_ a: String, _ b: String) -> Float { signals[a]!.embedding.distance(to: signals[b]!.embedding) }

    var sameAll: [Float] = [], sameSharpBlur: [Float] = [], sameBlurBlur: [Float] = []
    for s in truth.series {
        for i in s.files.indices { for j in s.files.indices where j > i {
            let v = d(s.files[i], s.files[j])
            sameAll.append(v)
            if s.files[i] == s.best || s.files[j] == s.best { sameSharpBlur.append(v) } else { sameBlurBlur.append(v) }
        } }
    }
    // Different moments that are neighbors in time: what the visual check has to reject.
    var neighbors: [Float] = []
    var closest: [(Float, String)] = []
    for (a, b) in zip(metas, metas.dropFirst()) where seriesOf[a.id] == nil || seriesOf[a.id] != seriesOf[b.id] {
        neighbors.append(d(a.id, b.id))
        closest.append((d(a.id, b.id), "\(a.id) ~ \(b.id)"))
    }
    var loosest: [(Float, String)] = []
    for s in truth.series {
        for i in s.files.indices { for j in s.files.indices where j > i { loosest.append((d(s.files[i], s.files[j]), "\(s.files[i]) ~ \(s.files[j])")) } }
    }
    var allDifferent: [Float] = []
    for i in metas.indices { for j in metas.indices where j > i {
        let a = metas[i].id, b = metas[j].id
        if seriesOf[a] == nil || seriesOf[a] != seriesOf[b] { allDifferent.append(d(a, b)) }
    } }
    print("same moment, any pair      \(percentiles(sameAll))")
    print("  sharp vs blurred         \(percentiles(sameSharpBlur))")
    print("  blurred vs blurred       \(percentiles(sameBlurBlur))")
    print("different, next in time    \(percentiles(neighbors))")
    print("different, any pair        \(percentiles(allDifferent))")
    for (v, label) in closest.sorted(by: { $0.0 < $1.0 }).prefix(5) { print(String(format: "  close but different %.3f  %@", v, label)) }
    for (v, label) in loosest.sorted(by: { $0.0 > $1.0 }).prefix(5) { print(String(format: "  far but same       %.3f  %@", v, label)) }
    let sorted = allDifferent.sorted()
    for (label, q) in [("1%", 0.01), ("5%", 0.05)] where !sorted.isEmpty {
        print(String(format: "  %@ of different pairs are closer than %.3f", label, sorted[Int(Double(sorted.count - 1) * q)]))
    }

case "features":
    // For comparing the feature print with other embeddings: per image, the feature print as the
    // app stores it (int8, dequantized here) and the ranking signals. "ms" times analyze() alone.
    guard args.count >= 3 else { fail(usage) }
    struct Line: Encodable {
        var id: String
        var embedding: [Float]
        var sharpness: Float
        var aesthetics: Float?
        var isUtility: Bool
        var faceQualities: [Float]
        var ms: Double
    }
    let images = try await imageList(folder)
    let analyzer = makeAnalyzer()
    let outURL = URL(fileURLWithPath: args[2])
    FileManager.default.createFile(atPath: outURL.path, contents: nil)
    let out = try FileHandle(forWritingTo: outURL)
    var failed = 0
    for (n, (source, id)) in images.enumerated() {
        do {
            let image = try await source.analysisImage(for: id, maxPixelSize: Scanner.analysisPixelSize)
            let start = ContinuousClock.now
            let s = try await analyzer.analyze(image)
            let ms = (ContinuousClock.now - start) / .milliseconds(1)
            let line = Line(id: id, embedding: s.embedding.dequantized(), sharpness: s.sharpness, aesthetics: s.aesthetics,
                            isUtility: s.isUtility, faceQualities: s.faceQualities, ms: ms)
            try out.write(contentsOf: try JSONEncoder().encode(line) + Data("\n".utf8))
        } catch {
            failed += 1
            FileHandle.standardError.write(Data("skipped \(id): \(error)\n".utf8))
        }
        if (n + 1) % 200 == 0 { FileHandle.standardError.write(Data("\(n + 1)/\(images.count)\n".utf8)) }
    }
    try out.close()
    FileHandle.standardError.write(Data("analyzed \(images.count - failed) of \(images.count) images (\(analyzer.version))\n".utf8))
    if failed > 0 { exit(1) }

case "rank":
    // Ranks known groups with the app's PhotoGroup and ShotScorer, for scoring best-shot picks.
    // No favorites or edits, so the ranking is the analysis alone.
    guard args.count >= 4 else { fail(usage) }
    struct Groups: Decodable { var groups: [[String]] }
    let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
    let groups = try (try? JSONDecoder().decode([[String]].self, from: data)) ?? JSONDecoder().decode(Groups.self, from: data).groups
    let source = FolderPhotoSource(folder: folder)
    let analyzer = makeAnalyzer()
    var signals: [String: FrameSignals] = [:]
    var ranked: [RankedGroup] = []
    for files in groups {
        guard !files.isEmpty, Set(files).count == files.count else { fail("a group must list distinct files: \(files)") }
        var members: [(meta: AssetMeta, signals: FrameSignals)] = []
        for id in files {
            if signals[id] == nil {
                signals[id] = try await analyzer.analyze(try await source.analysisImage(for: id, maxPixelSize: Scanner.analysisPixelSize))
            }
            members.append((AssetMeta(id: id, creationDate: Date(timeIntervalSince1970: 0)), signals[id]!))
        }
        ranked.append(RankedGroup(PhotoGroup(members: members)))
    }
    struct Out: Encodable { var analyzer: String; var groups: [RankedGroup] }
    try prettyJSON(Out(analyzer: analyzer.version, groups: ranked)).write(to: URL(fileURLWithPath: args[3]), options: .atomic)
    print("ranked \(ranked.count) groups of \(signals.count) photos")

default:
    fail(usage)
}

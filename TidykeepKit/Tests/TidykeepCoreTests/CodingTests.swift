import Foundation
@testable import TidykeepCore
import Testing

/// What builds from before the content model wrote must still load, and what this build
/// writes must come back whole.
@Suite struct CodingTests {
    @Test func signalsWrittenBeforeTheContentModelDecodeWithoutIt() throws {
        // "AQL/" is the bytes 1, 2, 255.
        let json = #"{"embedding":{"scale":0.5,"codes":"AQL/"},"aesthetics":0.25,"isUtility":false,"sharpness":5,"faceQualities":[0.75]}"#
        let decoded = try JSONDecoder().decode(FrameSignals.self, from: Data(json.utf8))
        #expect(decoded.embedding == QuantizedEmbedding(scale: 0.5, codes: [1, 2, -1]))
        #expect(decoded.aesthetics == 0.25 && decoded.sharpness == 5 && decoded.faceQualities == [0.75])
        #expect(decoded.dinoCLS == nil && decoded.dinoMean == nil)
    }

    @Test func metadataWrittenBeforeScreenshotsDecodesAsNotAScreenshot() throws {
        let json = #"{"id":"a","creationDate":0,"pixelWidth":4032,"pixelHeight":3024,"isFavorite":true,"hasAdjustments":false}"#
        let decoded = try JSONDecoder().decode(AssetMeta.self, from: Data(json.utf8))
        #expect(decoded == AssetMeta(id: "a", creationDate: Date(timeIntervalSinceReferenceDate: 0), pixelWidth: 4032, pixelHeight: 3024, isFavorite: true))
        #expect(!decoded.isScreenshot)
    }

    @Test func contentEmbeddingsAndScreenshotsRoundTrip() throws {
        let s = FrameSignals(
            embedding: scene(0), aesthetics: nil, isUtility: true, sharpness: 2, faceQualities: [],
            dinoCLS: scene(1), dinoMean: scene(2, nudge: 0.3)
        )
        let m = AssetMeta(id: "b", creationDate: t0, pixelWidth: 1170, pixelHeight: 2532, isScreenshot: true)
        #expect(try JSONDecoder().decode(FrameSignals.self, from: JSONEncoder().encode(s)) == s)
        #expect(try PropertyListDecoder().decode(FrameSignals.self, from: PropertyListEncoder().encode(s)) == s)
        #expect(try JSONDecoder().decode(AssetMeta.self, from: JSONEncoder().encode(m)) == m)
    }

    @Test func theStoreKeepsContentEmbeddings() async throws {
        let url = temporaryDirectory().appendingPathComponent("analysis.plist")
        let s = FrameSignals(
            embedding: scene(0), aesthetics: 0.1, isUtility: false, sharpness: 4, faceQualities: [0.5],
            dinoCLS: scene(3), dinoMean: scene(4)
        )
        let store = AnalysisStore(url: url, analyzerVersion: "v1")
        await store.put(s, for: meta("a", 0))
        try await store.save()
        #expect(await AnalysisStore(url: url, analyzerVersion: "v1").signals(for: meta("a", 0)) == s)
    }

    /// A cache from before the schema number is rebuilt, even for the same analyzer version.
    @Test func aCacheFromAnOlderSchemaStartsFresh() async throws {
        struct OldEntry: Codable { var contentVersion: Date?; var signals: FrameSignals }
        struct OldContents: Codable { var analyzerVersion: String; var entries: [String: OldEntry] }
        let url = temporaryDirectory().appendingPathComponent("analysis.plist")
        let old = OldContents(analyzerVersion: "v1", entries: ["a": OldEntry(contentVersion: nil, signals: signals())])
        try PropertyListEncoder().encode(old).write(to: url)
        #expect(await AnalysisStore(url: url, analyzerVersion: "v1").count == 0)
    }
}

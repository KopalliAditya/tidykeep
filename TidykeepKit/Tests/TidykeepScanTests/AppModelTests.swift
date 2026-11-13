import Foundation
import TidykeepCore
import TidykeepFolderSource
import TidykeepTestSupport
@testable import TidykeepUI
import TidykeepVision
import SwiftUI
import Testing

/// The app's flow from first launch to removing photos, against a folder instead of Photos.
@MainActor @Suite(.serialized) struct AppModelTests {
    let library: URL
    let data: URL
    let defaults: UserDefaults
    let truth: SyntheticLibrary.Truth

    init() throws {
        library = temporaryDirectory("app-library")
        data = temporaryDirectory("app-data")
        truth = try SyntheticLibrary.write(to: library, seriesCount: 3, framesPerSeries: 3...4, singles: 3)
        let suite = "tidykeep-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(ScanScope.everything.rawValue, forKey: "scanScope")
        defaults.set(Sensitivity.strict.rawValue, forKey: "sensitivity")
    }

    func makeModel() -> AppModel {
        AppModel(source: FolderPhotoSource(folder: library), analyzer: VisionFrameAnalyzer(), directory: data, defaults: defaults)
    }

    func waitForScan(_ model: AppModel) async throws {
        for _ in 0..<600 {
            if case .finished = model.scanState { return }
            if case .failed(let message) = model.scanState { Issue.record("scan failed: \(message)"); return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("scan didn't finish in 30 s")
    }

    @Test func firstLaunchScansAndShowsGroups() async throws {
        let model = makeModel()
        #expect(model.phase == .launching)
        await model.start()
        #expect(model.phase == .ready)
        try await waitForScan(model)
        #expect(model.groups.count == truth.series.count)
        #expect(model.suggestedRemovalCount == truth.series.reduce(0) { $0 + $1.files.count - 1 })
        #expect(model.ledger.lastScan != nil)
        #expect(FileManager.default.fileExists(atPath: data.appendingPathComponent("analysis.plist").path))
    }

    @Test func reviewChoicesAreSavedAndRefusalsExplained() async throws {
        let model = makeModel()
        await model.start()
        try await waitForScan(model)
        let group = try #require(model.groups.first)

        model.setKeep(false, group.keeper.id, in: group)
        #expect(model.notice == "Each group keeps at least one photo.")
        #expect(model.isKept(group.keeper.id, in: group))

        let other = group.members[1].id
        model.keepOnly(other, in: group)
        #expect(model.isKept(other, in: group))
        #expect(!model.isKept(group.keeper.id, in: group))

        // A fresh launch remembers the choice.
        let relaunched = makeModel()
        await relaunched.start()
        try await waitForScan(relaunched)
        let same = try #require(relaunched.group(group.id))
        #expect(relaunched.isKept(other, in: same))
        #expect(!relaunched.isKept(group.keeper.id, in: same))
    }

    @Test func keepAllHidesAGroupUntilRestored() async throws {
        let model = makeModel()
        await model.start()
        try await waitForScan(model)
        let group = try #require(model.groups.first)
        model.keepAll(group)
        #expect(model.group(group.id) == nil)
        #expect(model.notice == "Kept all \(group.members.count) photos.")
        model.restoreKeptGroups()
        #expect(model.group(group.id) != nil)
    }

    @Test func removingMovesPhotosAndTheGroupStaysDone() async throws {
        let model = makeModel()
        await model.start()
        try await waitForScan(model)
        let group = try #require(model.groups.first)
        let removing = model.removals(in: group).map(\.id)
        #expect(!removing.isEmpty)

        await model.removeSuggested(in: group)
        #expect(model.ledger.photosRemoved == removing.count)
        #expect(model.group(group.id) == nil)
        #expect(model.notice?.hasPrefix("Removed \(Copy.photos(removing.count)).") == true)
        for id in removing {
            #expect(!FileManager.default.fileExists(atPath: library.appendingPathComponent(id).path))
            #expect(FileManager.default.fileExists(atPath: library.appendingPathComponent(".removed/\(id)").path))
        }
        #expect(FileManager.default.fileExists(atPath: library.appendingPathComponent(group.keeper.id).path))

        // After a rescan, the photos that were kept don't come back as a group to review.
        model.rescan()
        try await waitForScan(model)
        #expect(!model.groups.contains { $0.members.contains { $0.id == group.keeper.id } })
        #expect(model.groups.count == truth.series.count - 1)
    }

    @Test func aPhotoMadeAFavoriteSinceTheScanIsKept() async throws {
        let model = makeModel()
        await model.start()
        try await waitForScan(model)
        let group = try #require(model.groups.first)
        let removing = model.removals(in: group).map(\.id)
        let favorite = try #require(removing.first)

        // The user marks it a favorite in Photos while the list is up.
        let url = library.appendingPathComponent(FolderPhotoSource.Manifest.fileName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var manifest = try decoder.decode(FolderPhotoSource.Manifest.self, from: Data(contentsOf: url))
        manifest.files[favorite]?.favorite = true
        try manifest.write(to: library)

        await model.removeSuggested(in: group)
        #expect(FileManager.default.fileExists(atPath: library.appendingPathComponent(favorite).path))
        #expect(model.ledger.photosRemoved == removing.count - 1)
    }

    @Test func aGroupWhoseKeeperIsGoneIsLeftAlone() async throws {
        let model = makeModel()
        await model.start()
        try await waitForScan(model)
        let group = try #require(model.groups.first)
        let removing = model.removals(in: group).map(\.id)

        // The keeper is deleted in Photos before the user taps Remove.
        try FileManager.default.removeItem(at: library.appendingPathComponent(group.keeper.id))

        await model.removeSuggested(in: group)
        #expect(model.notice == "Nothing was removed.")
        for id in removing {
            #expect(FileManager.default.fileExists(atPath: library.appendingPathComponent(id).path))
        }
    }

    @Test func whatsLeftOfACleanedGroupStaysKept() async throws {
        let model = makeModel()
        await model.start()
        try await waitForScan(model)
        let group = try #require(model.groups.first { $0.members.count >= 3 })
        // Keep two, remove the rest.
        let second = try #require(model.removals(in: group).first)
        model.setKeep(true, second.id, in: group)
        await model.removeSuggested(in: group)
        #expect(model.ledger.decisions.overrides[group.keeper.id] == true)
        #expect(model.ledger.decisions.overrides[second.id] == true)
    }

    @Test func removeAllLeavesOnlyKeepers() async throws {
        let model = makeModel()
        await model.start()
        try await waitForScan(model)
        let keepers = Set(model.groups.map(\.keeper.id))
        await model.removeAllSuggested()
        #expect(model.groups.isEmpty)
        #expect(model.suggestedRemovalCount == 0)
        let left = try FileManager.default.contentsOfDirectory(atPath: library.path).filter { $0.hasSuffix(".jpg") }
        #expect(Set(left) == keepers.union(truth.singles))
    }

    @Test func settingsPersistAndRescan() async throws {
        let model = makeModel()
        await model.start()
        try await waitForScan(model)
        model.setSensitivity(.balanced)
        #expect(defaults.string(forKey: "sensitivity") == "balanced")
        try await waitForScan(model)
        #expect(makeModel().sensitivity == .balanced)
    }

    @Test func forgetAnalysisStartsOver() async throws {
        let model = makeModel()
        await model.start()
        try await waitForScan(model)
        let before = model.groups.map(\.id)
        await model.forgetAnalysis()
        try await waitForScan(model)
        #expect(model.groups.map(\.id) == before)
    }

    /// Renders each screen once, to catch layout code that traps.
    @Test func screensRender() async throws {
        let model = makeModel()
        await model.start()
        try await waitForScan(model)
        let group = try #require(model.groups.first)
        let screens: [AnyView] = [
            AnyView(RootView()),
            AnyView(LibraryView()),
            AnyView(GroupDetailView(groupID: group.id)),
            AnyView(SettingsView()),
        ]
        for screen in screens {
            let renderer = ImageRenderer(content: screen.environment(model).frame(width: 393, height: 852))
            #expect(renderer.cgImage != nil)
        }
    }
}

@Suite struct CopyTests {
    func group(reasons favorite: Bool = false) -> PhotoGroup {
        let date = Date(timeIntervalSince1970: 1_767_225_600)
        func m(_ id: String, _ s: Float, fav: Bool = false) -> (meta: AssetMeta, signals: FrameSignals) {
            (AssetMeta(id: id, creationDate: date.addingTimeInterval(Double(s)), isFavorite: fav),
             FrameSignals(embedding: QuantizedEmbedding([1, 0]), aesthetics: 0.5, isUtility: false, sharpness: s, faceQualities: []))
        }
        return PhotoGroup(members: [m("a", 2, fav: favorite), m("b", 8), m("c", 5)])
    }

    @Test func counts() {
        #expect(Copy.photos(1) == "1 photo")
        #expect(Copy.photos(3) == "3 photos")
        #expect(Copy.keepRemove(kept: 1, removing: 2) == "Keep 1 · Remove 2")
        #expect(Copy.keepRemove(kept: 3, removing: 0) == "Keeping all 3")
        #expect(Copy.scanSummary(groups: 0, extras: 0) == "No similar photos found")
        #expect(Copy.scanSummary(groups: 1, extras: 1) == "1 group · 1 extra photo")
        #expect(Copy.scanSummary(groups: 4, extras: 9) == "4 groups · 9 extra photos")
        #expect(Copy.skipped(1) == "1 photo couldn't be read on this phone, usually because it's only in iCloud, and was skipped.")
        #expect(Copy.skipped(2) == "2 photos couldn't be read on this phone, usually because they're only in iCloud, and were skipped.")
        #expect(Copy.scanDone(groups: 4, extras: 9) == "Done checking. 4 groups, 9 extra photos.")
        #expect(Copy.checked(ScanProgress()) == "Getting ready")
    }

    @Test func reasonsReadAsASentence() {
        #expect(Copy.reasons([]) == "best all-round")
        #expect(Copy.reasons([.sharpest]) == "sharpest")
        #expect(Copy.reasons([.sharpest, .bestFaces]) == "sharpest and best faces")
        #expect(Copy.reasons([.sharpest, .bestFaces, .bestLook]) == "sharpest, best faces and best overall look")
    }

    @Test func protectedNotes() {
        let g = group(reasons: true)
        #expect(Copy.protectedNote(g.member("a")!, in: g) == "This is a favorite, so it's always kept.")
        #expect(Copy.protectedNote(g.member("b")!, in: g) == nil)
    }

    @Test func whyThisOne() {
        #expect(Copy.whyThisOne(group()) == "Best pick: sharpest.")
        #expect(Copy.whyThisOne(group(reasons: true)) == "Kept because you marked it as a favorite.")
        // VoiceOver can't see the star, so it hears which photo, numbered like the tiles.
        #expect(Copy.whyThisOneSpoken(group()) == "Best pick is photo 3: sharpest.")
        #expect(Copy.whyThisOneSpoken(group(reasons: true)) == "Best pick is photo 1, because you marked it as a favorite.")
    }

    @Test func tilesAreInCaptureOrderAndNumberedThatWay() {
        let g = group()
        #expect(g.inCaptureOrder.map(\.id) == ["a", "c", "b"])
        #expect(g.inCaptureOrder.map { Copy.photoNumber($0.id, in: g) } == ["photo 1", "photo 2", "photo 3"])
    }

    @Test func closeCallNamesTheRunnerUp() {
        let date = Date(timeIntervalSince1970: 1_767_225_600)
        func m(_ id: String, _ s: Float) -> (meta: AssetMeta, signals: FrameSignals) {
            (AssetMeta(id: id, creationDate: date.addingTimeInterval(Double(s)), isFavorite: false),
             FrameSignals(embedding: QuantizedEmbedding([1, 0]), aesthetics: 0.5, isUtility: false, sharpness: s, faceQualities: []))
        }
        let close = PhotoGroup(members: [m("a", 8), m("b", 7.98), m("c", 2)])
        #expect(close.ranking.isCloseCall)
        #expect(close.runnerUp?.id == "b")
        #expect(Copy.closeCallSpoken(close) == "Close call: photo 2 is nearly as good. Compare them before removing.")
        #expect(Copy.photoValue(close.member("b")!, in: close, kept: true) == "Runner-up. Keeping")
        #expect(group().runnerUp == nil)
        #expect(Copy.closeCallSpoken(group()) == Copy.closeCall)
    }

    @Test func voiceOverLabels() {
        let g = group()
        #expect(Copy.groupTitle(g) == "3 similar photos")
        #expect(Copy.photoLabel(g.member("b")!, in: g).hasPrefix("Photo 3 of 3, taken "))
        #expect(Copy.photoValue(g.keeper, in: g, kept: true) == "Best pick, sharpest. Keeping")
        #expect(Copy.photoValue(g.member("a")!, in: g, kept: false) == "Marked for removal")
        #expect(Copy.groupLabel(g, kept: 1, removing: 2).hasSuffix("1 to keep, 2 to remove."))
        #expect(Copy.tally(g, removing: 2) == "1 to keep, 2 to remove.")
        #expect(Copy.tally(g, removing: 0) == "Keeping all 3.")
        let f = group(reasons: true)
        #expect(Copy.photoValue(f.keeper, in: f, kept: true) == "Best pick, a favorite. Keeping")
    }
}

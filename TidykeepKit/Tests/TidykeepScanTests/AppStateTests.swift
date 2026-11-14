import CoreGraphics
import Foundation
import os
import SwiftUI
import Testing
import TidykeepCore
import TidykeepFolderSource
import TidykeepTestSupport
@testable import TidykeepUI
import TidykeepVision

/// The app's flow from first launch to removing photos, against a folder instead of Photos.
@MainActor @Suite(.serialized) struct AppStateTests {
    let library: URL
    let data: URL
    let defaults: UserDefaults
    let truth: SyntheticLibrary.Truth

    init() throws {
        library = temporaryDirectory("app-library")
        data = temporaryDirectory("app-data")
        truth = try SyntheticLibrary.write(to: library, seriesCount: 3, framesPerSeries: 3...4, singles: 3)
        defaults = freshDefaults()
        defaults.set(ScanScope.everything.rawValue, forKey: "scanScope")
        defaults.set(Sensitivity.strict.rawValue, forKey: "sensitivity")
    }

    func makeState() -> AppState {
        // The copy pass joins the drawn shapes of the synthetic library to its series, so it's
        // off here; real-photo copy precision is measured by the benchmark.
        AppState(photoSource: FolderPhotoSource(folder: library), analyzer: VisionFrameAnalyzer(), directory: data, defaults: defaults, findsCopies: false)
    }

    func started() async throws -> AppState {
        let state = makeState()
        await state.start()
        try await waitForScan(state.photos)
        return state
    }

    @Test func firstLaunchShowsOnboardingThenChecks() async throws {
        let state = makeState()
        #expect(state.showsOnboarding)
        await state.finishOnboarding()
        #expect(!state.showsOnboarding)
        #expect(defaults.bool(forKey: "onboarded"))
        try await waitForScan(state.photos)
        let photos = state.photos
        #expect(photos.similar.count == truth.series.count)
        #expect(photos.similarRemovalCount == truth.series.reduce(0) { $0 + $1.files.count - 1 })
        #expect(photos.ledger.lastScan != nil)
        #expect(photos.coverage.checked == truth.series.reduce(0) { $0 + $1.files.count } + truth.singles.count)
        #expect(FileManager.default.fileExists(atPath: data.appendingPathComponent("analysis.plist").path))
        #expect(!makeState().showsOnboarding)
    }

    @Test func reviewChoicesAreSavedAndRefusalsExplained() async throws {
        let state = try await started()
        let photos = state.photos
        let group = try #require(photos.similar.first)

        photos.setKeep(false, group.keeper.id, in: group)
        #expect(state.notices.text == Copy.Similar.lastKeptRefusal)
        #expect(photos.isKept(group.keeper.id, in: group))

        let other = group.members[1].id
        photos.keepOnly(other, in: group)
        #expect(photos.isKept(other, in: group))
        #expect(!photos.isKept(group.keeper.id, in: group))

        // A fresh launch remembers the choice.
        let relaunched = try await started()
        let same = try #require(relaunched.photos.group(group.id))
        #expect(relaunched.photos.isKept(other, in: same))
        #expect(!relaunched.photos.isKept(group.keeper.id, in: same))
    }

    @Test func keepAllLeavesAReceiptAndUndoBringsTheGroupBack() async throws {
        let state = try await started()
        let photos = state.photos
        let group = try #require(photos.similar.first)
        photos.keepAll(group)
        #expect(photos.group(group.id) == nil)
        #expect(state.notices.text == "Kept all \(group.members.count).")

        let receipt = try #require(state.history.lastChange)
        #expect(receipt.kind == .keptAll)
        #expect(receipt.status == .done)
        #expect(state.canUndo(receipt))
        await state.undo(receipt)
        #expect(photos.group(group.id) != nil)
        #expect(state.history.receipt(receipt.id)?.status == .undone)
        #expect(!state.canUndo(try #require(state.history.receipt(receipt.id))))
    }

    @Test func removingLeavesAReceiptAndTheGroupStaysDone() async throws {
        let state = try await started()
        let photos = state.photos
        let group = try #require(photos.similar.first)
        let removing = photos.removals(in: group).map(\.id)
        #expect(!removing.isEmpty)

        await photos.removeSuggested(in: [group])
        #expect(photos.ledger.photosRemoved == removing.count)
        #expect(photos.group(group.id) == nil)
        #expect(state.notices.text == Copy.Notices.removedPhotos(removing.count))
        for id in removing {
            #expect(!FileManager.default.fileExists(atPath: library.appendingPathComponent(id).path))
            #expect(FileManager.default.fileExists(atPath: library.appendingPathComponent(".removed/\(id)").path))
        }
        #expect(FileManager.default.fileExists(atPath: library.appendingPathComponent(group.keeper.id).path))

        let receipt = try #require(state.history.lastChange)
        #expect(receipt.kind == .photosRemoved)
        #expect(receipt.status == .done)
        #expect(receipt.completed == removing.count)
        #expect(Set(receipt.itemIDs) == Set(removing))
        #expect(receipt.deadline != nil)
        #expect(!state.canUndo(receipt))
        #expect(Copy.Receipts.sentence(receipt) == "Removed \(Copy.photos(removing.count))")

        // History is saved: a fresh launch has it.
        #expect(makeState().history.receipt(receipt.id)?.status == .done)

        // After a rescan, the photos that were kept don't come back as a group to review.
        photos.rescan()
        try await waitForScan(photos)
        #expect(!photos.similar.contains { $0.members.contains { $0.id == group.keeper.id } })
        #expect(photos.similar.count == truth.series.count - 1)
    }

    @Test func aPhotoMadeAFavoriteSinceTheCheckIsKept() async throws {
        let state = try await started()
        let photos = state.photos
        let group = try #require(photos.similar.first)
        let removing = photos.removals(in: group).map(\.id)
        let favorite = try #require(removing.first)

        // The user marks it a favorite in Photos while the list is up.
        let url = library.appendingPathComponent(FolderPhotoSource.Manifest.fileName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var manifest = try decoder.decode(FolderPhotoSource.Manifest.self, from: Data(contentsOf: url))
        manifest.files[favorite]?.favorite = true
        try manifest.write(to: library)

        await photos.removeSuggested(in: [group])
        #expect(FileManager.default.fileExists(atPath: library.appendingPathComponent(favorite).path))
        #expect(photos.ledger.photosRemoved == removing.count - 1)
        let receipt = try #require(state.history.lastChange)
        #expect(receipt.requested == removing.count)
        #expect(receipt.completed == removing.count - 1)
        #expect(receipt.status == .partial)
    }

    @Test func aGroupWhoseKeeperIsGoneIsLeftAloneAndNothingIsRecorded() async throws {
        let state = try await started()
        let photos = state.photos
        let group = try #require(photos.similar.first)
        let removing = photos.removals(in: group).map(\.id)

        // The keeper is deleted in Photos before the user taps Remove.
        try FileManager.default.removeItem(at: library.appendingPathComponent(group.keeper.id))

        await photos.removeSuggested(in: [group])
        #expect(state.notices.text == Copy.Notices.nothingRemoved)
        #expect(state.history.receipts.isEmpty)
        for id in removing {
            #expect(FileManager.default.fileExists(atPath: library.appendingPathComponent(id).path))
        }
    }

    @Test func whatsLeftOfACleanedGroupStaysKept() async throws {
        let state = try await started()
        let photos = state.photos
        let group = try #require(photos.similar.first { $0.members.count >= 3 })
        // Keep two, remove the rest.
        let second = try #require(photos.removals(in: group).first)
        photos.setKeep(true, second.id, in: group)
        await photos.removeSuggested(in: [group])
        #expect(photos.ledger.decisions.overrides[group.keeper.id] == true)
        #expect(photos.ledger.decisions.overrides[second.id] == true)
    }

    @Test func removeAllLeavesOnlyKeepers() async throws {
        let state = try await started()
        let photos = state.photos
        let keepers = Set(photos.similar.map(\.keeper.id))
        await photos.removeSuggested(in: photos.similar)
        #expect(photos.similar.isEmpty)
        #expect(photos.similarRemovalCount == 0)
        let left = try FileManager.default.contentsOfDirectory(atPath: library.path).filter { $0.hasSuffix(".jpg") }
        #expect(Set(left) == keepers.union(truth.singles))
    }

    @Test func aChangeCutOffByQuittingIsFinishedOnTheNextLaunch() async throws {
        let state = try await started()
        let group = try #require(state.photos.similar.first)
        let ids = state.photos.removals(in: group).map(\.id)
        // The app recorded the change, then quit before PhotoKit answered. One photo went.
        let id = state.history.begin(.photosRemoved, requested: ids.count, itemIDs: ids)
        try FileManager.default.removeItem(at: library.appendingPathComponent(ids[0]))

        let relaunched = makeState()
        await relaunched.start()
        let receipt = try #require(relaunched.history.receipt(id))
        #expect(receipt.status == (ids.count == 1 ? .done : .partial))
        #expect(receipt.completed == 1)
        #expect(relaunched.history.interrupted.isEmpty)
    }

    @Test func aPhotoChangeCutOffWaitsForFullAccess() async throws {
        let source = MemoryPhotoSource(photos: [AssetMeta(id: "kept", creationDate: Date())], access: .limited)
        func launch() -> AppState {
            AppState(photoSource: source, analyzer: ConstantAnalyzer(), directory: data, defaults: defaults, findsCopies: false)
        }
        let id = launch().history.begin(.copiesMerged, requested: 2, itemIDs: ["kept", "elsewhere"])

        // "elsewhere" may just be outside the selection, so nothing is decided yet.
        let limited = launch()
        await limited.recoverInterrupted()
        #expect(limited.history.interrupted.map(\.id) == [id])

        _ = await source.requestAccess()
        let full = launch()
        await full.recoverInterrupted()
        let receipt = try #require(full.history.receipt(id))
        #expect(receipt.status == .partial)
        #expect(receipt.completed == 1)
        // Cut off before the merge saved its outcomes, so there's nothing to take back.
        #expect(!full.canUndo(receipt))
    }

    @Test func forgetAnalysisStartsOver() async throws {
        let state = try await started()
        let before = state.photos.similar.map(\.id)
        await state.photos.forgetAnalysis()
        try await waitForScan(state.photos)
        #expect(state.photos.similar.map(\.id) == before)
    }

    @Test func resetStateLaunchArgumentForgetsEverything() async throws {
        let state = try await started()
        await state.finishOnboarding()
        state.photos.keepAll(try #require(state.photos.similar.first))
        #expect(!state.history.receipts.isEmpty)

        defaults.set(true, forKey: "TKResetState")
        let reset = makeState()
        #expect(reset.showsOnboarding)
        #expect(reset.history.receipts.isEmpty)
        #expect(reset.photos.ledger.dismissedGroups.isEmpty)
        #expect(reset.preferences.scope == .last12Months)
        // The library itself is untouched.
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.path).contains { $0.hasSuffix(".jpg") })
    }

    /// Renders every screen once, to catch layout code that traps.
    @Test func screensRender() async throws {
        let state = try await started()
        let group = try #require(state.photos.similar.first)
        state.photos.keepAll(group)
        let receipt = try #require(state.history.lastChange)
        let routes: [Route] = [
            .similar, .similarGroup(group.id), .copies, .copySet(group.id), .screenshots, .videos, .video("none"),
            .duplicateFiles, .duplicateFileSet("none"), .largeFiles, .holding, .contacts, .contactMerge("none"),
            .receipt(receipt.id), .albums, .about, .privacyPolicy, .acknowledgements,
        ] + RuleChoice.allCases.map { .ruleChoice($0) }
        var screens: [AnyView] = [AnyView(TidyHomeView()), AnyView(OnboardingView()), AnyView(CoverageSheet(coverage: state.photos.coverage))]
        screens += routes.map { AnyView(RouteDestination(route: $0)) }
        for screen in screens {
            let content = NavigationStack { screen }
                .frame(width: 393, height: 852)
                .environment(state)
                .environment(state.photos)
                .environment(state.files)
                .environment(state.contacts)
                .environment(state.history)
                .environment(state.notices)
                .environment(state.preferences)
            #expect(ImageRenderer(content: content).cgImage != nil)
        }
        #if os(macOS)
        // The tab view needs a live update cycle, which ImageRenderer doesn't give it.
        let host = NSHostingView(rootView: RootView().environment(state).frame(width: 393, height: 852))
        host.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)
        #endif
    }
}

/// Screenshots, videos and the rules, against a library held in memory.
@MainActor @Suite struct PhotoListTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func makeState(_ source: MemoryPhotoSource, defaults: UserDefaults = freshDefaults()) -> AppState {
        AppState(photoSource: source, analyzer: ConstantAnalyzer(), directory: nil, defaults: defaults, findsCopies: false)
    }

    @Test func screenshotsAreListedNewestFirstAndRulesKeepSomeSafe() async throws {
        let source = MemoryPhotoSource(
            photos: [
                AssetMeta(id: "shot-old", creationDate: now.addingTimeInterval(-3_600), isScreenshot: true),
                AssetMeta(id: "shot-new", creationDate: now, isScreenshot: true),
                AssetMeta(id: "shot-fav", creationDate: now, isFavorite: true, isScreenshot: true),
                AssetMeta(id: "shot-in-album", creationDate: now.addingTimeInterval(-60), isScreenshot: true),
                AssetMeta(id: "photo", creationDate: now),
            ],
            albums: [PhotoAlbum(id: "album", title: "Receipts", assetIDs: ["shot-in-album"])]
        )
        let defaults = freshDefaults()
        defaults.set(ScanScope.everything.rawValue, forKey: "scanScope")
        let state = makeState(source, defaults: defaults)
        await state.start()
        try await waitForScan(state.photos)
        #expect(state.photos.screenshots.map(\.id) == ["shot-new", "shot-old"])
        #expect(state.photos.coverage.skipped[.keptByRule] == 1)

        state.preferences.rules.keepScreenshotsInAlbums = false
        state.photos.refresh()
        #expect(state.photos.screenshots.map(\.id) == ["shot-new", "shot-in-album", "shot-old"])

        state.photos.markedScreenshots = ["shot-old"]
        await state.photos.removeScreenshots(["shot-old"])
        #expect(!state.photos.screenshots.contains { $0.id == "shot-old" })
        #expect(state.photos.markedScreenshots.isEmpty)
        #expect(state.notices.text == Copy.Notices.removedScreenshots(1))
        #expect(state.history.lastChange?.kind == .screenshotsRemoved)
    }

    @Test func bigVideosAreOverTheMinimumBiggestFirst() async throws {
        let source = MemoryPhotoSource(videos: [
            VideoMeta(id: "short", creationDate: now, duration: 30, pixelWidth: 3_840, pixelHeight: 2_160),
            VideoMeta(id: "long-hd", creationDate: now, duration: 600, pixelWidth: 1_920, pixelHeight: 1_080),
            VideoMeta(id: "mid-4k", creationDate: now, duration: 240, pixelWidth: 3_840, pixelHeight: 2_160),
            VideoMeta(id: "fav", creationDate: now, duration: 900, pixelWidth: 3_840, pixelHeight: 2_160, isFavorite: true),
        ])
        let state = makeState(source)
        await state.start()
        try await waitForScan(state.photos)
        #expect(state.photos.videos.map(\.id) == ["mid-4k", "long-hd"])

        state.photos.keepVideo("mid-4k")
        #expect(state.photos.videos.map(\.id) == ["long-hd"])

        state.preferences.videoMinimum = 300
        state.photos.refresh()
        #expect(state.photos.videos.map(\.id) == ["long-hd"])
        await state.photos.removeVideos(["long-hd"])
        #expect(state.photos.videos.isEmpty)
        #expect(state.notices.text == Copy.Notices.removedVideos(1))
    }

    @Test func nothingIsAskedForBeforeOnboarding() async throws {
        let source = MemoryPhotoSource(access: .notDetermined)
        let state = makeState(source)
        await state.start()
        #expect(state.photos.access == .notDetermined)
        #expect(source.requests == 0)
        await state.finishOnboarding()
        #expect(source.requests == 1)
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
        #expect(Copy.photos(1_204) == "1,204 photos")
        #expect(Copy.Similar.keepRemove(kept: 1, removing: 2) == "Keep 1 · Remove 2")
        #expect(Copy.Similar.keepRemove(kept: 3, removing: 0) == "Keeping all 3")
        #expect(Copy.Similar.summary(groups: 0, extras: 0) == "All tidy")
        #expect(Copy.Similar.summary(groups: 1, extras: 1) == "1 group · 1 extra photo")
        #expect(Copy.Similar.summary(groups: 4, extras: 9) == "4 groups · 9 extra photos")
        #expect(Copy.Scan.progress(ScanProgress()) == "Getting ready")
        #expect(Copy.Coverage.line(checked: 10, skipped: 0) == "Checked 10 photos")
        #expect(Copy.Coverage.line(checked: 10, skipped: 2) == "Checked 10 photos · 2 skipped")
        #expect(Copy.Notices.removedPhotos(1) == "Removed 1 photo. It's in Recently Deleted in Photos for 30 days.")
        #expect(Copy.Notices.removedVideos(2) == "Removed 2 videos. They're in Recently Deleted in Photos for 30 days.")
        #expect(Copy.Similar.keptOnlyThis(alsoAlwaysKept: 0) == "Only this one is kept")
        #expect(Copy.Similar.keptOnlyThis(alsoAlwaysKept: 1) == "Only this one is kept, plus 1 photo that's always kept")
        #expect(Copy.Similar.keptOnlyThis(alsoAlwaysKept: 2) == "Only this one is kept, plus 2 photos that are always kept")
    }

    @Test func receiptsReadAsSentences() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        var r = Receipt(kind: .filesHeld, date: date, status: .done, requested: 1, completed: 1, bytes: 2_000_000, title: "Trip notes copy.pdf")
        #expect(Copy.Receipts.sentence(r) == "Moved \u{201C}Trip notes copy.pdf\u{201D} to Holding")
        #expect(Copy.Receipts.status(r, now: date) == "2 MB in Holding")
        r = Receipt(kind: .contactsMerged, date: date, status: .done, requested: 2, completed: 1, title: "Jordan Rivera")
        #expect(Copy.Receipts.sentence(r) == "Merged 2 cards into Jordan Rivera")
        r = Receipt(kind: .photosRemoved, date: date, status: .partial, requested: 3, completed: 2, deadline: date.addingTimeInterval(86_400))
        #expect(Copy.Receipts.sentence(r) == "Removed 2 photos")
        #expect(Copy.Receipts.status(r, now: date).hasPrefix("2 of 3 done · In Recently Deleted until "))
    }

    @Test func copyRelations() {
        let date = Date(timeIntervalSince1970: 1_767_225_600)
        let keeper = AssetMeta(id: "k", creationDate: date, pixelWidth: 4_032, pixelHeight: 3_024)
        let smaller = AssetMeta(id: "s", creationDate: date, pixelWidth: 1_024, pixelHeight: 768)
        let same = AssetMeta(id: "e", creationDate: date, pixelWidth: 4_032, pixelHeight: 3_024)
        let shot = AssetMeta(id: "x", creationDate: date, pixelWidth: 1_179, pixelHeight: 2_556, isScreenshot: true)
        #expect(Copy.Copies.relation(CopyRelation.of(smaller, keeper: keeper)) == "Same photo, saved smaller")
        #expect(Copy.Copies.relation(CopyRelation.of(same, keeper: keeper)) == "Exact copy")
        #expect(Copy.Copies.relation(CopyRelation.of(same, keeper: keeper, formats: ["e": "JPEG", "k": "HEIC"])) == "Same photo, different format")
        #expect(Copy.Copies.relation(CopyRelation.of(shot, keeper: keeper)) == "Screenshot of this photo")
    }

    @Test func reasonsReadAsASentence() {
        #expect(Copy.Similar.reasons([]) == "best all-round")
        #expect(Copy.Similar.reasons([.sharpest]) == "sharpest")
        #expect(Copy.Similar.reasons([.sharpest, .bestFaces]) == "sharpest and best faces")
        #expect(Copy.Similar.reasons([.sharpest, .bestFaces, .bestLook]) == "sharpest, best faces and best overall look")
    }

    @Test func protectedNotes() {
        let g = group(reasons: true)
        #expect(Copy.Similar.protectedNote(g.member("a")!, in: g) == "This is a favorite, so it's always kept.")
        #expect(Copy.Similar.protectedNote(g.member("b")!, in: g) == nil)
        let ruled = group().applying(keptByRules: ["c"])
        #expect(Copy.Similar.protectedNote(ruled.member("c")!, in: ruled) == "This is in an album you protect, so it's always kept.")
    }

    @Test func whyThisOne() {
        #expect(Copy.Similar.whyThisOne(group()) == "Best pick: sharpest.")
        #expect(Copy.Similar.whyThisOne(group(reasons: true)) == "Kept because you marked it as a favorite.")
        // VoiceOver can't see the star, so it hears which photo, numbered like the tiles.
        #expect(Copy.Similar.whyThisOneSpoken(group()) == "Best pick is photo 3: sharpest.")
        #expect(Copy.Similar.whyThisOneSpoken(group(reasons: true)) == "Best pick is photo 1, because you marked it as a favorite.")
    }

    @Test func tilesAreInCaptureOrderAndNumberedThatWay() {
        let g = group()
        #expect(g.inCaptureOrder.map(\.id) == ["a", "c", "b"])
        #expect(g.inCaptureOrder.map { Copy.Similar.photoNumber($0.id, in: g) } == ["photo 1", "photo 2", "photo 3"])
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
        #expect(Copy.Similar.closeCallSpoken(close) == "Close call: photo 2 is nearly as good. Compare them before removing.")
        #expect(Copy.Similar.photoValue(close.member("b")!, in: close, kept: true) == "Runner-up. Keeping")
        #expect(group().runnerUp == nil)
        #expect(Copy.Similar.closeCallSpoken(group()) == Copy.Similar.closeCall)
    }

    @Test func voiceOverLabels() {
        let g = group()
        #expect(Copy.Similar.groupTitle(g) == "3 similar photos")
        #expect(Copy.Similar.photoLabel(g.member("b")!, in: g).hasPrefix("Photo 3 of 3, taken "))
        #expect(Copy.Similar.photoValue(g.keeper, in: g, kept: true) == "Best pick, sharpest. Keeping")
        #expect(Copy.Similar.photoValue(g.member("a")!, in: g, kept: false) == "Marked for removal")
        #expect(Copy.Similar.groupLabel(g, kept: 1, removing: 2).hasSuffix("1 to keep, 2 to remove."))
        #expect(Copy.Similar.tally(g, removing: 2) == "1 to keep, 2 to remove.")
        #expect(Copy.Similar.tally(g, removing: 0) == "Keeping all 3.")
        let f = group(reasons: true)
        #expect(Copy.Similar.photoValue(f.keeper, in: f, kept: true) == "Best pick, a favorite. Keeping")
    }

    /// The app never links out: no web addresses anywhere in what it says.
    @Test func noWebAddresses() {
        #expect(!Copy.Scan.keepOpen.contains("://"))
        #expect(!TextDocumentView.load("PrivacyPolicy").contains("://"))
        #expect(!TextDocumentView.load("PrivacyPolicy").isEmpty)
        #expect(!TextDocumentView.load("Acknowledgements").isEmpty)
    }
}

// MARK: - Helpers

func freshDefaults() -> UserDefaults {
    let suite = "tidykeep-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

@MainActor
func waitForScan(_ photos: PhotosModel) async throws {
    for _ in 0..<600 {
        if case .finished = photos.scanState { return }
        if case .failed = photos.scanState { Issue.record("check failed"); return }
        try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("check didn't finish in 30 s")
}

/// A library held in memory. Images can't be read, so nothing is grouped; the lists that come
/// from metadata alone (screenshots, videos) still fill.
final class MemoryPhotoSource: PhotoSource, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var photos: [AssetMeta]
    private var videoList: [VideoMeta]
    private let albumList: [PhotoAlbum]
    private var currentAccess: LibraryAccess
    private(set) var requests = 0

    init(photos: [AssetMeta] = [], videos: [VideoMeta] = [], albums: [PhotoAlbum] = [], access: LibraryAccess = .full) {
        self.photos = photos
        self.videoList = videos
        self.albumList = albums
        self.currentAccess = access
    }

    func access() async -> LibraryAccess { lock.withLock { currentAccess } }
    func requestAccess() async -> LibraryAccess {
        lock.withLock {
            requests += 1
            currentAccess = .full
            return currentAccess
        }
    }
    func fetchAssets(since: Date?) async throws -> [AssetMeta] { lock.withLock { photos } }
    func analysisImage(for id: String, maxPixelSize: Int) async throws -> CGImage { throw PhotoSourceError.unreadable }
    func thumbnail(for id: String, pixelSize: Int) async -> CGImage? { nil }
    func delete(_ ids: [String]) async -> Set<String> {
        lock.withLock {
            let gone = Set(ids)
            photos.removeAll { gone.contains($0.id) }
            videoList.removeAll { gone.contains($0.id) }
            return gone
        }
    }
    func existing(_ ids: [String]) async -> Set<String> {
        lock.withLock { Set(ids).intersection(photos.map(\.id) + videoList.map(\.id)) }
    }
    func changes() -> AsyncStream<Void> { AsyncStream { _ in } }
    func fetchVideos(since: Date?) async throws -> [VideoMeta] { lock.withLock { videoList } }
    func albums() async -> [PhotoAlbum] { albumList }
}

struct ConstantAnalyzer: FrameAnalyzing {
    let version = "constant"
    func analyze(_ image: CGImage) async throws -> FrameSignals {
        FrameSignals(embedding: QuantizedEmbedding([1, 0]), aesthetics: 0.5, isUtility: false, sharpness: 1, faceQualities: [])
    }
}

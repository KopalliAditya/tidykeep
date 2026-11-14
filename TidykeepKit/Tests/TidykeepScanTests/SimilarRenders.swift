import CoreGraphics
import Foundation
import SwiftUI
import Testing
import TidykeepCore
import TidykeepFolderSource
import TidykeepTestSupport
@testable import TidykeepUI
import TidykeepVision

/// Similar Shots: the list, a group, Compare and the review for a removal, drawn from the demo
/// library, plus how the list numbers its rows, what the review promises and what the group
/// screen relies on.
///
///     TK_RENDER_DIR=/tmp/renders bash scripts/test.sh --filter SimilarRenders
@MainActor @Suite(.serialized) struct SimilarRenders {
    // MARK: Renders

    @Test func screens() async throws {
        let state = try await RenderHarness.demoState()
        let photos = state.photos
        let group = try #require(photos.similar.first)
        for meta in group.members {
            _ = await photos.thumbnail(for: meta.id, pixelSize: 1400)
        }

        await RenderHarness.render(SimilarShotsView(), named: "similar-list", state: state)
        await RenderHarness.render(SimilarGroupView(groupID: group.id), named: "similar-group", state: state, height: 1150)

        // The largest text sizes: rows and controls stack instead of clipping.
        await RenderHarness.render(SimilarShotsView().dynamicTypeSize(.accessibility3), named: "similar-list-ax", state: state, height: 1400)
        await RenderHarness.render(SimilarGroupView(groupID: group.id).dynamicTypeSize(.accessibility3), named: "similar-group-ax", state: state, height: 1800)

        let other = try #require(group.runnerUp ?? group.members.dropFirst().first)
        let pair = SimilarComparePair(groupID: group.id, memberIDs: Set(group.members.map(\.id)), topID: group.keeper.id, bottomID: other.id)
        await RenderHarness.render(SimilarCompareView(pair: pair), named: "similar-compare", state: state)

        // The sheet itself draws blank in the Mac harness (its bottom bar), so the renders show
        // its content laid out the same way.
        let review = try #require(photos.similarReview(photos.similar))
        await RenderHarness.render(SimilarReviewContent(request: review), named: "similar-review", state: state)
        let one = try #require(photos.similarReview([group]))
        await RenderHarness.render(SimilarReviewContent(request: one), named: "similar-review-group", state: state)

        // After Keep all, the group screen says the group is gone instead of going blank.
        photos.keepAll(group)
        await RenderHarness.render(SimilarGroupView(groupID: group.id), named: "similar-group-gone", state: state)
    }

    /// A close call, a favorite picked as best and an edited photo the rules keep.
    @Test func variedGroups() async throws {
        let demo = try await SimilarDemo.make(varied: true)
        let photos = demo.state.photos
        let close = try #require(photos.similar.first { $0.ranking.isCloseCall })
        let favorite = try #require(photos.similar.first { $0.ranking.reasons == [.favorite] })
        for meta in close.members + favorite.members {
            _ = await photos.thumbnail(for: meta.id, pixelSize: 1400)
        }

        await RenderHarness.render(SimilarShotsView(), named: "similar-list-varied", state: demo.state)
        await RenderHarness.render(SimilarGroupView(groupID: close.id), named: "similar-group-closecall", state: demo.state, height: 1250)
        await RenderHarness.render(
            SimilarGroupView(groupID: close.id).dynamicTypeSize(.accessibility3),
            named: "similar-group-closecall-ax", state: demo.state, height: 2100
        )
        await RenderHarness.render(SimilarGroupView(groupID: favorite.id), named: "similar-group-favorite", state: demo.state, height: 1250)
    }

    /// Checking, stopped, done with nothing left, limited access and access off.
    @Test func listStates() async throws {
        // Checking: new photos are held back from analysis, so the check stays under way with
        // the groups found so far on screen.
        let demo = try await SimilarDemo.make()
        let photos = demo.state.photos
        let held = try demo.addFrames(copying: demo.truth.series[0].files, after: 86_400)
        demo.source.hold(Set(held))
        photos.rescan()
        try await waitFor { photos.scanState.progress.map { $0.photosInRange > 0 } == true && !photos.similar.isEmpty }
        #expect(photos.scanState.isActive)
        await RenderHarness.render(SimilarShotsView(), named: "similar-list-scanning", state: demo.state)

        // Stopped part-way with nothing left to review: no "All tidy", and a way to finish.
        for group in photos.similar { photos.keepAll(group) }
        photos.stopScan()
        await RenderHarness.render(SimilarShotsView(), named: "similar-empty-stopped", state: demo.state)

        // Done, nothing left: "All tidy".
        let done = try await SimilarDemo.make()
        for group in done.state.photos.similar { done.state.photos.keepAll(group) }
        await RenderHarness.render(SimilarShotsView(), named: "similar-empty", state: done.state)

        let limited = try await SimilarDemo.make(access: .limited)
        await RenderHarness.render(SimilarShotsView(), named: "similar-list-limited", state: limited.state)

        let off = try await SimilarDemo.make(access: .denied)
        await RenderHarness.render(SimilarShotsView(), named: "similar-access-off", state: off.state)
    }

    // MARK: Behaviour

    @Test func listHasOneNumberedRowPerGroup() async throws {
        let state = try await RenderHarness.demoState()
        let photos = state.photos
        #expect(photos.similar.count >= 2)
        for sort in SimilarListLayout.Sort.allCases {
            let rows = SimilarListLayout.sections(photos.similar, sort: sort) { photos.removals(in: $0).count }.flatMap(\.rows)
            #expect(rows.count == photos.similar.count)
            #expect(rows.map(\.index) == Array(0..<photos.similar.count))
            #expect(Set(rows.map(\.group.id)) == Set(photos.similar.map(\.id)))
        }
        let newest = SimilarListLayout.sections(photos.similar, sort: .newest) { _ in 0 }.flatMap(\.rows).map(\.group.startDate)
        #expect(newest == newest.sorted(by: >))
    }

    @Test func removeAllReviewsEverySuggestedPhoto() async throws {
        let state = try await RenderHarness.demoState()
        let photos = state.photos
        let groups = photos.similar
        let request = try #require(photos.similarReview(groups))
        let total = groups.reduce(0) { $0 + $1.members.count }

        #expect(request.removing.count == photos.similarRemovalCount)
        #expect(request.removing.count + request.staying.count == total)
        #expect(request.title == Copy.Review.removePhotos(photos.similarRemovalCount))
        #expect(request.confirmTitle == Copy.Similar.removeButton(photos.similarRemovalCount))
        // Every best pick stays, and nothing protected is listed for removal.
        let removing = Set(request.removing.map(\.id))
        for group in groups {
            #expect(!removing.contains(group.keeper.id))
            #expect(group.members.allSatisfy { !group.isProtected($0.id) || !removing.contains($0.id) })
        }
        #expect(request.reason.undo.contains("Recently Deleted"))
        #expect(request.sharedLibraryLine != nil)

        // Keeping every photo in a group leaves nothing to review for it.
        let first = try #require(groups.first)
        for meta in first.members { photos.setKeep(true, meta.id, in: first) }
        #expect(photos.similarReview([first]) == nil)
        #expect(photos.similarReview(groups)?.removing.count == photos.similarRemovalCount)
    }

    /// The confirm the screens hand to the review sheet removes the photos and reports back.
    @Test func confirmingTheReviewRemovesAndReportsBack() async throws {
        let state = try await RenderHarness.demoState()
        let photos = state.photos
        let groups = Array(photos.similar.prefix(2))
        let removing = groups.flatMap { photos.removals(in: $0).map(\.id) }
        var heard: [Bool] = []
        let request = try #require(photos.similarReview(groups) { heard.append($0) })

        await request.confirm()
        #expect(heard == [true])
        #expect(photos.ledger.photosRemoved == removing.count)
        #expect(state.notices.text == Copy.Notices.removedPhotos(removing.count))
        for group in groups {
            #expect(photos.similarGroup(group.id, following: Set(group.members.map(\.id))) == nil)
        }

        // Nothing is marked any more, so a second confirm removes nothing and says so.
        await request.confirm()
        #expect(heard == [true, false])
        #expect(photos.ledger.photosRemoved == removing.count)
    }

    /// The group screen follows its photos when a check adds one (the group's ID changes), and
    /// lets go once they're gone.
    @Test func groupScreenFollowsItsPhotos() async throws {
        let demo = try await SimilarDemo.make()
        let photos = demo.state.photos
        let series = demo.truth.series[0]
        let group = try #require(photos.similar.first { $0.member(series.best) != nil })
        let members = Set(group.members.map(\.id))
        #expect(photos.similarGroup(group.id, following: members)?.id == group.id)

        // Another frame of the same moment, a second after the last.
        let added = try demo.addFrames(copying: [series.best], after: 1)
        photos.rescan()
        try await waitForScan(photos)
        #expect(photos.similar.first { $0.id == group.id } == nil)
        let followed = try #require(photos.similarGroup(group.id, following: members))
        #expect(followed.id != group.id)
        #expect(Set(followed.members.map(\.id)) == members.union(added))

        // Nothing to follow: no group.
        #expect(photos.similarGroup("missing", following: []) == nil)
        #expect(photos.similarGroup("missing", following: ["missing.jpg"]) == nil)

        photos.keepAll(followed)
        #expect(photos.similarGroup(group.id, following: members) == nil)
    }

    /// What the picker snaps back from: the last kept photo, and a photo the rules keep.
    @Test func refusedChangesLeaveTheChoiceAsItWas() async throws {
        let demo = try await SimilarDemo.make(varied: true)
        let photos = demo.state.photos

        let plain = try #require(photos.similar.first { group in !group.members.contains { group.isProtected($0.id) } })
        #expect(plain.members.filter { photos.isKept($0.id, in: plain) }.map(\.id) == [plain.keeper.id])
        photos.setKeep(false, plain.keeper.id, in: plain)
        #expect(photos.isKept(plain.keeper.id, in: plain))
        #expect(demo.state.notices.text == Copy.Similar.lastKeptRefusal)

        let ruled = try #require(photos.similar.first { $0.members.contains { $0.hasAdjustments } })
        let edited = try #require(ruled.members.first { $0.hasAdjustments })
        #expect(edited.id != ruled.keeper.id)
        photos.setKeep(false, edited.id, in: ruled)
        #expect(photos.isKept(edited.id, in: ruled))
        #expect(demo.state.notices.text == Copy.Similar.protectedRefusal)
        #expect(photos.similarReason(ruled).keptSafe == Copy.Similar.keptSafe(favorites: 0, edited: 1, albums: 0, documents: 0))

        // The close call names a runner-up for Compare.
        let close = try #require(photos.similar.first { $0.ranking.isCloseCall })
        #expect(close.runnerUp != nil)
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("condition not met in 30 s")
    }
}

// MARK: - Demo

/// The demo library behind a source that can say access is limited or off, and can hold
/// photos back from analysis so a check stays under way.
@MainActor
struct SimilarDemo {
    let state: AppState
    let source: SimilarDemoSource
    let library: URL
    let truth: SyntheticLibrary.Truth

    /// - Parameter varied: adds what the plain demo lacks: a close call (series 1's best frame
    ///   twice), an edited photo that isn't the best pick (series 0) and a favorite (series 2).
    static func make(access: LibraryAccess = .full, varied: Bool = false) async throws -> SimilarDemo {
        let library = temporaryDirectory("similar-library-\(UUID().uuidString)")
        let truth = try SyntheticLibrary.write(to: library, seriesCount: 4, framesPerSeries: 3...5, singles: 4, start: Date().addingTimeInterval(-40 * 86_400))
        try DemoPhotoSource.addScreenshots(to: library, count: 6)
        let defaults = freshDefaults()
        defaults.set(ScanScope.everything.rawValue, forKey: "scanScope")
        defaults.set(Sensitivity.strict.rawValue, forKey: "sensitivity")
        defaults.set(true, forKey: "onboarded")
        let source = SimilarDemoSource(folder: library, access: access)
        let state = AppState(
            photoSource: source,
            analyzer: VisionFrameAnalyzer(),
            directory: temporaryDirectory("similar-data-\(UUID().uuidString)"),
            defaults: defaults,
            findsCopies: false
        )
        let demo = SimilarDemo(state: state, source: source, library: library, truth: truth)
        if varied {
            _ = try demo.addFrames(copying: [truth.series[1].best], after: 1)
            try demo.editManifest { files in
                let edited = truth.series[0].files.first { $0 != truth.series[0].best }!
                let favorite = truth.series[2].files.first { $0 != truth.series[2].best }!
                files[edited]?.edited = true
                files[favorite]?.favorite = true
            }
        }
        await state.start()
        if access.canRead {
            try await waitForScan(state.photos)
            for meta in state.photos.similar.flatMap(\.members) {
                _ = await state.photos.thumbnail(for: meta.id, pixelSize: 300)
            }
        }
        return demo
    }

    /// Copies photos under new names, `seconds` after the last of them, and returns the names.
    func addFrames(copying names: [String], after seconds: TimeInterval) throws -> [String] {
        var added: [String] = []
        try editManifest { files in
            let last = names.compactMap { files[$0]?.date }.max() ?? Date()
            for (i, name) in names.enumerated() {
                let copy = "added\(UUID().uuidString.prefix(6))_\(name)"
                try FileManager.default.copyItem(at: library.appendingPathComponent(name), to: library.appendingPathComponent(copy))
                files[copy] = .init(date: last.addingTimeInterval(seconds + Double(i) * 2))
                added.append(copy)
            }
        }
        return added
    }

    func editManifest(_ edit: (inout [String: FolderPhotoSource.Manifest.Entry]) throws -> Void) throws {
        let url = library.appendingPathComponent(FolderPhotoSource.Manifest.fileName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var manifest = try decoder.decode(FolderPhotoSource.Manifest.self, from: Data(contentsOf: url))
        try edit(&manifest.files)
        try manifest.write(to: library)
    }
}

final class SimilarDemoSource: PhotoSource, @unchecked Sendable {
    private let base: DemoPhotoSource
    private let lock = NSLock()
    private let libraryAccess: LibraryAccess
    private var held: Set<String> = []

    init(folder: URL, access: LibraryAccess) {
        base = DemoPhotoSource(folder: folder)
        libraryAccess = access
    }

    /// Analysis of these photos waits until the check is stopped.
    func hold(_ ids: Set<String>) { lock.withLock { held = ids } }

    func access() async -> LibraryAccess { libraryAccess }
    func requestAccess() async -> LibraryAccess { libraryAccess }
    func changes() -> AsyncStream<Void> { base.changes() }
    func fetchAssets(since: Date?) async throws -> [AssetMeta] { try await base.fetchAssets(since: since) }
    func analysisImage(for id: String, maxPixelSize: Int) async throws -> CGImage {
        if lock.withLock({ held.contains(id) }) { try await Task.sleep(for: .seconds(600)) }
        return try await base.analysisImage(for: id, maxPixelSize: maxPixelSize)
    }
    func thumbnail(for id: String, pixelSize: Int) async -> CGImage? { await base.thumbnail(for: id, pixelSize: pixelSize) }
    func delete(_ ids: [String]) async -> Set<String> { await base.delete(ids) }
    func existing(_ ids: [String]) async -> Set<String> { await base.existing(ids) }
    func fetchVideos(since: Date?) async throws -> [VideoMeta] { try await base.fetchVideos(since: since) }
    func albums() async -> [PhotoAlbum] { await base.albums() }
    func formats(for ids: [String]) async -> [String: String] { await base.formats(for: ids) }
    func coverage(since: Date?) async -> LibraryCoverage { await base.coverage(since: since) }
}

// MARK: - Review content

/// What the review sheet shows, without its bottom bar: title, the photos that go, the Reason
/// card and the Shared Library line, then the confirm title as text.
private struct SimilarReviewContent: View {
    let request: ReviewRequest

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                Text(request.title).font(.title2.weight(.bold))
                Text("\(Copy.Review.removing) \(request.removing.count) · \(Copy.Review.staying) \(request.staying.count)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: Space.xs)], spacing: Space.xs) {
                    ForEach(request.removing) { item in
                        PhotoThumbnail(id: item.id, pixelSize: 200)
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                    }
                }
                ReasonCard(reason: request.reason)
                if let line = request.sharedLibraryLine {
                    Label(line, systemImage: "person.2").font(.footnote).foregroundStyle(.secondary)
                }
                Text(request.confirmTitle)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Palette.accent, in: Capsule())
            }
            .padding(Space.l)
        }
        .background(Palette.groupedBackground)
    }
}

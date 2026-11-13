import Foundation
import SwiftUI
import Testing
import TidykeepCore
@testable import TidykeepUI

/// Similar Shots: the list, a group, Compare and the review for a removal, drawn from the demo
/// library, plus how the list numbers its rows and what the review promises.
///
///     TK_RENDER_DIR=/tmp/renders bash scripts/test.sh --filter SimilarRenders
@MainActor @Suite(.serialized) struct SimilarRenders {
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
        // its content laid out the same way; the sheet is still drawn to catch traps.
        let review = try #require(photos.similarReview(photos.similar))
        await RenderHarness.render(ReviewSheet(request: review), named: "similar-review-sheet", state: state)
        await RenderHarness.render(SimilarReviewContent(request: review), named: "similar-review", state: state)
        let one = try #require(photos.similarReview([group]))
        await RenderHarness.render(SimilarReviewContent(request: one), named: "similar-review-group", state: state)

        // After Keep all, the group screen says the group is gone instead of going blank.
        photos.keepAll(group)
        await RenderHarness.render(SimilarGroupView(groupID: group.id), named: "similar-group-gone", state: state)
    }

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
}

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

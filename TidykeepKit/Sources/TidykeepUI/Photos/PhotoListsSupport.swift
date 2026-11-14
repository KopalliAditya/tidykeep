import Foundation
import SwiftUI
import TidykeepCore

// What Copies, Screenshots and Big Videos share: the review requests that gate every merge
// and removal, and screenshots grouped by month.

// MARK: Review requests

extension PhotosModel {
    /// "Merge 3 sets?": what goes, what stays and how to take it back, for one or more copy
    /// sets. Confirming runs `mergeCopies`.
    func mergeReview(for groups: [PhotoGroup], title: String? = nil, confirmTitle: String? = nil) -> ReviewRequest {
        let sets = groups.filter { !removals(in: $0).isEmpty }
        let removing = sets.flatMap { removals(in: $0).map(\.id) }
        let keepers = sets.map { copyKeeper(in: $0).id }
        // Copies kept besides the keeper: favorites and edited ones, which always stay.
        let alsoKept = sets.reduce(0) { total, group in
            total + group.members.count - removals(in: group).count - 1
        }
        let deadline = Receipt.recentlyDeletedDeadline(from: Date())
        return ReviewRequest(
            title: title ?? Copy.Review.mergeSets(sets.count),
            removing: removing.map(ReviewItem.photo),
            staying: keepers.map(ReviewItem.photo),
            reason: Reason(
                why: Copy.Copies.reviewWhy(sets: sets.count),
                keptSafe: alsoKept > 0 ? Copy.Copies.keptSafe(alsoKept) : nil,
                undo: Copy.Copies.undo(until: deadline)
            ),
            sharedLibraryLine: Copy.Review.sharedLibrary,
            confirmTitle: confirmTitle ?? Copy.Copies.mergeButton(sets.count),
            confirm: { [weak self] in await self?.mergeCopies(sets) }
        )
    }

    /// "Remove 4 screenshots?" for the marked screenshots. Confirming runs `removeScreenshots`.
    func screenshotsReview(_ ids: [String], keepsAlbums: Bool) -> ReviewRequest {
        let marked = Set(ids)
        let months = Set(screenshots.filter { marked.contains($0.id) }.map { ScreenshotMonth.start(of: $0.creationDate) }).count
        let ordered = screenshots.map(\.id).filter(marked.contains)
        return ReviewRequest(
            title: Copy.Review.removeScreenshots(ordered.count),
            removing: ordered.map(ReviewItem.photo),
            staying: [],
            reason: Reason(
                why: Copy.Screenshots.reviewWhy(months: max(months, 1)),
                keptSafe: Copy.Screenshots.reviewKeptSafe(albums: keepsAlbums),
                undo: Copy.Reason.recentlyDeleted(until: Receipt.recentlyDeletedDeadline(from: Date()))
            ),
            sharedLibraryLine: Copy.Review.sharedLibrary,
            confirmTitle: Copy.Screenshots.removeButton(ordered.count),
            confirm: { [weak self] in await self?.removeScreenshots(ordered) }
        )
    }

    /// "Remove 2 videos?" for the marked videos, or one video. Confirming runs `removeVideos`.
    func videosReview(_ ids: [String], minimum: TimeInterval, title: String? = nil, then done: (@MainActor () -> Void)? = nil) -> ReviewRequest {
        let chosen = Set(ids)
        let ordered = videos.map(\.id).filter(chosen.contains)
        return ReviewRequest(
            title: title ?? Copy.Review.removeVideos(ordered.count),
            removing: ordered.map(ReviewItem.photo),
            staying: [],
            reason: Reason(
                why: Copy.Videos.reviewWhy(ordered.count, minimum: minimum),
                keptSafe: Copy.Videos.reviewKeptSafe,
                undo: Copy.Reason.recentlyDeleted(until: Receipt.recentlyDeletedDeadline(from: Date()))
            ),
            sharedLibraryLine: Copy.Review.sharedLibrary,
            confirmTitle: Copy.Videos.removeButton(ordered.count),
            confirm: { [weak self] in
                await self?.removeVideos(ordered)
                done?()
            }
        )
    }

    /// Whether choosing this copy makes it the one kept. Copies kept safe (favorites, edits,
    /// documents, rule-kept) stay whatever is chosen, and the merge goes onto the first copy
    /// kept, so only a copy listed above every kept-safe one can be chosen.
    func canChooseCopy(_ id: String, in group: PhotoGroup) -> Bool {
        for member in group.members {
            if member.id == id { return true }
            if group.isProtected(member.id) { return false }
        }
        return false
    }

    /// Where the kept copy will be after merging, by title: the albums it's in now and the ones
    /// it joins. A copy in an album it can't join isn't removed (`CopyMerge.sparingAlbums`), so
    /// that album isn't named.
    func albumTitles(for group: PhotoGroup) -> [String] {
        let keeper = copyKeeper(in: group).id
        let merge = CopyMerge(keeperID: keeper, removeIDs: removals(in: group).map(\.id)).sparingAlbums(albums)
        let joined = Set(merge.albumsToJoin(albums).map(\.id))
        return albums.filter { $0.assetIDs.contains(keeper) || joined.contains($0.id) }.map(\.title).sorted()
    }

    /// Marks or unmarks every screenshot in `ids`: all of them when any is unmarked, otherwise
    /// none. Returns whether they're marked now.
    @discardableResult
    func toggleMarks(_ ids: [String]) -> Bool {
        let all = Set(ids)
        if all.isSubset(of: markedScreenshots) {
            markedScreenshots.subtract(all)
            return false
        }
        markedScreenshots.formUnion(all)
        return true
    }
}

// MARK: Months

/// Screenshots taken in one calendar month, newest first.
struct ScreenshotMonth: Identifiable, Hashable {
    /// The first moment of the month.
    let month: Date
    let items: [AssetMeta]

    var id: Date { month }

    static func start(of date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? date
    }

    /// Groups screenshots by month, newest month first, keeping their order within a month.
    static func sections(_ metas: [AssetMeta], calendar: Calendar = .current) -> [ScreenshotMonth] {
        var order: [Date] = []
        var byMonth: [Date: [AssetMeta]] = [:]
        for meta in metas.sorted(by: { $0.creationDate > $1.creationDate }) {
            let month = start(of: meta.creationDate, calendar: calendar)
            if byMonth[month] == nil { order.append(month) }
            byMonth[month, default: []].append(meta)
        }
        return order.map { ScreenshotMonth(month: $0, items: byMonth[$0] ?? []) }
    }
}

extension Copy.Screenshots.Filter {
    /// Whether a screenshot taken on `date` shows under this filter.
    func includes(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .all: true
        case .olderThanMonth: date < (calendar.date(byAdding: .month, value: -1, to: now) ?? now)
        case .olderThanYear: date < (calendar.date(byAdding: .year, value: -1, to: now) ?? now)
        }
    }
}

// MARK: List notes

extension View {
    /// Text above or below a list's rows, drawn as a row without a card so it wraps at every
    /// text size: a heading line, or what the rules keep safe.
    func photoListNote() -> some View {
        self
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: Space.xs, leading: Space.xs, bottom: Space.xs, trailing: Space.xs))
    }
}

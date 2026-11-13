import Foundation
import SwiftUI
import Testing
import TidykeepCore
@testable import TidykeepUI

/// History, the receipt, Rules, the album picker and About, drawn from the demo library with
/// receipts of every kind and status.
///
///     TK_RENDER_DIR=/tmp/renders bash scripts/test.sh --filter HistoryRulesRenders
@MainActor @Suite(.serialized) struct HistoryRulesRenders {
    @Test func historyAndRules() async throws {
        let state = try await RenderHarness.demoState()
        let ids = try await HistoryDemo.fill(state)

        await RenderHarness.render(HistoryView(), named: "history", state: state, height: 1500)
        await RenderHarness.render(ReceiptView(receiptID: ids.photos), named: "receipt-photos", state: state, height: 1100)
        await RenderHarness.render(ReceiptView(receiptID: ids.files), named: "receipt-files", state: state, height: 1100)
        await RenderHarness.render(ReceiptView(receiptID: ids.contacts), named: "receipt-contacts", state: state)
        await RenderHarness.render(ReceiptView(receiptID: ids.expired), named: "receipt-expired", state: state)

        state.preferences.rules.albumIDs = ["album-family"]
        state.photos.refresh()
        await RenderHarness.render(RulesView(), named: "rules", state: state, height: 2200)
        await RenderHarness.render(AlbumPickerView(), named: "albums", state: state)
        await RenderHarness.render(AboutView(), named: "about", state: state, height: 1500)

        state.history.clear()
        await RenderHarness.render(HistoryView(), named: "history-empty", state: state)
        await RenderHarness.render(ReceiptView(receiptID: ids.photos), named: "receipt-missing", state: state)
    }
}

/// Receipts for the renders: one of every kind, across several days, including a partial
/// change recovered after an interruption, a failed one, an undone one and an expired one.
@MainActor
enum HistoryDemo {
    struct IDs {
        var photos: UUID
        var files: UUID
        var contacts: UUID
        var expired: UUID
    }

    static func fill(_ state: AppState) async throws -> IDs {
        let history = state.history
        let day: TimeInterval = 86_400
        let now = Date()

        func move(_ id: UUID, back seconds: TimeInterval) {
            history.update(id) {
                $0.date = now.addingTimeInterval(-seconds)
                if $0.deadline != nil { $0.deadline = Receipt.recentlyDeletedDeadline(from: $0.date) }
            }
        }

        // Older days first, so the log's own order matches what a person would have done.
        let expired = history.begin(.photosRemoved, requested: 14, itemIDs: (0..<14).map { "gone-\($0)" })
        history.finish(expired, completed: 14)
        move(expired, back: 45 * day)

        let deleted = history.begin(.filesDeleted, requested: 3, bytes: 1_284_517_888)
        history.finish(deleted, completed: 3)
        move(deleted, back: 9 * day)

        let contacts = history.begin(.contactsMerged, requested: 2, title: "Aditya Kopalli")
        history.finish(contacts, completed: 1)
        history.update(contacts) { $0.status = .done }
        move(contacts, back: 9 * day + 3_600)

        let putBack = history.begin(.filesPutBack, requested: 2, itemIDs: ["Downloads/IMG_2041.MOV", "Downloads/IMG_2042.MOV"], bytes: 412_000_000)
        history.finish(putBack, completed: 2)
        move(putBack, back: 1 * day)

        let files = history.begin(
            .filesHeld, requested: 4,
            itemIDs: ["Downloads/Invoice-2026-03.pdf", "Downloads/Invoice-2026-03 (1).pdf", "Documents/Lease scan.pdf", "Downloads/Boarding pass.pdf"],
            bytes: 18_420_224
        )
        history.finish(files, completed: 4)
        move(files, back: 1 * day + 7_200)

        let failed = history.begin(.videosRemoved, requested: 2, itemIDs: ["video-clip", "video-drive"])
        history.finish(failed, completed: 0, keepIfFailed: true)
        move(failed, back: 1 * day + 9_000)

        // Today: a merge, a keep-all that was taken back, a check cut off by quitting, and a
        // fresh removal.
        let merged = history.begin(.copiesMerged, requested: 3, itemIDs: ["a", "b", "c"])
        history.finish(merged, completed: 3)
        move(merged, back: 5_400)

        let undone = history.begin(.keptAll, requested: 4, itemIDs: ["group-x"])
        history.finish(undone, completed: 4)
        move(undone, back: 4_800)
        if let receipt = history.receipt(undone) { state.photos.reviewAgain(receipt) }

        let shots = state.photos.screenshots.prefix(2).map(\.id)
        let interrupted = history.begin(.screenshotsRemoved, requested: 5, itemIDs: shots + ["gone-a", "gone-b", "gone-c"])
        move(interrupted, back: 3_000)
        await state.recoverInterrupted()

        if let group = state.photos.similar.first { state.photos.keepAll(group) }
        // A removal recorded directly, so the demo library on disk is never touched.
        let photos = history.begin(.photosRemoved, requested: 9, itemIDs: (0..<9).map { "removed-\($0)" })
        history.finish(photos, completed: 9)
        move(photos, back: 600)

        return IDs(photos: photos, files: files, contacts: contacts, expired: expired)
    }
}

// MARK: - Behaviour

/// History and Rules without drawing: grouping by day, the words on receipts, undo from a
/// row, and rules that stick.
@MainActor @Suite struct HistoryRulesTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func makeState(defaults: UserDefaults = freshDefaults()) -> AppState {
        AppState(photoSource: MemoryPhotoSource(photos: [AssetMeta(id: "kept", creationDate: now)]), analyzer: ConstantAnalyzer(), directory: nil, defaults: defaults, findsCopies: false)
    }

    @Test func receiptsGroupByDayNewestFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = calendar.startOfDay(for: now)
        let receipts = [
            Receipt(kind: .photosRemoved, date: today.addingTimeInterval(3_600), status: .done, requested: 1, completed: 1),
            Receipt(kind: .filesHeld, date: today.addingTimeInterval(-3_600), status: .done, requested: 1, completed: 1),
            Receipt(kind: .keptAll, date: today.addingTimeInterval(7_200), status: .done, requested: 3, completed: 3),
            Receipt(kind: .filesDeleted, date: today.addingTimeInterval(-10 * 86_400), status: .done, requested: 2, completed: 2),
        ]
        let days = ReceiptDay.group(receipts, calendar: calendar)
        #expect(days.map(\.day) == [today, today.addingTimeInterval(-86_400), today.addingTimeInterval(-10 * 86_400)])
        #expect(days[0].receipts.map(\.kind) == [.keptAll, .photosRemoved])
        #expect(days[1].receipts.map(\.kind) == [.filesHeld])
        #expect(ReceiptDay.group([], calendar: calendar).isEmpty)

        #expect(Copy.Receipts.dayHeader(today, now: now, calendar: calendar) == "Today")
        #expect(Copy.Receipts.dayHeader(days[1].day, now: now, calendar: calendar) == "Yesterday")
        #expect(Copy.Receipts.dayHeader(days[2].day, now: now, calendar: calendar) == Copy.day(days[2].day))
    }

    @Test func rulesPersistAcrossLaunches() {
        let defaults = freshDefaults()
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.protectsMyCard)
        #expect(preferences.rules.keepScreenshotsInAlbums)
        #expect(preferences.rules.hideFilesChangedWithinDays == 7)

        preferences.rules.albumIDs.insert("album-family")
        preferences.rules.keepScreenshotsInAlbums = false
        preferences.rules.hideFilesChangedWithinDays = 0
        preferences.protectsMyCard = false
        preferences.scope = .last30Days
        preferences.sensitivity = .loose
        preferences.videoMinimum = 300
        preferences.largeFileMinimum = 500_000_000

        let relaunched = Preferences(defaults: defaults)
        #expect(relaunched.rules.albumIDs == ["album-family"])
        #expect(!relaunched.rules.keepScreenshotsInAlbums)
        // Off is 0 days: nil reads back as the 7-day default.
        #expect(relaunched.rules.hideFilesChangedWithinDays == 0)
        #expect(!relaunched.protectsMyCard)
        #expect(relaunched.scope == .last30Days)
        #expect(relaunched.sensitivity == .loose)
        #expect(relaunched.videoMinimum == 300)
        #expect(relaunched.largeFileMinimum == 500_000_000)
        #expect(Preferences.Keys.all.contains(Preferences.Keys.protectsMyCard))
    }

    @Test func reviewAgainFromHistoryUndoesKeepAll() async throws {
        let state = makeState()
        let id = state.history.begin(.keptAll, requested: 3, itemIDs: ["group"])
        state.history.finish(id, completed: 3)
        let receipt = try #require(state.history.receipt(id))
        #expect(state.canUndo(receipt))
        #expect(Copy.Receipts.actionTitle(receipt.kind) == "Review again")

        await takeBack(receipt, state: state)
        let after = try #require(state.history.receipt(id))
        #expect(after.status == .undone)
        #expect(!state.canUndo(after))
        #expect(Copy.Receipts.status(after) == "Undone")
        #expect(state.notices.text == Copy.Notices.reviewAgain)
    }

    @Test func interruptedReceiptsShowWhatWasFound() async {
        let state = makeState()
        let id = state.history.begin(.photosRemoved, requested: 3, itemIDs: ["kept", "gone-1", "gone-2"])
        #expect(Copy.Receipts.status(state.history.receipt(id)!).hasPrefix("Not finished"))
        await state.recoverInterrupted()
        let receipt = state.history.receipt(id)!
        #expect(receipt.status == .partial)
        #expect(Copy.Receipts.sentence(receipt) == "Removed 2 photos")
        #expect(Copy.Receipts.status(receipt).hasPrefix("2 of 3 done · In Recently Deleted until "))
        #expect(Copy.Receipts.howManyValue(receipt) == "2 of 3 photos")
    }

    @Test func receiptsSayHowToGetThingsBack() {
        let date = now
        var photos = Receipt(kind: .photosRemoved, date: date, status: .done, requested: 9, completed: 9, bytes: 123, deadline: Receipt.recentlyDeletedDeadline(from: date))
        #expect(Copy.Receipts.recoverySteps(photos, now: now).count == 5)
        #expect(Copy.Receipts.recoveryIntro(photos, now: now).contains("Recently Deleted"))
        #expect(Copy.Receipts.fileNameList(photos) == nil)
        // Photos never show a size, even if one was recorded.
        #expect(!Copy.Receipts.howManyValue(photos).contains("B"))

        photos.deadline = now.addingTimeInterval(-1)
        #expect(Copy.Receipts.recoverySteps(photos, now: now).isEmpty)
        #expect(Copy.Receipts.status(photos, now: now) == "Gone from Recently Deleted")

        let deleted = Receipt(kind: .filesDeleted, date: date, status: .done, requested: 2, completed: 2, bytes: 2_000_000)
        #expect(Copy.Receipts.recoverySteps(deleted, now: now).isEmpty)
        #expect(Copy.Receipts.undoLine(deleted, now: now) == Copy.Reason.cantBeUndone)

        let held = Receipt(kind: .filesHeld, date: date, status: .done, requested: 10, completed: 10, itemIDs: (1...10).map { "Downloads/file-\($0).pdf" })
        let names = Copy.Receipts.fileNameList(held, limit: 8)!
        #expect(names.hasPrefix("file-1.pdf\nfile-2.pdf"))
        #expect(names.hasSuffix("and 2 more"))
        #expect(Copy.Receipts.actionTitle(held.kind) == "Put back")
        #expect(Copy.Receipts.exactSize(18_420_224).hasSuffix("(\(Int64(18_420_224).formatted()) bytes)"))

        for kind in Receipt.Kind.allCases {
            let receipt = Receipt(kind: kind, date: date, status: .done, requested: 1, completed: 1, deadline: Receipt.recentlyDeletedDeadline(from: date))
            for text in [Copy.Receipts.undoLine(receipt, now: now), Copy.Receipts.recoveryIntro(receipt, now: now)] + Copy.Receipts.recoverySteps(receipt, now: now) {
                #expect(!text.isEmpty)
                #expect(!text.contains("!"))
                #expect(!text.lowercased().contains("free up"))
            }
        }
    }

    @Test func clearHistoryEmptiesIt() {
        let state = makeState()
        let id = state.history.begin(.filesDeleted, requested: 1, bytes: 10)
        state.history.finish(id, completed: 1)
        #expect(!state.history.receipts.isEmpty)
        state.clearHistory()
        #expect(state.history.receipts.isEmpty)
        #expect(state.notices.text == Copy.Notices.historyCleared)
    }

    @Test func aboutHasNoLinksAndAPlainTextAddress() {
        #expect(!Copy.About.supportEmail.contains(":"))
        #expect(Copy.About.supportEmail.contains("@"))
        let all = Copy.About.privacyBullets.map(\.text) + Copy.About.cantDoBullets.map(\.text) + [Copy.About.free]
        #expect(all.allSatisfy { !$0.contains("//") && !$0.contains("!") })
        #expect(Copy.About.free == "Free. No purchases, ads, tips or subscriptions.")
    }
}

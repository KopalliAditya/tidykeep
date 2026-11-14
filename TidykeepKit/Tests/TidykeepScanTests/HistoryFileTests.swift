import Foundation
import Testing
import TidykeepCore
@testable import TidykeepUI

/// History's file: what is left in it across launches, and a receipt that can't be saved.
@MainActor @Suite struct HistoryFileTests {
    let data = temporaryDirectory("history-\(UUID().uuidString)")

    var file: JSONFile<ReceiptLog> { JSONFile(url: data.appendingPathComponent("history.json")) }

    @Test func receiptsTooOldToKeepLeaveTheFile() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let old = Receipt(
            kind: .filesHeld, date: now.addingTimeInterval(-ReceiptLog.keepFor - 86_400), status: .done,
            requested: 1, completed: 1)
        let recent = Receipt(kind: .filesHeld, date: now.addingTimeInterval(-86_400), status: .done, requested: 1, completed: 1)
        try file.save(ReceiptLog(receipts: [old, recent]))

        let history = History(directory: data, now: { now })
        #expect(history.receipts.map(\.id) == [recent.id])
        #expect(file.load()?.receipts.map(\.id) == [recent.id])
    }

    @Test func beginSavedWritesTheReceiptStraightAway() throws {
        let history = History(directory: data)
        let id = try history.beginSaved(.contactsMerged, requested: 2, itemIDs: ["a"], title: "Ana")
        #expect(history.receipt(id)?.status == .inProgress)
        #expect(file.load()?.receipt(id)?.title == "Ana")
    }

    @Test func aReceiptThatCantBeSavedIsntRecorded() throws {
        let history = History(directory: data)
        let kept = history.begin(.filesHeld, requested: 1)
        // A folder where the file should be, so saving it fails.
        try FileManager.default.removeItem(at: file.url)
        try FileManager.default.createDirectory(at: file.url, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file.url.appendingPathComponent("inside"))

        #expect(throws: (any Error).self) {
            try history.beginSaved(.contactsMerged, requested: 2, itemIDs: ["a"], title: "Ana")
        }
        #expect(history.receipts.map(\.id) == [kept])
        // Plain `begin` still keeps its receipt in memory when the save fails.
        let unsaved = history.begin(.filesHeld, requested: 1)
        #expect(history.receipt(unsaved) != nil)
    }
}

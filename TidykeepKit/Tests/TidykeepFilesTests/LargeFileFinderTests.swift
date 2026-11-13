import Foundation
import Testing
@testable import TidykeepFiles

@Suite("Large files")
struct LargeFileFinderTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let day: TimeInterval = 86_400

    func item(_ name: String, bytes: Int64, modifiedDaysAgo: Double, createdDaysAgo: Double? = nil) -> FileItem {
        FileItem(
            url: URL(fileURLWithPath: "/f/\(name)"),
            bytes: bytes,
            modified: now - modifiedDaysAgo * day,
            created: createdDaysAgo.map { now - $0 * day },
            folderID: UUID(),
            relativePath: name
        )
    }

    @Test func keepsFilesAtOrOverTheThresholdBiggestFirst() {
        let items = [
            item("just-under.mov", bytes: 99_999_999, modifiedDaysAgo: 30),
            item("exactly.mov", bytes: 100_000_000, modifiedDaysAgo: 30),
            item("huge.mov", bytes: 4_000_000_000, modifiedDaysAgo: 30),
            item("medium.zip", bytes: 300_000_000, modifiedDaysAgo: 30),
        ]

        let found = LargeFileFinder.find(items, now: now)

        #expect(found.map(\.name) == ["huge.mov", "medium.zip", "exactly.mov"])
    }

    @Test func customThreshold() {
        let items = [item("a", bytes: 2_000, modifiedDaysAgo: 30), item("b", bytes: 500, modifiedDaysAgo: 30)]
        #expect(LargeFileFinder.find(items, minBytes: 1_000, now: now).map(\.name) == ["a"])
    }

    @Test func hidesFilesChangedRecently() {
        let items = [
            item("edited-yesterday.mov", bytes: 500_000_000, modifiedDaysAgo: 1),
            item("copied-in-yesterday.mov", bytes: 500_000_000, modifiedDaysAgo: 300, createdDaysAgo: 1),
            item("last-week.mov", bytes: 500_000_000, modifiedDaysAgo: 8),
            item("on-the-line.mov", bytes: 500_000_000, modifiedDaysAgo: 7),
        ]

        let found = LargeFileFinder.find(items, now: now)

        #expect(Set(found.map(\.name)) == ["last-week.mov", "on-the-line.mov"])
        #expect(LargeFileFinder.find(items, hideChangedWithinDays: 0, now: now).count == 4)
        #expect(LargeFileFinder.find(items, hideChangedWithinDays: nil, now: now).count == 4)
        #expect(LargeFileFinder.find(items, hideChangedWithinDays: 30, now: now).isEmpty)
    }
}

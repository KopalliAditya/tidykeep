import Foundation

/// Files that take up a lot of space, biggest first.
public enum LargeFileFinder: Sendable {
    /// Files taking at least `minBytes` on disk. With `hideChangedWithinDays`, files created or
    /// changed in that many days before `now` are left out (the "files changed in the last 7
    /// days" rule): something the user is still working on isn't clutter. Both dates count,
    /// because a file copied in keeps its old modification date but gets a new creation date.
    /// Pass nil to show every large file.
    public static func find(
        _ items: [FileItem],
        minBytes: Int64 = 100_000_000,
        hideChangedWithinDays: Int? = 7,
        now: Date
    ) -> [FileItem] {
        let cutoff = hideChangedWithinDays.map { now.addingTimeInterval(-TimeInterval($0) * 86_400) }
        return items
            .filter { $0.bytes >= minBytes }
            .filter { item in
                guard let cutoff else { return true }
                let latest = max(item.modified, item.created ?? item.modified)
                return latest <= cutoff
            }
            .sorted { a, b in a.bytes != b.bytes ? a.bytes > b.bytes : a.id < b.id }
    }
}

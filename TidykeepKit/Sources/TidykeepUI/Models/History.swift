import Foundation
import Observation
import TidykeepCore

/// Every change the app made, newest first, saved on this iPhone.
///
/// Two steps per change: `begin` is saved before the change is made and `finish` after, so a
/// change cut off by the app quitting is found on the next launch and finished from what is
/// true then (`AppState.recoverInterrupted`).
@MainActor
@Observable
public final class History {
    public private(set) var log: ReceiptLog
    private let file: JSONFile<ReceiptLog>?
    private let now: () -> Date

    public init(directory: URL?, now: @escaping () -> Date = Date.init) {
        self.file = directory.map { JSONFile(url: $0.appendingPathComponent("history.json")) }
        self.now = now
        var log = file?.load() ?? ReceiptLog()
        log.prune(now: now())
        self.log = log
    }

    public var receipts: [Receipt] { log.receipts }

    /// The newest change that did something, for the Home header.
    public var lastChange: Receipt? { log.receipts.first { $0.status != .inProgress && $0.status != .failed } }

    public func receipt(_ id: UUID) -> Receipt? { log.receipt(id) }

    /// Records a change before making it. Saved straight away.
    @discardableResult
    public func begin(
        _ kind: Receipt.Kind,
        requested: Int,
        itemIDs: [String] = [],
        bytes: Int64? = nil,
        title: String? = nil,
        payload: Data? = nil
    ) -> UUID {
        let date = now()
        let deadline: Date? = switch kind {
        case .photosRemoved, .screenshotsRemoved, .videosRemoved, .copiesMerged: Receipt.recentlyDeletedDeadline(from: date)
        default: nil
        }
        let receipt = Receipt(kind: kind, date: date, requested: requested, itemIDs: itemIDs, bytes: bytes, title: title, deadline: deadline, payload: payload)
        log.begin(receipt)
        save()
        return receipt.id
    }

    public func finish(_ id: UUID, completed: Int, keepIfFailed: Bool = false, update: (inout Receipt) -> Void = { _ in }) {
        log.finish(id, completed: completed, at: now(), keepIfFailed: keepIfFailed, update: update)
        save()
    }

    /// The user cancelled before anything changed.
    public func discard(_ id: UUID) {
        log.discard(id)
        save()
    }

    public func markUndone(_ id: UUID) {
        log.markUndone(id)
        save()
    }

    public func update(_ id: UUID, _ change: (inout Receipt) -> Void) {
        log.update(id, change)
        save()
    }

    public var interrupted: [Receipt] { log.interrupted }

    public func recover(_ id: UUID, stillThere: Int) {
        log.recover(id, stillThere: stillThere, at: now())
        save()
    }

    public func clear() {
        log.removeAll()
        save()
    }

    private func save() {
        try? file?.save(log)
    }
}

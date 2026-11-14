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
        let loaded = log.receipts.count
        log.prune(now: now())
        self.log = log
        // Saved, so receipts too old to keep leave the file as well as the screen.
        if log.receipts.count < loaded { save() }
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
        let receipt = newReceipt(kind, requested: requested, itemIDs: itemIDs, bytes: bytes, title: title, payload: payload)
        log.begin(receipt)
        save()
        return receipt.id
    }

    /// `begin` for a change that only its saved receipt can undo after a relaunch, such as a
    /// contact merge. Throws when the receipt couldn't be saved, with nothing recorded, so the
    /// change can stop before it starts.
    public func beginSaved(
        _ kind: Receipt.Kind,
        requested: Int,
        itemIDs: [String] = [],
        bytes: Int64? = nil,
        title: String? = nil,
        payload: Data? = nil
    ) throws -> UUID {
        let receipt = newReceipt(kind, requested: requested, itemIDs: itemIDs, bytes: bytes, title: title, payload: payload)
        log.begin(receipt)
        do {
            try file?.save(log)
        } catch {
            log.discard(receipt.id)
            throw error
        }
        return receipt.id
    }

    private func newReceipt(
        _ kind: Receipt.Kind, requested: Int, itemIDs: [String], bytes: Int64?, title: String?, payload: Data?
    ) -> Receipt {
        let date = now()
        let deadline: Date? = switch kind {
        case .photosRemoved, .screenshotsRemoved, .videosRemoved, .copiesMerged: Receipt.recentlyDeletedDeadline(from: date)
        default: nil
        }
        return Receipt(kind: kind, date: date, requested: requested, itemIDs: itemIDs, bytes: bytes, title: title, deadline: deadline, payload: payload)
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

    // MARK: Undo in progress

    /// Receipts whose undo is running right now. Kept in memory only: an undo cut off by the
    /// app quitting leaves its receipt as it was, so it can be tried again.
    public private(set) var undoing: Set<UUID> = []

    public func isUndoing(_ id: UUID) -> Bool { undoing.contains(id) }

    /// Runs a receipt's undo unless one is already running for it, so the History row, the
    /// receipt and the notice banner can never start the same undo twice.
    /// - Returns: false when an undo for this receipt was already running.
    @discardableResult
    public func undoOnce(_ id: UUID, _ body: @MainActor () async -> Void) async -> Bool {
        guard !undoing.contains(id) else { return false }
        undoing.insert(id)
        defer { undoing.remove(id) }
        await body()
        return true
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

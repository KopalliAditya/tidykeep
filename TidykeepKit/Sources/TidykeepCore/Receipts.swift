import Foundation

/// A record of one change the user made: photos removed, files moved to Holding, cards merged.
/// History shows these, and every way back starts from one.
///
/// A receipt is written in two steps: just before the change (`inProgress`) and after it, with
/// the outcome. If the app dies in between, the next launch finds the receipt still in progress
/// and checks what actually happened, so History never claims a change that didn't happen or
/// forgets one that did.
///
/// Receipts hold metadata only (counts, identifiers, file names, byte counts), never images.
public struct Receipt: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case photosRemoved
        case screenshotsRemoved
        case videosRemoved
        /// Favorites and albums moved onto the kept copy, then the other copies removed.
        case copiesMerged
        /// "Keep all": nothing changed in the library, but the group won't be suggested again.
        case keptAll
        case filesHeld
        case filesPutBack
        /// Permanent: Empty Holding or Delete now.
        case filesDeleted
        case contactsMerged
    }

    public enum Status: String, Sendable, Codable {
        case inProgress
        case done
        /// Some items changed and some didn't; `completed` says how many did.
        case partial
        /// Nothing changed.
        case failed
        /// Reversed later from History.
        case undone
    }

    public let id: UUID
    public let kind: Kind
    /// When the change started. Updated when it finishes.
    public var date: Date
    public var status: Status
    /// Items the change was asked to touch.
    public var requested: Int
    /// Items it actually touched.
    public var completed: Int
    /// What was touched: photo local identifiers, file paths or contact identifiers. Used to
    /// check an interrupted change on the next launch.
    public var itemIDs: [String]
    /// Exact bytes, for files only. Photos and videos never show a size.
    public var bytes: Int64?
    /// A name to show, such as the kept contact's name or a single file's name.
    public var title: String?
    /// Until when the change can be reversed outside the app, such as the end of the 30 days in
    /// Recently Deleted.
    public var deadline: Date?
    /// What the owning feature needs to undo the change, encoded by that feature (merge
    /// changes, Holding item IDs, a contact backup ID). Opaque here so Core needn't know them.
    public var payload: Data?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        date: Date,
        status: Status = .inProgress,
        requested: Int,
        completed: Int = 0,
        itemIDs: [String] = [],
        bytes: Int64? = nil,
        title: String? = nil,
        deadline: Date? = nil,
        payload: Data? = nil
    ) {
        self.id = id
        self.kind = kind
        self.date = date
        self.status = status
        self.requested = requested
        self.completed = completed
        self.itemIDs = itemIDs
        self.bytes = bytes
        self.title = title
        self.deadline = deadline
        self.payload = payload
    }

    /// Photos stay in Recently Deleted for 30 days after removal.
    public static let recentlyDeletedDays = 30

    public static func recentlyDeletedDeadline(from date: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: recentlyDeletedDays, to: date) ?? date.addingTimeInterval(30 * 86_400)
    }

    /// Something left the photo library and sits in Recently Deleted until `deadline`.
    public var wentToRecentlyDeleted: Bool {
        switch kind {
        case .photosRemoved, .screenshotsRemoved, .videosRemoved, .copiesMerged: completed > 0
        default: false
        }
    }
}

/// Every receipt, newest first. Pure, so the rules for writing, finishing and recovering
/// receipts can be tested without files.
public struct ReceiptLog: Sendable, Hashable, Codable {
    public private(set) var receipts: [Receipt] = []

    /// Receipts older than this are dropped, so History stays readable.
    public static let keepFor: TimeInterval = 366 * 86_400

    public init(receipts: [Receipt] = []) {
        self.receipts = receipts.sorted(by: Self.newestFirst)
    }

    public func receipt(_ id: UUID) -> Receipt? { receipts.first { $0.id == id } }

    /// Step one: record the change before making it.
    public mutating func begin(_ receipt: Receipt) {
        receipts.removeAll { $0.id == receipt.id }
        receipts.insert(receipt, at: 0)
        receipts.sort(by: Self.newestFirst)
    }

    /// Step two: record what happened. `completed == 0` means nothing changed, so a receipt
    /// that was only ever going to say "nothing happened" is dropped rather than kept as noise,
    /// unless the change failed with an error worth showing.
    public mutating func finish(_ id: UUID, completed: Int, at date: Date, keepIfFailed: Bool = false, update: (inout Receipt) -> Void = { _ in }) {
        guard let index = receipts.firstIndex(where: { $0.id == id }) else { return }
        var receipt = receipts[index]
        receipt.completed = completed
        receipt.date = date
        receipt.status = completed == 0 ? .failed : (completed < receipt.requested ? .partial : .done)
        update(&receipt)
        if receipt.status == .failed && !keepIfFailed {
            receipts.remove(at: index)
        } else {
            receipts[index] = receipt
        }
    }

    /// The user cancelled before anything changed (say, in the iOS delete alert).
    public mutating func discard(_ id: UUID) {
        receipts.removeAll { $0.id == id }
    }

    public mutating func markUndone(_ id: UUID) {
        guard let index = receipts.firstIndex(where: { $0.id == id }) else { return }
        receipts[index].status = .undone
    }

    public mutating func update(_ id: UUID, _ change: (inout Receipt) -> Void) {
        guard let index = receipts.firstIndex(where: { $0.id == id }) else { return }
        change(&receipts[index])
    }

    /// Receipts whose change may have been cut off by the app quitting.
    public var interrupted: [Receipt] { receipts.filter { $0.status == .inProgress } }

    /// Finishes an interrupted receipt from what is true now: `stillThere` is how many of its
    /// items are still where they started (still in the library, still in the folder).
    public mutating func recover(_ id: UUID, stillThere: Int, at date: Date) {
        guard let receipt = receipt(id) else { return }
        let changed = max(0, receipt.requested - stillThere)
        finish(id, completed: changed, at: date)
    }

    public mutating func prune(now: Date) {
        receipts.removeAll { now.timeIntervalSince($0.date) > Self.keepFor && $0.status != .inProgress }
    }

    public mutating func removeAll() { receipts.removeAll() }

    static func newestFirst(_ a: Receipt, _ b: Receipt) -> Bool {
        a.date != b.date ? a.date > b.date : a.id.uuidString < b.id.uuidString
    }
}

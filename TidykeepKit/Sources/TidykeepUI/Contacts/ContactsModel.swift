import Foundation
import Observation
import TidykeepCore

/// Duplicate contact cards: finding them, merging them with a backup, and undo.
///
/// STUB: the Contacts slice replaces this file. The properties and methods here are the
/// contract the shell (Home, AppState) relies on; keep their names and meanings.
@MainActor
@Observable
public final class ContactsModel {
    public enum Access: Equatable { case notDetermined, denied, allowed }

    public private(set) var access: Access = .notDetermined
    public private(set) var isScanning = false
    public private(set) var duplicateGroupCount = 0
    /// Cards that would go if every group were merged.
    public private(set) var extraCardCount = 0

    private let directory: URL?
    private let preferences: Preferences
    private let history: History
    private let notices: Notices

    public init(directory: URL?, preferences: Preferences, history: History, notices: Notices) {
        self.directory = directory
        self.preferences = preferences
        self.history = history
        self.notices = notices
    }

    /// Reads access without asking; checks when it's allowed.
    public func start() async {}
    public func rescan() {}
    /// Undo for a `.contactsMerged` receipt.
    public func undo(_ receipt: Receipt) async {}
    /// How many of an interrupted receipt's removed cards still exist.
    func stillThere(_ receipt: Receipt) async -> Int { receipt.requested }
    /// Simulator only, for UI tests (`-TKSeedContacts YES`).
    func seedSample() {}
}

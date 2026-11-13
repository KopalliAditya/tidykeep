import Foundation
import Observation
import TidykeepCore

/// Files in folders the user chose: duplicates, large files and Holding.
///
/// STUB: the Files slice replaces this file. The properties and methods here are the contract
/// the shell (Home, AppState) relies on; keep their names and meanings.
@MainActor
@Observable
public final class FilesModel {
    /// Folders the user chose, by name.
    public private(set) var folderNames: [String] = []
    public private(set) var isScanning = false
    /// Sets of identical files.
    public private(set) var duplicateSetCount = 0
    /// Bytes the extra copies take.
    public private(set) var duplicateExtraBytes: Int64 = 0
    public private(set) var largeFileCount = 0
    public private(set) var largeFileBytes: Int64 = 0
    /// Files in "Held by Tidykeep".
    public private(set) var holdingCount = 0
    public private(set) var holdingBytes: Int64 = 0

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

    public var folderCount: Int { folderNames.count }

    /// Loads the saved folders and checks them.
    public func start() async {}
    public func rescan() {}
    /// Checks again when the app comes back if the folders may have changed.
    public func refreshIfStale() async {}
    /// Undo for a `.filesHeld` receipt: moves the files back where they were.
    public func putBack(_ receipt: Receipt) async {}
    /// How many of an interrupted receipt's files are still where they started.
    func stillThere(_ receipt: Receipt) async -> Int { receipt.requested }
    /// Simulator only, for UI tests (`-TKSeedFiles YES`).
    func seedSample() {}
}

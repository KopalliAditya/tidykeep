import Foundation
import Observation
import SwiftUI
import TidykeepContacts
import TidykeepCore

/// Everything the app knows, in one place the views share: the three areas (photos, files,
/// contacts), History, Rules and the notice banner.
@MainActor
@Observable
public final class AppState {
    public let preferences: Preferences
    public let history: History
    public let notices: Notices
    public let photos: PhotosModel
    public let files: FilesModel
    public let contacts: ContactsModel
    public var showsOnboarding: Bool
    /// Light or dark for UI tests and screenshots (`-TKAppearance dark`); nil follows the system.
    public let appearance: ColorScheme?
    private var started = false

    /// - Parameter directory: where saved data lives; nil keeps everything in memory.
    /// - Parameter contactStore: the address book; nil uses `ContactsModel`'s default.
    public init(
        photoSource: any PhotoSource,
        analyzer: any FrameAnalyzing,
        directory: URL?,
        defaults: UserDefaults = .standard,
        conditions: @escaping @Sendable () -> DeviceConditions = { .current() },
        findsCopies: Bool = true,
        contactStore: (any ContactStoring)? = nil
    ) {
        let hooks = TestHooks(defaults: defaults)
        if hooks.resetState { TestHooks.reset(directory: directory, defaults: defaults) }

        let preferences = Preferences(defaults: defaults)
        let history = History(directory: directory)
        let notices = Notices()
        self.preferences = preferences
        self.history = history
        self.notices = notices
        self.photos = PhotosModel(
            source: photoSource, analyzer: analyzer, directory: directory,
            preferences: preferences, history: history, notices: notices,
            conditions: conditions, findsCopies: findsCopies
        )
        self.files = FilesModel(directory: directory, preferences: preferences, history: history, notices: notices)
        self.contacts = ContactsModel(directory: directory, preferences: preferences, history: history, notices: notices, store: contactStore)
        self.showsOnboarding = !preferences.onboarded
        self.appearance = hooks.appearance

        #if targetEnvironment(simulator)
        if hooks.seedFiles { files.seedSample() }
        if hooks.seedContacts { contacts.seedSample() }
        #endif
    }

    /// Runs once at launch: finishes changes cut off last time, then starts checking whatever
    /// the app already has access to. Never asks for access by itself.
    public func start() async {
        guard !started else { return }
        started = true
        await recoverInterrupted()
        await photos.start()
        await files.start()
        await contacts.start()
    }

    /// Onboarding's Continue: the only time the app asks for photos on its own.
    public func finishOnboarding() async {
        preferences.onboarded = true
        showsOnboarding = false
        await photos.requestAccess()
    }

    public func scenePhaseChanged(to phase: ScenePhase) {
        photos.scenePhaseChanged(to: phase)
        if phase == .active, started {
            Task { await files.refreshIfStale() }
        }
    }

    /// Checks everything again: photos, folders and contacts.
    public func checkAgain() {
        photos.rescan()
        files.rescan()
        contacts.rescan()
    }

    // MARK: Undo

    /// Whether a receipt has a way back the app can take by itself.
    public func canUndo(_ receipt: Receipt) -> Bool {
        guard receipt.status == .done || receipt.status == .partial else { return false }
        switch receipt.kind {
        case .copiesMerged, .keptAll, .filesHeld, .contactsMerged: return true
        case .photosRemoved, .screenshotsRemoved, .videosRemoved, .filesPutBack, .filesDeleted: return false
        }
    }

    /// Takes a receipt's way back. Does nothing while an undo for it is already running
    /// (`History.isUndoing`), whichever screen started it.
    public func undo(_ receipt: Receipt) async {
        guard canUndo(receipt) else { return }
        await history.undoOnce(receipt.id) {
            // Read it again: a screen may hold a copy from before an earlier undo finished.
            guard let current = history.receipt(receipt.id), canUndo(current) else { return }
            switch current.kind {
            case .copiesMerged: await photos.undoMerge(current)
            case .keptAll: photos.reviewAgain(current)
            case .filesHeld: await files.putBack(current)
            case .contactsMerged: await contacts.undo(current)
            case .photosRemoved, .screenshotsRemoved, .videosRemoved, .filesPutBack, .filesDeleted: break
            }
        }
    }

    /// Finishes receipts whose change was cut off by the app quitting, from what is true now.
    func recoverInterrupted() async {
        for receipt in history.interrupted {
            let stillThere: Int
            switch receipt.kind {
            case .photosRemoved, .screenshotsRemoved, .videosRemoved, .copiesMerged:
                stillThere = await photos.stillThere(receipt)
            case .filesHeld, .filesPutBack, .filesDeleted:
                stillThere = await files.stillThere(receipt)
            case .contactsMerged:
                stillThere = await contacts.stillThere(receipt)
            case .keptAll:
                stillThere = 0
            }
            history.recover(receipt.id, stillThere: stillThere)
        }
    }

    // MARK: Saved data

    public func clearHistory() {
        history.clear()
        notices.show(Copy.Notices.historyCleared, systemImage: "clock.arrow.circlepath")
    }
}

/// Launch arguments for UI tests and screenshots. `-TKResetState YES` lands in the
/// `UserDefaults` argument domain, so `bool(forKey:)` sees it for this launch only.
struct TestHooks {
    var resetState: Bool
    var seedFiles: Bool
    var seedContacts: Bool
    var appearance: ColorScheme?

    init(defaults: UserDefaults) {
        resetState = defaults.bool(forKey: "TKResetState")
        seedFiles = defaults.bool(forKey: "TKSeedFiles")
        seedContacts = defaults.bool(forKey: "TKSeedContacts")
        appearance = switch defaults.string(forKey: "TKAppearance") {
        case "dark": .dark
        case "light": .light
        default: nil
        }
    }

    /// Back to a first launch: saved data and Rules are forgotten. The user's photos, files and
    /// contacts are untouched.
    static func reset(directory: URL?, defaults: UserDefaults) {
        for key in Preferences.Keys.all { defaults.removeObject(forKey: key) }
        guard let directory else { return }
        let fm = FileManager.default
        for item in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: item)
        }
    }
}

import Foundation
import Observation
import TidykeepContacts
import TidykeepCore

/// Duplicate contact cards: finding them, merging them with a backup, and undo.
///
/// Nothing changes without the user. Every merge is shown first, backed up as a vCard on this
/// iPhone, recorded in History before it is saved, and can be undone from the notice or from
/// History. Cards are only ever merged within one account.
///
/// iOS has no way to tell an app which card is the user's own, so there is no My Card switch.
/// The engine still never removes a card it knows to be My Card (on a Mac, where it can tell).
@MainActor
@Observable
public final class ContactsModel {
    public enum Access: Equatable { case notDetermined, denied, allowed }

    /// Why a merge didn't happen. Each says nothing changed and what to do next.
    enum MergeProblem: Equatable {
        /// A card changed or went away since the check.
        case changed
        case crossAccount
        case myCard
        case notAuthorized
        /// The backup couldn't be made or saved, so the merge didn't start.
        case backupFailed
        case other
    }

    public private(set) var access: Access = .notDetermined
    public private(set) var isScanning = false
    public private(set) var duplicateGroupCount = 0
    /// Cards that would go if every group were merged.
    public private(set) var extraCardCount = 0

    /// Groups that can be merged, in list order: same phone, then same email, then same name.
    private(set) var groups: [ContactDuplicateGroup] = []
    /// The same person in different accounts. Shown, never merged.
    private(set) var crossAccountGroups: [ContactDuplicateGroup] = []
    /// How many cards the last check read.
    private(set) var checkedCount = 0
    /// The user shared only some contacts.
    private(set) var isLimited = false
    /// Access is blocked on this iPhone (Screen Time or device management), so Settings
    /// can't turn it on. Shown as off.
    private(set) var isRestricted = false
    private(set) var hasChecked = false
    private(set) var scanFailed = false
    /// The group being merged right now, for the busy button.
    private(set) var mergingGroupID: String?
    /// The last merge that didn't happen, by group.
    private(set) var problems: [String: MergeProblem] = [:]
    /// Groups the user chose to keep apart. They aren't suggested again.
    private(set) var keptApart: Set<String> = []
    /// vCard backups saved on this iPhone, one per merge.
    private(set) var backupCount = 0
    /// An undo that would replace changes made after the merge, waiting for the user to say
    /// whether to go ahead. The root view asks with a confirmation dialog.
    var pendingUndoConflict: UndoConflict?

    /// An undo that stopped because the card that stayed changed after the merge.
    struct UndoConflict: Identifiable, Equatable {
        var receiptID: UUID
        var text: String
        var button: String
        var id: UUID { receiptID }
    }

    private let directory: URL?
    private let preferences: Preferences
    private let history: History
    private let notices: Notices
    private let store: any ContactStoring
    private let backups: ContactBackupStore?
    private let keptApartFile: JSONFile<[String]>?
    private var memoryBackups: [UUID: Data] = [:]
    private var cards: [String: ContactCard] = [:]
    private var mergeable: [ContactDuplicateGroup] = []
    private var scanTask: Task<Void, Never>?
    private var seedRequested = false
    private var seedTask: Task<Void, Never>?
    private var undoing: Set<UUID> = []

    /// - Parameter store: the address book. The real one on iPhone; on a Mac, where the
    ///   package only draws screens and runs tests, an empty book in memory, so nothing ever
    ///   opens the Mac's own contacts.
    public init(
        directory: URL?, preferences: Preferences, history: History, notices: Notices,
        store: (any ContactStoring)? = nil
    ) {
        self.directory = directory
        self.preferences = preferences
        self.history = history
        self.notices = notices
        self.store = store ?? Self.defaultStore()
        self.backups = directory.map { ContactBackupStore(directory: $0.appendingPathComponent("ContactBackups", isDirectory: true)) }
        self.keptApartFile = directory.map { JSONFile(url: $0.appendingPathComponent("contacts-kept-apart.json")) }
        keptApart = Set(keptApartFile?.load() ?? [])
        backupCount = countBackups()
    }

    private static func defaultStore() -> any ContactStoring {
        #if os(iOS)
        SystemContactStore()
        #else
        InMemoryContactStore(access: .notDetermined)
        #endif
    }

    // MARK: Access

    /// Reads access without asking; checks when it's allowed.
    public func start() async {
        deleteOrphanBackups()
        refreshAccess()
        guard access == .allowed else { return }
        rescan()
        await scanTask?.value
    }

    /// The pre-permission screen's Continue, and Rules' Allow contacts: the only places the
    /// app asks for contacts.
    public func requestAccess() async {
        _ = try? await store.requestAccess()
        await start()
    }

    /// Reads access again (say, back from Settings) and checks if it was never checked.
    func refresh() async {
        let before = access
        refreshAccess()
        guard access == .allowed, before != .allowed || !hasChecked, scanTask == nil else { return }
        await start()
    }

    private func refreshAccess() {
        let raw = store.authorization()
        access = Self.access(raw)
        isLimited = raw == .limited
        isRestricted = raw == .restricted
        if access != .allowed {
            scanTask?.cancel()
            scanTask = nil
            isScanning = false
            setFound(cards: [], mergeable: [], crossAccount: [])
        }
    }

    /// Limited counts as allowed (the user chose which cards); restricted as off.
    static func access(_ access: ContactAccess) -> Access {
        switch access {
        case .notDetermined: .notDetermined
        case .limited, .full: .allowed
        case .denied, .restricted: .denied
        }
    }

    // MARK: Checking

    public func rescan() {
        guard access == .allowed else { return }
        scanTask?.cancel()
        isScanning = true
        scanFailed = false
        scanTask = Task { await runScan() }
    }

    /// Checks again and returns when the check is done, for pull to refresh.
    func checkAgainAndWait() async {
        rescan()
        await scanTask?.value
    }

    private func runScan() async {
        await seedIfRequested()
        do {
            let fetched = try await store.fetchCards()
            try Task.checkCancellation()
            let found = await Self.find(fetched)
            try Task.checkCancellation()
            setFound(cards: fetched, mergeable: found.mergeable, crossAccount: found.crossAccount)
            hasChecked = true
        } catch is CancellationError {
            // A newer check took over; it finishes the job.
            return
        } catch ContactStoreError.notAuthorized {
            refreshAccess()
        } catch {
            scanFailed = true
            notices.announce(Copy.Contacts.scanFailed)
        }
        isScanning = false
        scanTask = nil
    }

    @concurrent
    nonisolated private static func find(_ cards: [ContactCard]) async -> (mergeable: [ContactDuplicateGroup], crossAccount: [ContactDuplicateGroup]) {
        DuplicateContactFinder.find(cards)
    }

    private func setFound(cards fetched: [ContactCard], mergeable: [ContactDuplicateGroup], crossAccount: [ContactDuplicateGroup]) {
        cards = Dictionary(fetched.map { ($0.id, $0) }) { first, _ in first }
        checkedCount = fetched.count
        self.mergeable = mergeable
        crossAccountGroups = sorted(crossAccount)
        problems = problems.filter { id, _ in mergeable.contains { $0.id == id } }
        publish()
    }

    /// The visible groups and the Home counts, from what the last check found.
    private func publish() {
        groups = sorted(mergeable.filter { !keptApart.contains($0.id) })
        duplicateGroupCount = groups.count
        extraCardCount = groups.reduce(0) { $0 + $1.cardIDs.count - 1 }
    }

    private func sorted(_ list: [ContactDuplicateGroup]) -> [ContactDuplicateGroup] {
        let order = Self.sectionOrder
        return list.sorted { a, b in
            let ra = order.firstIndex(of: Self.section(of: a)) ?? 0
            let rb = order.firstIndex(of: Self.section(of: b)) ?? 0
            if ra != rb { return ra < rb }
            let na = name(of: a), nb = name(of: b)
            if na != nb { return na.localizedStandardCompare(nb) == .orderedAscending }
            return a.id < b.id
        }
    }

    // MARK: Reading groups

    /// The list sections, strongest evidence first.
    static let sectionOrder: [MatchReason] = [.samePhone, .sameEmail, .sameName]

    /// The section a group is listed under: its strongest reason.
    static func section(of group: ContactDuplicateGroup) -> MatchReason {
        sectionOrder.first { group.reasons.contains($0) } ?? .sameName
    }

    func group(_ id: String) -> ContactDuplicateGroup? {
        groups.first { $0.id == id }
    }

    func card(_ id: String) -> ContactCard? {
        cards[id]
    }

    /// The group's cards as last read, keeper first.
    func cards(in group: ContactDuplicateGroup) -> [ContactCard] {
        group.cardIDs.compactMap { cards[$0] }
    }

    /// The name the group goes by: the suggested keeper's.
    func name(of group: ContactDuplicateGroup) -> String {
        Copy.Contacts.name(cards[group.keeperID] ?? cards(in: group).first)
    }

    /// The accounts the group's cards are in, each once, in card order.
    func accounts(of group: ContactDuplicateGroup) -> [String] {
        var seen: Set<String> = []
        return cards(in: group).map(\.containerName).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The merge as it would be, for the preview. Nil when the cards are gone.
    func preview(_ group: ContactDuplicateGroup, keeperID: String, choices: MergeChoices) -> MergePlan? {
        try? MergePlanner.plan(cards: cards(in: group), keeperID: keeperID, choices: choices)
    }

    // MARK: Merging

    /// Merges the group: plans it, backs the cards up as a vCard on this iPhone, records it in
    /// History, then saves. A refusal or failure changes nothing and is shown on the merge
    /// screen. Returns whether the cards were merged.
    @discardableResult
    func merge(_ groupID: String, keeperID: String, choices: MergeChoices) async -> Bool {
        guard mergingGroupID == nil, let group = mergeable.first(where: { $0.id == groupID }) else { return false }
        mergingGroupID = groupID
        problems[groupID] = nil
        defer { mergingGroupID = nil }

        let plan: MergePlan
        do {
            plan = try MergePlanner.plan(cards: cards(in: group), keeperID: keeperID, choices: choices)
        } catch {
            return failed(groupID, problem(for: error))
        }
        // Only the card that stays was read this time: the others changed or went away.
        guard !plan.removedIDs.isEmpty else { return failed(groupID, .changed) }

        let backupID = UUID()
        do {
            let data = try await store.backup(ids: plan.backupIDs)
            try saveBackup(data, id: backupID)
        } catch {
            return failed(groupID, problem(for: error, whileBackingUp: true))
        }

        let count = plan.backupIDs.count
        let title = Copy.Contacts.name(plan.merged)
        let record = ContactMergeRecord(plan: plan, backupID: backupID, groupID: groupID)
        let receipt = history.begin(
            .contactsMerged, requested: count, itemIDs: plan.removedIDs, title: title,
            payload: try? JSONEncoder().encode(record))
        do {
            try await store.apply(plan)
        } catch {
            history.finish(receipt, completed: 0)
            deleteBackup(backupID)
            return failed(groupID, problem(for: error))
        }
        history.finish(receipt, completed: count)

        mergeable.removeAll { $0.id == groupID }
        publish()
        notices.show(Copy.Contacts.merged(count, into: title), systemImage: Copy.Receipts.symbol(.contactsMerged), undo: Notice.Undo(title: Copy.General.undo) { [weak self] in
            guard let self, let current = self.history.receipt(receipt) else { return }
            await self.undo(current)
        })
        rescan()
        return true
    }

    private func failed(_ groupID: String, _ problem: MergeProblem) -> Bool {
        problems[groupID] = problem
        notices.announce(Copy.Contacts.problem(problem), priority: .high)
        return false
    }

    private func problem(for error: any Error, whileBackingUp: Bool = false) -> MergeProblem {
        switch error as? ContactStoreError {
        case .changedSincePreview, .cardNotFound: return .changed
        case .crossAccount: return .crossAccount
        case .myCardNotKeeper: return .myCard
        case .notAuthorized:
            refreshAccess()
            return .notAuthorized
        default: return whileBackingUp ? .backupFailed : .other
        }
    }

    /// Says which card stays after the user picks another one.
    func announceKeeper(number: Int) {
        notices.announce(Copy.Contacts.staysAnnouncement(number))
    }

    /// Clears a group's problem and reads the cards again, so the preview shows them as they are.
    func checkAgain(_ groupID: String) {
        problems[groupID] = nil
        rescan()
    }

    // MARK: Keeping apart

    /// The user says these cards are different people. They aren't suggested again.
    func keepApart(_ groupID: String) {
        guard let group = mergeable.first(where: { $0.id == groupID }) else { return }
        keptApart.insert(groupID)
        saveKeptApart()
        publish()
        notices.show(Copy.Contacts.keptApart(group.cardIDs.count), systemImage: "person.2", undo: Notice.Undo(title: Copy.General.undo) { [weak self] in
            self?.suggestAgain([groupID])
        })
    }

    /// Lists kept-apart cards again: all of them, from Rules, or one, from the notice's Undo.
    func suggestAgain(_ ids: Set<String>? = nil) {
        keptApart.subtract(ids ?? keptApart)
        saveKeptApart()
        publish()
        notices.announce(Copy.Contacts.suggestedAgain)
    }

    private func saveKeptApart() {
        try? keptApartFile?.save(keptApart.sorted())
    }

    // MARK: Undo

    /// Undo for a `.contactsMerged` receipt: puts the card that stayed back as it was and
    /// re-creates the others from the backup. When the card was edited since, it asks first.
    public func undo(_ receipt: Receipt) async {
        await undo(receipt, overwritingLaterEdits: false)
    }

    func undo(_ receipt: Receipt, overwritingLaterEdits: Bool) async {
        guard receipt.kind == .contactsMerged, receipt.status == .done || receipt.status == .partial,
              !undoing.contains(receipt.id) else { return }
        undoing.insert(receipt.id)
        defer { undoing.remove(receipt.id) }

        let name = receipt.title ?? Copy.Contacts.unnamed
        guard let data = receipt.payload, let record = try? JSONDecoder().decode(ContactMergeRecord.self, from: data) else {
            notices.show(Copy.Contacts.undoFailed, systemImage: "exclamationmark.triangle")
            return
        }
        guard let backup = loadBackup(record.backupID) else {
            note(receipt, .backupGone)
            notices.show(Copy.Contacts.backupGone, systemImage: "exclamationmark.triangle")
            return
        }
        do {
            let restored = try await store.undo(record.plan, backup: backup, overwritingLaterEdits: overwritingLaterEdits)
            history.update(receipt.id) { r in
                r.payload = try? JSONEncoder().encode(record.undone(restoredIDs: restored))
            }
            history.markUndone(receipt.id)
            notices.show(Copy.Contacts.undone(name, cards: receipt.requested), systemImage: "arrow.uturn.backward")
            rescan()
        } catch ContactStoreError.keeperChangedSinceMerge {
            note(receipt, .keeperEdited)
            confirmUndo(receipt, Copy.Contacts.keeperEdited(name), button: Copy.Contacts.undoAnyway)
        } catch ContactStoreError.keeperMissing {
            note(receipt, .keeperDeleted)
            confirmUndo(receipt, Copy.Contacts.keeperDeleted(name), button: Copy.Contacts.restoreAnyway)
        } catch ContactStoreError.keeperNotVisible {
            note(receipt, .keeperNotShared)
            notices.show(Copy.Contacts.keeperNotShared(name), systemImage: "exclamationmark.triangle")
        } catch ContactStoreError.notMerged {
            // The original cards are there, so a second undo would only make copies of them.
            note(receipt, .alreadyBack)
            history.markUndone(receipt.id)
            notices.show(Copy.Contacts.alreadyBack, systemImage: "info.circle")
        } catch ContactStoreError.notAuthorized {
            refreshAccess()
            notices.show(Copy.Contacts.undoNeedsAccess, systemImage: "lock")
        } catch ContactStoreError.backupMissingCards, ContactStoreError.unreadableBackup {
            note(receipt, .backupGone)
            notices.show(Copy.Contacts.backupGone, systemImage: "exclamationmark.triangle")
        } catch {
            notices.show(Copy.Contacts.undoFailed, systemImage: "exclamationmark.triangle")
        }
    }

    /// Asks before an undo that would replace later edits, with a confirmation dialog the
    /// root view shows. Cancel changes nothing, and Undo in History asks again.
    private func confirmUndo(_ receipt: Receipt, _ text: String, button: String) {
        pendingUndoConflict = UndoConflict(receiptID: receipt.id, text: text, button: button)
        notices.announce(text, priority: .high)
    }

    /// The dialog's confirming button: undoes the merge, replacing the later changes.
    func confirmUndo(_ conflict: UndoConflict) async {
        if pendingUndoConflict == conflict { pendingUndoConflict = nil }
        guard let current = history.receipt(conflict.receiptID) else { return }
        await undo(current, overwritingLaterEdits: true)
    }

    /// The dialog's Cancel: the merge stays as it is.
    func cancelPendingUndo() {
        guard pendingUndoConflict != nil else { return }
        pendingUndoConflict = nil
        notices.announce(Copy.Contacts.undoCancelled)
    }

    /// Keeps why an undo stopped on the receipt, so History can tell.
    private func note(_ receipt: Receipt, _ problem: ContactMergeRecord.UndoProblem) {
        history.update(receipt.id) { r in
            guard let data = r.payload, var record = try? JSONDecoder().decode(ContactMergeRecord.self, from: data) else { return }
            record.undoProblem = problem
            r.payload = try? JSONEncoder().encode(record)
        }
    }

    /// How many of an interrupted merge's cards are still there as they were. A merge is one
    /// save, so it is all of them (the removed cards still exist: nothing happened) or none.
    /// When the cards can't be read it says none, so the receipt and its Undo stay.
    func stillThere(_ receipt: Receipt) async -> Int {
        guard !receipt.itemIDs.isEmpty, store.authorization().canRead,
              let current = try? await store.fetchCards() else { return 0 }
        let ids = Set(current.map(\.id))
        return receipt.itemIDs.contains(where: ids.contains) ? receipt.requested : 0
    }

    // MARK: Backups

    private func saveBackup(_ data: Data, id: UUID) throws {
        if let backups {
            try backups.save(data, id: id)
        } else {
            memoryBackups[id] = data
        }
        backupCount = countBackups()
    }

    private func loadBackup(_ id: UUID) -> Data? {
        if let backups { return try? backups.load(id: id) }
        return memoryBackups[id]
    }

    private func deleteBackup(_ id: UUID) {
        try? backups?.delete(id: id)
        memoryBackups[id] = nil
        backupCount = countBackups()
    }

    /// Deletes every saved backup. Merges made before can't be undone after this; the cards
    /// themselves aren't touched.
    func deleteBackups() {
        for url in backupFiles() { try? FileManager.default.removeItem(at: url) }
        memoryBackups = [:]
        backupCount = countBackups()
        notices.show(Copy.Contacts.backupsDeleted, systemImage: "trash")
    }

    private func backupFiles() -> [URL] {
        guard let backups else { return [] }
        let items = (try? FileManager.default.contentsOfDirectory(at: backups.directory, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "vcf" }
    }

    /// Deletes backups no receipt points to: left by a merge cut off before it was recorded
    /// or saved, or by receipts cleared from History. Without a receipt they can't be used
    /// to undo anything.
    private func deleteOrphanBackups() {
        let files = backupFiles()
        guard !files.isEmpty else { return }
        let decoder = JSONDecoder()
        let used = Set(history.receipts.compactMap { receipt -> String? in
            guard receipt.kind == .contactsMerged, let data = receipt.payload,
                  let record = try? decoder.decode(ContactMergeRecord.self, from: data) else { return nil }
            return record.backupID.uuidString
        })
        var deleted = false
        for url in files where !used.contains(url.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
            deleted = true
        }
        if deleted { backupCount = countBackups() }
    }

    private func countBackups() -> Int {
        backups == nil ? memoryBackups.count : backupFiles().count
    }

    // MARK: Sample cards

    /// Simulator only, for UI tests (`-TKSeedContacts YES`): makes sure there are at least two
    /// "Jordan Rivera" cards with the same phone number, then checks again. Running it again
    /// adds nothing. Without access it does nothing until access is given in the app.
    func seedSample() {
        seedRequested = true
        refreshAccess()
        rescan()
    }

    private func seedIfRequested() async {
        if let seedTask {
            await seedTask.value
            return
        }
        guard seedRequested, store.authorization().canRead else { return }
        seedRequested = false
        let store = self.store
        let task = Task { await Self.topUpSample(in: store) }
        seedTask = task
        await task.value
        seedTask = nil
    }

    nonisolated static let samplePhone = "+1 415 555 0134"

    nonisolated private static func topUpSample(in store: any ContactStoring) async {
        guard let current = try? await store.fetchCards() else { return }
        let have = current.filter(isSample).count
        guard have < 2 else { return }
        for _ in have..<2 {
            _ = try? await store.add(ContactCard(
                id: "", givenName: "Jordan", familyName: "Rivera",
                phones: [LabeledValue(label: "_$!<Mobile>!$_", value: samplePhone)]))
        }
    }

    nonisolated static func isSample(_ card: ContactCard) -> Bool {
        card.givenName == "Jordan" && card.familyName == "Rivera"
            && card.phones.contains { $0.value.filter(\.isNumber).hasSuffix("4155550134") }
    }
}

/// What a merge's receipt keeps, so it can be undone after a relaunch: the plan, where its
/// backup is, and how an undo went.
struct ContactMergeRecord: Codable, Sendable, Hashable {
    enum UndoProblem: String, Codable, Sendable {
        case keeperEdited, keeperDeleted, keeperNotShared, alreadyBack, backupGone
    }

    var plan: MergePlan
    var backupID: UUID
    var groupID: String
    /// The cards an undo re-created.
    var restoredIDs: [String]?
    /// Why the last undo stopped, when it did.
    var undoProblem: UndoProblem?

    func undone(restoredIDs: [String]) -> ContactMergeRecord {
        var copy = self
        copy.restoredIDs = restoredIDs
        copy.undoProblem = nil
        return copy
    }
}

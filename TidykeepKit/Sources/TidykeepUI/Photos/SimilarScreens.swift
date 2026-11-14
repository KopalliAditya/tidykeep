import SwiftUI
import TidykeepCore

// MARK: - List

/// Similar Shots: one row per group, in month sections, newest first. Each row opens the group;
/// the bar removes every suggested photo across groups, through the review sheet.
struct SimilarShotsView: View {
    @Environment(PhotosModel.self) private var photos
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var sort = SimilarListLayout.Sort.newest
    @ViewState private var review: ReviewRequest?
    @ViewState private var showsCoverage = false
    @ViewState private var finishedBatches = 0
    /// The rows as they were when a group was opened, to find the next one when it's gone.
    @ViewState private var leftRows: [SimilarListLayout.Row] = []
    @AccessibilityFocusState private var focus: SimilarListFocus?
    @Namespace private var rotorSpace
    /// The spec's pause before focus moves after a pop or a removal.
    private static let focusDelay: Duration = .milliseconds(600)

    var body: some View {
        content
            .background(Palette.groupedBackground)
            .navigationTitle(Copy.Similar.title)
            .toolbar { menu }
            .actionBar(primary: removeAction)
            .reviewSheet($review)
            .sheet(isPresented: $showsCoverage) { CoverageSheet(coverage: photos.coverage) }
            .feedback(.success, trigger: finishedBatches)
            .onDisappear { leftRows = sections.flatMap(\.rows) }
            .onAppear(perform: focusAfterReturn)
    }

    @ViewBuilder
    private var content: some View {
        switch photos.access {
        case .notDetermined:
            accessState(AccessOffView(
                title: Copy.Home.photos,
                detail: Copy.Access.photosOffDetail,
                symbol: "photo.on.rectangle",
                ask: (Copy.Access.askPhotos, { Task { await photos.requestAccess() } })
            ))
        case .denied:
            accessState(AccessOffView(title: Copy.Access.photosOff, detail: Copy.Access.photosOffDetail))
        case .limited, .full:
            if photos.similar.isEmpty { emptyState } else { list }
        }
    }

    private func accessState(_ view: AccessOffView) -> some View {
        ScrollView {
            view.padding(Space.l)
        }
    }

    // MARK: Header

    /// The summary, what was checked and, while checking, how far along it is.
    private var header: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if !photos.similar.isEmpty {
                Text(Copy.Similar.summary(groups: photos.similar.count, extras: photos.similarRemovalCount))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($focus, equals: .summary)
                    .accessibilityIdentifier("similar.summary")
            }
            if photos.scanState.progress != nil {
                Button { showsCoverage = true } label: {
                    HStack(spacing: Space.s) {
                        Image(systemName: "checkmark.seal")
                            .foregroundStyle(Palette.accent)
                        Text(coverageLine)
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                        Image(systemName: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                    .font(.subheadline)
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(coverageLine)
                .accessibilityHint(Copy.Coverage.title)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("similar.coverage")
            }
            if photos.access == .limited {
                Button { Task { await photos.chooseMorePhotos() } } label: {
                    Text(Copy.Access.chooseMore)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Palette.accent)
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            ScanStatusView(state: photos.scanState)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var coverageLine: String {
        Copy.Coverage.line(checked: photos.coverage.checked, skipped: photos.coverage.totalSkipped)
    }

    // MARK: Empty

    /// "All tidy" only once a check has looked at everything. A check that is still going,
    /// was stopped or couldn't run says so, with a way to check again.
    private var emptyState: some View {
        ScrollView {
            VStack(spacing: Space.xl) {
                header
                emptyMessage
                    .frame(maxWidth: .infinity)
                    .padding(.top, Space.xxl)
            }
            .padding(.horizontal, Space.l)
            .padding(.bottom, Space.xl)
        }
    }

    @ViewBuilder
    private var emptyMessage: some View {
        switch photos.scanState {
        case .finished:
            AllTidyView(detail: Copy.Similar.emptyDetail)
                .accessibilityFocused($focus, equals: .empty)
        case .scanning, .paused:
            emptyNote(Copy.Similar.stillChecking)
        case .stopped(let p) where p.checked > 0:
            emptyNote(Copy.Similar.noneSoFar, checks: true)
        case .stopped, .failed, .idle:
            emptyNote(Copy.Similar.notChecked, checks: true)
        }
    }

    private func emptyNote(_ text: String, checks: Bool = false) -> some View {
        VStack(spacing: Space.l) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityFocused($focus, equals: .empty)
            if checks {
                Button(Copy.General.checkAgain) { photos.rescan() }
                    .buttonStyle(.glass)
                    .foregroundStyle(Palette.accent)
                    .controlSize(.large)
            }
        }
    }

    // MARK: Rows

    private var sections: [SimilarListLayout.Section] {
        SimilarListLayout.sections(photos.similar, sort: sort) { photos.removals(in: $0).count }
    }

    private var list: some View {
        let sections = sections
        return List {
            Section {
                header
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: Space.s, leading: Space.l, bottom: Space.s, trailing: Space.l))
                    .listRowSeparator(.hidden)
            }
            ForEach(sections) { section in
                Section {
                    ForEach(section.rows) { row in
                        rowLink(row)
                    }
                } header: {
                    if let title = section.title {
                        Text(title)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
            }
        }
        .groupedList()
        .scrollContentBackground(.hidden)
        .disabled(photos.isWorking)
        .animation(Motion.standard(reduceMotion), value: photos.similar.map(\.id))
        .accessibilityRotor(Copy.Similar.closeCallsRotor) {
            ForEach(sections.flatMap(\.rows).filter(\.group.ranking.isCloseCall)) { row in
                AccessibilityRotorEntry(Text(Copy.Similar.groupTitle(row.group)), id: row.group.id, in: rotorSpace)
            }
        }
    }

    private func rowLink(_ row: SimilarListLayout.Row) -> some View {
        let group = row.group
        let removing = photos.removals(in: group).count
        let kept = group.members.count - removing
        let keptSafe = group.members.count(where: { group.isProtected($0.id) })
        return NavigationLink(value: Route.similarGroup(group.id)) {
            SimilarGroupRow(group: group, kept: kept, removing: removing, keptSafe: keptSafe)
        }
        .listRowBackground(Palette.card)
        .accessibilityLabel(Copy.Similar.rowLabel(group, kept: kept, removing: removing, keptSafe: keptSafe))
        .accessibilityIdentifier("similar.row.\(row.index)")
        .accessibilityFocused($focus, equals: .row(group.id))
        .accessibilityRotorEntry(id: group.id, in: rotorSpace)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { keepAll(group) } label: {
                Label(Copy.General.keepAll, systemImage: "checkmark.circle")
            }
            .tint(Palette.accent)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if removing > 0 {
                Button { reviewRemoval([group]) } label: {
                    Label(Copy.Similar.removeButton(removing), systemImage: "trash")
                }
                .tint(Palette.remove)
            }
        }
        .contextMenu {
            Button { keepAll(group) } label: {
                Label(Copy.General.keepAll, systemImage: "checkmark.circle")
            }
            if removing > 0 {
                Button { reviewRemoval([group]) } label: {
                    Label(Copy.Similar.removeButton(removing), systemImage: "trash")
                }
            }
        }
        .accessibilityActions {
            if removing > 0 {
                Button(Copy.Similar.removeButton(removing)) { reviewRemoval([group]) }
            }
            Button(Copy.General.keepAll) { keepAll(group) }
        }
    }

    // MARK: Actions

    private var removeAction: BarAction? {
        // While checking, rows stream in and the total keeps changing, so the bar that removes
        // across every group waits for the check (spec). One group, from its row or its
        // screen, can still be removed: the review lists exactly the photos that go.
        guard !photos.similar.isEmpty, !photos.scanState.isActive else { return nil }
        let n = photos.similarRemovalCount
        return BarAction(
            title: Copy.Similar.removeButton(n),
            isEnabled: n > 0,
            isBusy: photos.isWorking,
            hint: Copy.Similar.removeHint
        ) {
            reviewRemoval(photos.similar)
        }
    }

    private func reviewRemoval(_ groups: [PhotoGroup]) {
        review = photos.similarReview(groups) { removed in
            guard removed else { return }
            finishedBatches += 1
            // The rows animate out first; with none left, the empty state takes the focus.
            moveFocus(to: photos.similar.isEmpty ? .empty : .summary)
        }
    }

    /// Back from a group that is gone (removed or kept there): focus goes to the row that took
    /// its place, or the one before it at the end of the list.
    private func focusAfterReturn() {
        let rows = leftRows
        leftRows = []
        func current(_ row: SimilarListLayout.Row) -> PhotoGroup? {
            photos.similarGroup(row.group.id, following: Set(row.group.members.map(\.id)))
        }
        guard let gone = rows.firstIndex(where: { current($0) == nil }) else { return }
        let next = rows[gone...].lazy.compactMap(current).first ?? rows[..<gone].reversed().lazy.compactMap(current).first
        moveFocus(to: next.map { .row($0.id) } ?? .empty)
    }

    /// After the screen settles, so VoiceOver lands on what is there rather than what left.
    private func moveFocus(to target: SimilarListFocus) {
        Task {
            try? await Task.sleep(for: Self.focusDelay)
            focus = target
        }
    }

    private func keepAll(_ group: PhotoGroup) {
        withAnimation(Motion.standard(reduceMotion)) { photos.keepAll(group) }
    }

    @ToolbarContentBuilder
    private var menu: some ToolbarContent {
        ToolbarItem(placement: .topTrailing) {
            Menu {
                Picker(Copy.Similar.sort, selection: $sort) {
                    ForEach(SimilarListLayout.Sort.allCases) { Text($0.title).tag($0) }
                }
                Divider()
                Button { photos.restoreKeptGroups() } label: {
                    Label(Copy.Similar.showKept, systemImage: "arrow.uturn.backward")
                }
            } label: {
                Label(Copy.Similar.more, systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
            }
            .disabled(photos.isWorking)
        }
    }
}

/// Where VoiceOver focus goes on the list after a change.
enum SimilarListFocus: Hashable {
    case summary
    case empty
    case row(String)
}

/// One group in the list: a small stack of its photos with the best pick on top, what it is,
/// when, and what would happen to it.
private struct SimilarGroupRow: View {
    let group: PhotoGroup
    let kept: Int
    let removing: Int
    let keptSafe: Int
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.m))
            : AnyLayout(HStackLayout(alignment: .center, spacing: Space.m))
        layout {
            SimilarStackThumbnail(group: group)
            VStack(alignment: .leading, spacing: Space.hair) {
                Text(Copy.Similar.groupTitle(group))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(Copy.Similar.rowDate(group.startDate))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(Copy.Similar.keepRemove(kept: kept, removing: removing))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if group.ranking.isCloseCall || keptSafe > 0 {
                    notes.padding(.top, Space.hair)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.s)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var notes: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.xs))
            : AnyLayout(HStackLayout(spacing: Space.m))
        layout {
            if group.ranking.isCloseCall {
                Label {
                    Text(Copy.Similar.closeCallShort)
                } icon: {
                    Image(systemName: "eye").foregroundStyle(Palette.closeCall)
                }
            }
            if keptSafe > 0 {
                Label {
                    Text(Copy.Similar.keptSafeCount(keptSafe))
                } icon: {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                }
            }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.secondary)
        .labelStyle(SimilarCompactLabelStyle())
    }
}

/// A symbol and text a little closer together than the default label.
struct SimilarCompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            configuration.icon.accessibilityHidden(true)
            configuration.title
        }
    }
}

/// The group's photos fanned like prints, best pick in front with its rosette.
private struct SimilarStackThumbnail: View {
    let group: PhotoGroup
    private let size: CGFloat = 64

    var body: some View {
        ThumbnailStack(ids: group.members.map(\.id), symbol: "square.stack.3d.up", size: size)
            .overlay(alignment: .bottomLeading) {
                SimilarBestPickBadge()
                    .offset(x: -Space.xs, y: Space.xs)
            }
            .padding(.bottom, Space.xs)
            .accessibilityHidden(true)
    }
}

/// The rosette that marks the best pick, on a small accent disc so it reads on any photo.
struct SimilarBestPickBadge: View {
    var body: some View {
        Image(systemName: "rosette")
            .font(.caption2.weight(.bold))
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .foregroundStyle(Palette.onAccent)
            .frame(width: 22, height: 22)
            .background(Palette.accent, in: Circle())
            .overlay { Circle().strokeBorder(Palette.card, lineWidth: 1.5) }
            .accessibilityHidden(true)
    }
}

// MARK: - Layout

/// How the list is cut into sections and numbered. The numbers (`similar.row.<i>`) run from
/// 0 down the screen, across sections, so UI tests can find the first row whatever the dates.
enum SimilarListLayout {
    enum Sort: String, CaseIterable, Identifiable, Hashable {
        case newest, oldest, mostExtra

        var id: String { rawValue }

        var title: String {
            switch self {
            case .newest: Copy.Similar.sortNewest
            case .oldest: Copy.Similar.sortOldest
            case .mostExtra: Copy.Similar.sortMostExtra
            }
        }
    }

    struct Row: Identifiable {
        let index: Int
        let group: PhotoGroup
        var id: String { group.id }
    }

    struct Section: Identifiable {
        let id: String
        /// "October 2026"; nil when the list isn't sorted by date.
        let title: String?
        let rows: [Row]
    }

    static func sections(
        _ groups: [PhotoGroup],
        sort: Sort,
        calendar: Calendar = .current,
        removals: (PhotoGroup) -> Int
    ) -> [Section] {
        let sorted: [PhotoGroup]
        switch sort {
        case .newest:
            sorted = groups.sorted { $0.startDate != $1.startDate ? $0.startDate > $1.startDate : $0.id < $1.id }
        case .oldest:
            sorted = groups.sorted { $0.startDate != $1.startDate ? $0.startDate < $1.startDate : $0.id < $1.id }
        case .mostExtra:
            let counts = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, removals($0)) })
            sorted = groups.sorted {
                let a = counts[$0.id] ?? 0, b = counts[$1.id] ?? 0
                return a != b ? a > b : $0.startDate > $1.startDate
            }
        }
        let rows = sorted.enumerated().map { Row(index: $0.offset, group: $0.element) }
        guard sort != .mostExtra else { return [Section(id: "all", title: nil, rows: rows)] }

        var sections: [Section] = []
        var current: (key: DateComponents, date: Date, rows: [Row])?
        for row in rows {
            let key = calendar.dateComponents([.year, .month], from: row.group.startDate)
            if current?.key == key {
                current?.rows.append(row)
            } else {
                if let done = current { sections.append(section(done.date, done.rows)) }
                current = (key, row.group.startDate, [row])
            }
        }
        if let done = current { sections.append(section(done.date, done.rows)) }
        return sections
    }

    private static func section(_ date: Date, _ rows: [Row]) -> Section {
        Section(id: Copy.month(date), title: Copy.month(date), rows: rows)
    }
}

// MARK: - Review

extension PhotosModel {
    /// The review sheet for removing what's marked in these groups: what goes, what stays,
    /// why, what the rules keep and how to get it back. Nil when nothing is marked.
    ///
    /// Confirming removes them; `done` then hears whether anything was removed (nothing is
    /// when the iOS alert is cancelled), so the screen can follow up with focus and a haptic.
    func similarReview(
        _ groups: [PhotoGroup],
        now: Date = Date(),
        done: (@MainActor (_ removed: Bool) -> Void)? = nil
    ) -> ReviewRequest? {
        let removing = groups.flatMap { removals(in: $0) }
        guard !removing.isEmpty else { return nil }
        let staying = groups.flatMap { group in group.members.filter { isKept($0.id, in: group) } }

        let why = groups.count == 1 ? Copy.Similar.whyThisOne(groups[0]) : Copy.Similar.fromGroups(groups.count)
        let reason = Reason(
            why: why,
            keptSafe: similarKeptSafe(groups),
            undo: Copy.Similar.undoLine(until: Receipt.recentlyDeletedDeadline(from: now))
        )
        return ReviewRequest(
            title: Copy.Review.removePhotos(removing.count),
            removing: removing.map { .photo($0.id) },
            staying: staying.map { .photo($0.id) },
            reason: reason,
            // PhotoKit can't say which photos are in a Shared Library, so the line is always shown.
            sharedLibraryLine: Copy.Review.sharedLibrary,
            confirmTitle: Copy.Similar.removeButton(removing.count),
            confirm: { [weak self] in
                guard let self else { return }
                let before = self.ledger.photosRemoved
                await self.removeSuggested(in: groups)
                done?(self.ledger.photosRemoved > before)
            }
        )
    }

    /// The Reason card on the group screen, before anything is removed. The line under the
    /// pager already gives the reasons; the card also names the photo.
    func similarReason(_ group: PhotoGroup, now: Date = Date()) -> Reason {
        Reason(
            why: Copy.Similar.whyThisOneSpoken(group),
            keptSafe: similarKeptSafe([group]),
            undo: Copy.Similar.undoLine(until: Receipt.recentlyDeletedDeadline(from: now))
        )
    }

    /// What the rules keep in these groups, by rule, each photo counted once.
    private func similarKeptSafe(_ groups: [PhotoGroup]) -> String? {
        var favorites = 0, edited = 0, albums = 0, documents = 0
        for group in groups {
            for meta in group.members where group.isProtected(meta.id) {
                if meta.isFavorite { favorites += 1 }
                else if meta.hasAdjustments { edited += 1 }
                else if group.ruleIDs.contains(meta.id) { albums += 1 }
                else { documents += 1 }
            }
        }
        return Copy.Similar.keptSafe(favorites: favorites, edited: edited, albums: albums, documents: documents)
    }

    /// A similar group by ID, or the group its photos now belong to: a group's ID changes when
    /// a photo joins it during a check, and groups never share photos.
    func similarGroup(_ id: String, following memberIDs: Set<String>) -> PhotoGroup? {
        similar.first { $0.id == id } ?? (memberIDs.isEmpty ? nil : similar.first { $0.members.contains { memberIDs.contains($0.id) } })
    }
}

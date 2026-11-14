import SwiftUI
import TidykeepCore
import TidykeepFiles

// MARK: - Duplicate files

/// Sets of identical files in the chosen folders, the most space first. Each row opens the set.
struct DuplicateFilesView: View {
    @Environment(FilesModel.self) private var files
    @ViewState private var picking = false
    @ViewState private var review: ReviewRequest?

    var body: some View {
        content
            .navigationTitle(Copy.Files.duplicatesTitle)
            .inlineNavigationTitle()
            .folderPicker(isPresented: $picking)
            .reviewSheet($review)
            .actionBar(primary: moveAll)
    }

    @ViewBuilder
    private var content: some View {
        if files.folderCount == 0 {
            ScrollView {
                NoFoldersView { picking = true }
                    .padding(Space.l)
            }
            .background(Palette.groupedBackground)
        } else {
            List {
                Section {
                    FilesStatusHeader(summary: summary)
                }
                if let error = files.lastError {
                    Section { InlineError(text: error) }
                }
                if !files.unavailableFolders.isEmpty {
                    Section { UnavailableFoldersNote(folders: files.unavailableFolders) { picking = true } }
                }
                if files.duplicateGroups.isEmpty {
                    if files.hasChecked, !files.isScanning {
                        Section {
                            AllTidyView(detail: Copy.Files.noDuplicates(folders: files.folderCount))
                                .listRowBackground(Color.clear)
                        } footer: {
                            ruleFooter
                        }
                    }
                } else {
                    Section {
                        ForEach(Array(files.duplicateGroups.enumerated()), id: \.element.id) { index, group in
                            NavigationLink(value: Route.duplicateFileSet(group.id)) {
                                DuplicateSetRow(group: group)
                            }
                            .accessibilityIdentifier("dupfiles.row.\(index)")
                        }
                    } footer: {
                        ruleFooter
                    }
                }
            }
            .groupedList()
            .minimizingTabBar()
        }
    }

    @ViewBuilder
    private var ruleFooter: some View {
        if let footer = Copy.Files.recentRule(days: files.recentDays, kept: files.keptByRule) {
            Text(footer).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summary: String {
        Copy.Files.duplicatesSummary(sets: files.duplicateSetCount, extras: files.duplicateExtraCount, bytes: files.duplicateExtraBytes)
    }

    /// Moves every set's extra copies, through the review sheet, since the user hasn't looked
    /// at each one.
    private var moveAll: BarAction? {
        let groups = files.duplicateGroups
        guard files.folderCount > 0, !groups.isEmpty else { return nil }
        let count = files.duplicateExtraCount
        return BarAction(title: Copy.Files.moveButton(count), isBusy: files.isBusy) {
            review = ReviewRequest(
                title: Copy.Files.moveAllTitle(count),
                removing: groups.flatMap(\.movable).map { .file(id: $0.id, name: $0.name, bytes: $0.unsharedBytes) },
                staying: groups.map { .file(id: $0.keeper.id, name: $0.keeper.name, bytes: $0.keeper.bytes) },
                reason: Reason(why: Copy.Files.whyIdenticalSets(groups.count), keptSafe: Copy.Files.keptSafeKeepers, undo: Copy.Files.undoHolding),
                confirmTitle: Copy.Files.moveButton(count),
                confirm: { await files.moveToHolding(groups: groups) }
            )
        }
    }
}

/// One set in the list: the kept file's name, how many copies, and what the extras take.
private struct DuplicateSetRow: View {
    let group: FilesModel.DuplicateGroup
    @Environment(FilesModel.self) private var files

    var body: some View {
        AdaptiveStack {
            HStack(spacing: Space.m) {
                FileTile(name: group.keeper.name)
                VStack(alignment: .leading, spacing: Space.hair) {
                    Text(group.keeper.name)
                        .font(.body.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(Copy.Files.setTitle(group.items.count)) · \(files.location(of: group.keeper))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Text(Copy.bytes(group.extraBytes))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, Space.xs)
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Files.setRowLabel(name: group.keeper.name, copies: group.items.count, extraBytes: group.extraBytes))
    }
}

// MARK: - One set

/// One set of identical files: the copy that stays, the copies that move, why, and how to undo.
/// The move happens straight away; the notice offers Undo, and Holding and History keep the
/// way back.
struct DuplicateFileSetView: View {
    let setID: String
    @Environment(FilesModel.self) private var files
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var moved = false

    var body: some View {
        Group {
            if let group = files.group(setID) {
                detail(group)
            } else {
                ScrollView {
                    AllTidyView(detail: moved ? Copy.Files.setMoved : Copy.Files.setGone)
                        .accessibilityIdentifier("dupfiles.done")
                }
                .background(Palette.groupedBackground)
            }
        }
        .navigationTitle(Copy.Files.duplicatesTitle)
        .inlineNavigationTitle()
        .actionBar(primary: moveAction)
        .feedback(.success, trigger: moved)
    }

    private var moveAction: BarAction? {
        guard let group = files.group(setID) else { return nil }
        return BarAction(title: Copy.Files.moveButton(group.movable.count), isBusy: files.isBusy) {
            moved = true
            Task {
                if await !files.moveToHolding(group) { moved = false }
            }
        }
    }

    private func detail(_ group: FilesModel.DuplicateGroup) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(Copy.Files.setTitle(group.items.count))
                        .font(.title2.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    Text(Copy.Files.setLine(name: group.keeper.name, bytes: group.keeper.bytes))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Space.xs)

                if let error = files.lastError {
                    InlineError(text: error)
                }

                CardSection(title: Copy.Files.keeping) {
                    card { copyRow(group.keeper, badge: Copy.Files.keepingThis) }
                }

                CardSection(title: Copy.Files.movingSection) {
                    card {
                        ForEach(group.movable) { item in
                            copyRow(item, in: group)
                            if item.id != group.movable.last?.id { Divider() }
                        }
                    }
                }

                if !group.recent.isEmpty {
                    CardSection(title: Copy.Files.stayingSection, footer: Copy.Files.changedRecently) {
                        card {
                            ForEach(group.recent) { item in
                                copyRow(item, in: group)
                                if item.id != group.recent.last?.id { Divider() }
                            }
                        }
                    }
                }

                ReasonCard(reason: Reason(
                    why: Copy.Files.whyIdentical,
                    keptSafe: Copy.Files.keptSafeKeeper(group.keeper.name, recent: group.recent.count),
                    undo: Copy.Files.undoHolding
                ))
            }
            .padding(Space.l)
            .animation(Motion.standard(reduceMotion), value: group.keeper.id)
        }
        .background(Palette.groupedBackground)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.m) { content() }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    private func copyRow(_ item: FileItem, badge: String? = nil) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            FileTile(name: item.name)
            FileDetails(
                name: item.name,
                location: files.location(of: item),
                bytes: item.bytes,
                date: Copy.Files.changed(item.modified),
                badge: badge
            )
        }
        .accessibilityElement(children: .combine)
    }

    private func copyRow(_ item: FileItem, in group: FilesModel.DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            copyRow(item)
            Button {
                files.keep(item.id, inSet: group.id)
            } label: {
                Text(Copy.Files.keepThisInstead)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.accent)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 36 + Space.m)
            .accessibilityHint(Copy.Files.keepThisInsteadHint(group.keeper.name))
        }
    }
}

// MARK: - Large files

/// Files over the size in Rules, biggest first. Select some and move them to Holding, or swipe
/// one.
struct LargeFilesView: View {
    @Environment(FilesModel.self) private var files
    @ViewState private var selection: Set<String> = []
    @ViewState private var picking = false

    var body: some View {
        content
            .navigationTitle(Copy.Files.largeTitle)
            .inlineNavigationTitle()
            .folderPicker(isPresented: $picking)
            .actionBar(secondary: selectAll, primary: moveSelected)
            .feedback(.selection, trigger: selection)
            .onChange(of: files.largeFiles.map(\.id)) { _, ids in
                selection.formIntersection(ids)
            }
    }

    @ViewBuilder
    private var content: some View {
        if files.folderCount == 0 {
            ScrollView {
                NoFoldersView { picking = true }
                    .padding(Space.l)
            }
            .background(Palette.groupedBackground)
        } else {
            List {
                Section {
                    FilesStatusHeader(summary: Copy.Files.largeSummary(files.largeFileCount, bytes: files.largeFileBytes, minimum: files.largeFileMinimum))
                }
                if let error = files.lastError {
                    Section { InlineError(text: error) }
                }
                if !files.unavailableFolders.isEmpty {
                    Section { UnavailableFoldersNote(folders: files.unavailableFolders) { picking = true } }
                }
                if files.largeFiles.isEmpty {
                    if files.hasChecked, !files.isScanning {
                        Section {
                            AllTidyView(detail: Copy.Files.noLargeFiles(minimum: files.largeFileMinimum))
                                .listRowBackground(Color.clear)
                        } footer: {
                            footer
                        }
                    }
                } else {
                    Section {
                        ForEach(Array(files.largeFiles.enumerated()), id: \.element.id) { index, item in
                            row(item)
                                .accessibilityIdentifier("largefiles.row.\(index)")
                        }
                    } footer: {
                        footer
                    }
                }
            }
            .groupedList()
            .minimizingTabBar()
        }
    }

    private var footer: some View {
        let rule = Copy.Files.recentRule(days: files.recentDays, kept: files.keptByRule)
        return Text([Copy.Files.largeFooter, rule].compactMap { $0 }.joined(separator: " "))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ item: FileItem) -> some View {
        let selected = selection.contains(item.id)
        let location = files.location(of: item)
        return Button {
            toggle(item.id)
        } label: {
            AdaptiveStack {
                HStack(spacing: Space.m) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? Palette.accent : Color.secondary)
                        .accessibilityHidden(true)
                    FileTile(name: item.name)
                    VStack(alignment: .leading, spacing: Space.hair) {
                        Text(item.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(location) · \(Copy.Files.changed(item.modified))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: Space.hair) {
                    Text(Copy.bytes(item.bytes))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(Copy.Files.exactBytes(item.bytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
            }
            .padding(.vertical, Space.xs)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Files.largeRowLabel(item, folder: location))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(Copy.Files.selectHint)
        .swipeActions(edge: .trailing) {
            Button(Copy.Files.moveToHolding) { move([item]) }
                .tint(Palette.accent)
        }
        .accessibilityAction(named: Copy.Files.moveToHolding) { move([item]) }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func move(_ items: [FileItem]) {
        Task {
            if await files.moveToHolding(items) {
                selection.subtract(items.map(\.id))
            }
        }
    }

    private var selectAll: BarAction? {
        guard !files.largeFiles.isEmpty else { return nil }
        let all = selection.count == files.largeFiles.count
        return BarAction(title: all ? Copy.Files.deselectAll : Copy.Files.selectAll) {
            selection = all ? [] : Set(files.largeFiles.map(\.id))
        }
    }

    private var moveSelected: BarAction? {
        guard !files.largeFiles.isEmpty else { return nil }
        let chosen = files.largeFiles.filter { selection.contains($0.id) }
        return BarAction(title: Copy.Files.moveButton(chosen.count), isEnabled: !chosen.isEmpty, isBusy: files.isBusy) {
            move(chosen)
        }
    }
}

// MARK: - Holding

/// Files moved to "Held by Tidykeep", newest first. Put them back, or empty Holding to delete
/// them for good, which always goes through the review sheet.
struct HoldingView: View {
    @Environment(FilesModel.self) private var files
    @ViewState private var review: ReviewRequest?

    var body: some View {
        content
            .navigationTitle(Copy.Files.holdingTitle)
            .inlineNavigationTitle()
            .reviewSheet($review)
            .actionBar(secondary: putAllBack, primary: emptyHolding)
    }

    @ViewBuilder
    private var content: some View {
        if files.held.isEmpty {
            ScrollView {
                VStack(spacing: Space.l) {
                    if let error = files.lastError { InlineError(text: error) }
                    HoldingEmptyView()
                }
                .padding(Space.l)
            }
            .background(Palette.groupedBackground)
        } else {
            List {
                Section {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(Copy.Files.holdingSummary(files.holdingCount, bytes: files.holdingBytes))
                            .font(.headline)
                            .monospacedDigit()
                        Text(Copy.Files.holdingExplainer)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, Space.xs)
                    .accessibilityElement(children: .combine)
                }
                if let error = files.lastError {
                    Section { InlineError(text: error) }
                }
                Section {
                    ForEach(Array(files.held.enumerated()), id: \.element.id) { index, item in
                        row(item)
                            .accessibilityIdentifier("holding.row.\(index)")
                    }
                }
            }
            .groupedList()
            .minimizingTabBar()
        }
    }

    private func row(_ item: HoldingItem) -> some View {
        let location = files.location(of: item)
        return HStack(alignment: .top, spacing: Space.m) {
            FileTile(name: item.name)
            FileDetails(name: item.name, location: Copy.Files.from(location), bytes: item.bytes, date: Copy.Files.movedAt(item.movedAt))
        }
        .padding(.vertical, Space.xs)
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Files.heldRowLabel(item, folder: location))
        .swipeActions(edge: .leading) {
            Button(Copy.Files.putBack) { Task { await files.putBack(item) } }
                .tint(Palette.accent)
        }
        .swipeActions(edge: .trailing) {
            Button(Copy.Files.deleteNow) { review = deleteRequest([item]) }
                .tint(Palette.remove)
        }
        .accessibilityAction(named: Copy.Files.putBack) { Task { await files.putBack(item) } }
        .accessibilityAction(named: Copy.Files.deleteNow) { review = deleteRequest([item]) }
    }

    private var putAllBack: BarAction? {
        guard !files.held.isEmpty else { return nil }
        return BarAction(title: Copy.Files.putAllBack, isEnabled: !files.isBusy) {
            Task { await files.putAllBack() }
        }
    }

    private var emptyHolding: BarAction? {
        guard !files.held.isEmpty else { return nil }
        return BarAction(title: Copy.Files.emptyHolding, isEnabled: !files.isBusy) {
            review = deleteRequest(files.held)
        }
    }

    private func deleteRequest(_ items: [HoldingItem]) -> ReviewRequest {
        let isAll = items.count == files.held.count
        return ReviewRequest(
            title: Copy.Files.removeTitle(items.count),
            removing: items.map { .file(id: $0.id.uuidString, name: $0.name, bytes: $0.bytes) },
            staying: [],
            reason: Reason(why: Copy.Files.whyDelete(items.count), keptSafe: Copy.Files.keptSafeDelete, undo: Copy.Reason.cantBeUndone),
            confirmTitle: Copy.Files.deleteButton(items.count),
            confirm: {
                if isAll { await files.emptyHolding() } else { await files.delete(items) }
            }
        )
    }
}

/// Nothing held: what Holding is and how it works.
private struct HoldingEmptyView: View {
    var body: some View {
        VStack(spacing: Space.m) {
            Image(systemName: "tray")
                .font(.largeTitle.weight(.light))
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
            Text(Copy.Files.holdingEmptyTitle)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(Copy.Files.holdingEmptyDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("holding.empty")
    }
}

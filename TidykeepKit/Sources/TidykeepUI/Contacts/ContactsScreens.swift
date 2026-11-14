import SwiftUI
import TidykeepContacts
import TidykeepCore

// MARK: Duplicate Contacts

/// Duplicate Contacts: what the app reads before it asks, then the cards that look like the
/// same person, by why they matched. Cards in different accounts are listed apart and never
/// merged. There is no bulk merge: each group is looked at on its own.
struct DuplicateContactsView: View {
    @Environment(ContactsModel.self) private var contacts
    @ViewState private var isAsking = false

    var body: some View {
        content
            .navigationTitle(Copy.Home.duplicateContacts)
            .inlineNavigationTitle()
            .task { await contacts.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch contacts.access {
        case .notDetermined:
            ContactsIntroView(isAsking: isAsking) {
                isAsking = true
                Task {
                    await contacts.requestAccess()
                    isAsking = false
                }
            }
        case .denied:
            ScrollView {
                AccessOffView(title: Copy.Contacts.accessOff, detail: Copy.Contacts.accessOffDetail, symbol: "person.crop.circle.badge.xmark")
                    .padding(Space.l)
            }
            .background(Palette.groupedBackground)
        case .allowed:
            if contacts.groups.isEmpty && contacts.crossAccountGroups.isEmpty {
                emptyOrChecking
            } else {
                ContactGroupList()
            }
        }
    }

    @ViewBuilder
    private var emptyOrChecking: some View {
        ScrollView {
            VStack(spacing: Space.l) {
                if contacts.isScanning || !contacts.hasChecked {
                    VStack(spacing: Space.m) {
                        ProgressView()
                        Text(Copy.Contacts.checking)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, Space.xxl)
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("contacts.status")
                } else if contacts.scanFailed {
                    InlineError(text: Copy.Contacts.scanFailed) { contacts.rescan() }
                } else {
                    AllTidyView(detail: Copy.Contacts.emptyDetail)
                        .padding(.top, Space.xl)
                    if contacts.isLimited {
                        Text(Copy.Contacts.limited)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .padding(Space.l)
        }
        .background(Palette.groupedBackground)
        .refreshable { contacts.rescan() }
    }
}

/// The groups, one section per strongest reason, then the cross-account ones. Rows are
/// numbered `contacts.row.<i>` from 0 down the whole list.
private struct ContactGroupList: View {
    @Environment(ContactsModel.self) private var contacts

    var body: some View {
        List {
            Section {
                status
            }
            ForEach(sections, id: \.reason) { section in
                Section(Copy.Contacts.section(section.reason)) {
                    ForEach(section.rows, id: \.group.id) { row in
                        link(row.group, index: row.index)
                    }
                }
            }
            if !contacts.crossAccountGroups.isEmpty {
                Section {
                    ForEach(Array(contacts.crossAccountGroups.enumerated()), id: \.element.id) { index, group in
                        groupRow(group)
                            .accessibilityIdentifier("contacts.other.\(index)")
                    }
                } header: {
                    Text(Copy.Contacts.otherAccounts)
                } footer: {
                    Text(Copy.Contacts.otherAccountsFooter)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .groupedList()
        .refreshable { contacts.rescan() }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                if contacts.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(Palette.accent)
                        .accessibilityHidden(true)
                }
                Text(contacts.isScanning ? Copy.Contacts.checking : Copy.Contacts.checked(contacts.checkedCount))
                    .font(.subheadline)
                    .contentTransition(.numericText())
            }
            if contacts.isLimited {
                Text(Copy.Contacts.limited)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("contacts.status")
    }

    private func link(_ group: ContactDuplicateGroup, index: Int) -> some View {
        NavigationLink(value: Route.contactMerge(group.id)) {
            groupRow(group)
        }
        .accessibilityIdentifier("contacts.row.\(index)")
        .swipeActions(edge: .trailing) {
            Button(Copy.Contacts.keepBoth) { contacts.keepApart(group.id) }
                .tint(Palette.accent)
        }
        .accessibilityAction(named: Text(Copy.Contacts.keepBoth)) { contacts.keepApart(group.id) }
    }

    private func groupRow(_ group: ContactDuplicateGroup) -> some View {
        ContactGroupRow(
            name: contacts.name(of: group),
            initials: Copy.Contacts.initials(contacts.card(group.keeperID)),
            cardCount: group.cardIDs.count,
            reasons: group.reasons,
            accounts: contacts.accounts(of: group)
        )
    }

    /// A list section: its reason and its rows, each with its number in the whole list.
    private struct ListSection {
        var reason: MatchReason
        var rows: [Row]
    }

    private struct Row {
        var index: Int
        var group: ContactDuplicateGroup
    }

    private var sections: [ListSection] {
        let numbered: [Row] = contacts.groups.enumerated().map { Row(index: $0.offset, group: $0.element) }
        return ContactsModel.sectionOrder.compactMap { (reason: MatchReason) -> ListSection? in
            let rows = numbered.filter { ContactsModel.section(of: $0.group) == reason }
            return rows.isEmpty ? nil : ListSection(reason: reason, rows: rows)
        }
    }
}

// MARK: Merge

/// One group's merge: the card as it will be, the choices, the cards as they are, what can't
/// be carried over, and why. Merge asks first ("Merge anyway"), then backs up and saves.
struct ContactMergeView: View {
    let groupID: String
    @Environment(ContactsModel.self) private var contacts

    var body: some View {
        if let group = contacts.group(groupID) {
            ContactMergeContent(group: group)
        } else {
            ScrollView {
                if contacts.isScanning {
                    ProgressView()
                        .padding(.top, Space.xxl)
                        .frame(maxWidth: .infinity)
                } else {
                    AllTidyView(detail: Copy.Contacts.gone)
                }
            }
            .background(Palette.groupedBackground)
            .navigationTitle(Copy.Home.duplicateContacts)
            .inlineNavigationTitle()
        }
    }
}

private struct ContactMergeContent: View {
    let group: ContactDuplicateGroup
    @Environment(ContactsModel.self) private var contacts
    @Environment(\.dismiss) private var dismiss
    @ViewState private var keeperID: String?
    @ViewState private var nameFrom: String?
    @ViewState private var photoFrom: String?
    @ViewState private var confirming = false

    var body: some View {
        let plan = contacts.preview(group, keeperID: keeper, choices: choices)
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                if let problem = contacts.problems[group.id] {
                    InlineError(text: Copy.Contacts.problem(problem)) { contacts.checkAgain(group.id) }
                        .accessibilityIdentifier("contacts.error")
                }
                ReasonCard(reason: reason)
                if let plan {
                    CardSection(title: Copy.Contacts.mergedCard, footer: Copy.Contacts.added(plan.addedFieldCount)) {
                        MergedCardPreview(plan: plan, numbers: numbers)
                    }
                }
                if !nameOptions.isEmpty || !photoOptions.isEmpty {
                    CardSection(title: Copy.Contacts.choose, footer: Copy.Contacts.chooseFooter) {
                        choicesCard
                    }
                }
                CardSection(title: Copy.Contacts.cardsBeingMerged, footer: Copy.Contacts.keeperFooter) {
                    cardsCard(keeper: plan?.keeperID ?? keeper)
                }
                NotesCaveatRow(text: Copy.Contacts.notesCaveat(removedNumbers(plan)))
            }
            .padding(.horizontal, Space.l)
            .padding(.top, Space.s)
            .padding(.bottom, Space.xl)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.groupedBackground)
        .navigationTitle(contacts.name(of: group))
        .inlineNavigationTitle()
        .actionBar(
            secondary: BarAction(title: Copy.Contacts.keepBoth, hint: Copy.Contacts.keepBothHint) {
                contacts.keepApart(group.id)
                dismiss()
            },
            primary: BarAction(
                title: Copy.Contacts.mergeButton(plan?.backupIDs.count ?? group.cardIDs.count),
                systemImage: "arrow.triangle.merge",
                isEnabled: plan != nil,
                isBusy: contacts.mergingGroupID == group.id,
                hint: Copy.Contacts.mergeHint
            ) { confirming = true }
        )
        .confirmationDialog(Copy.Contacts.confirmTitle(removedNumbers(plan)), isPresented: $confirming, titleVisibility: .visible) {
            Button(Copy.Contacts.mergeAnyway) { merge() }
            Button(Copy.General.cancel, role: .cancel) {}
        } message: {
            Text(Copy.Contacts.confirmMessage(removedNumbers(plan)))
        }
    }

    // MARK: Choices

    private var keeper: String { keeperID ?? group.keeperID }

    private var choices: MergeChoices {
        MergeChoices(nameFrom: nameFrom ?? keeper, photoFrom: photoFrom)
    }

    private var cards: [ContactCard] { contacts.cards(in: group) }

    /// Card numbers by identifier, from 0, in the group's order.
    private var numbers: [String: Int] {
        Dictionary(group.cardIDs.enumerated().map { ($0.element, $0.offset) }) { first, _ in first }
    }

    /// Cards whose names differ, one per name. Empty when every card has the same name.
    private var nameOptions: [ContactCard] {
        var seen: Set<String> = []
        let distinct = cards.filter { !$0.displayName.isEmpty && seen.insert($0.displayName).inserted }
        return distinct.count > 1 ? distinct : []
    }

    /// Cards with a photo, when there is a choice to make.
    private var photoOptions: [ContactCard] {
        let withPhoto = cards.filter(\.hasImage)
        return withPhoto.count > 1 ? withPhoto : []
    }

    /// The name option showing the chosen name. Cards with the same name share one option.
    private var nameSelection: String {
        let chosen = nameFrom ?? keeper
        let name = cards.first { $0.id == chosen }?.displayName
        return nameOptions.first { $0.id == chosen || $0.displayName == name }?.id ?? chosen
    }

    private var choicesCard: some View {
        VStack(spacing: 0) {
            if !nameOptions.isEmpty {
                choiceRow(Copy.Contacts.nameChoice) {
                    Picker(Copy.Contacts.nameChoice, selection: Binding(get: { nameSelection }, set: { nameFrom = $0 })) {
                        ForEach(nameOptions) { card in
                            Text(card.displayName).tag(card.id)
                        }
                    }
                    .accessibilityIdentifier("contacts.choose.name")
                }
            }
            if !nameOptions.isEmpty && !photoOptions.isEmpty {
                Divider().padding(.leading, Space.l)
            }
            if !photoOptions.isEmpty {
                choiceRow(Copy.Contacts.photoChoice) {
                    Picker(Copy.Contacts.photoChoice, selection: Binding(get: { photoFrom ?? (cards.first { $0.id == keeper }?.hasImage == true ? keeper : photoOptions.first?.id) }, set: { photoFrom = $0 })) {
                        ForEach(photoOptions) { card in
                            Text(Copy.Contacts.photoFrom(numbers[card.id] ?? 0)).tag(Optional(card.id))
                        }
                    }
                    .accessibilityIdentifier("contacts.choose.photo")
                }
            }
        }
        .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    private func choiceRow(_ title: String, @ViewBuilder picker: () -> some View) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.m) {
                Text(title).font(.body)
                Spacer(minLength: Space.s)
                picker().labelsHidden().pickerStyle(.menu).tint(Palette.accent)
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title).font(.body)
                picker().labelsHidden().pickerStyle(.menu).tint(Palette.accent)
            }
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.xs)
        .frame(minHeight: 44)
    }

    private func cardsCard(keeper: String) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                if index > 0 { Divider().padding(.leading, 52) }
                MergeCardRow(card: card, number: numbers[card.id] ?? index, isKeeper: card.id == keeper) {
                    keeperID = card.id
                    contacts.announceKeeper(number: numbers[card.id] ?? index)
                }
            }
        }
        .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    // MARK: Merging

    private var reason: Reason {
        let n = group.cardIDs.count
        return Reason(why: Copy.Contacts.why(group.reasons), keptSafe: Copy.Contacts.keptSafe(n), undo: Copy.Contacts.undoReason(n))
    }

    private func removedNumbers(_ plan: MergePlan?) -> [Int] {
        let removed = plan?.removedIDs ?? group.cardIDs.filter { $0 != keeper }
        return removed.compactMap { numbers[$0] }.sorted()
    }

    private func merge() {
        let keeper = keeper, choices = choices, id = group.id
        Task {
            if await contacts.merge(id, keeperID: keeper, choices: choices) {
                dismiss()
            }
        }
    }
}

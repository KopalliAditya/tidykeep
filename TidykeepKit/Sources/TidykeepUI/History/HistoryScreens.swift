import SwiftUI
import TidykeepCore

// MARK: - History

/// The History tab: every change the app made, by day, newest first. Each row says what
/// happened and where it stands now, and offers the one way back the app can take by itself.
/// History is the record; the notice banner is only a convenience.
struct HistoryView: View {
    @Environment(AppState.self) private var state
    @Environment(History.self) private var history
    @Namespace private var rotorNamespace
    @ViewState private var working: Set<UUID> = []
    @ViewState private var undoneCount = 0

    var body: some View {
        Group {
            if history.receipts.isEmpty {
                empty
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.groupedBackground)
        .navigationTitle(Copy.Tabs.history)
        .minimizingTabBar()
        .feedback(.success, trigger: undoneCount)
    }

    // MARK: Empty

    private var empty: some View {
        ContentUnavailableView {
            Label(Copy.Receipts.empty, systemImage: "clock.arrow.circlepath")
        } description: {
            Text(Copy.Receipts.emptyDetail)
        }
    }

    // MARK: List

    private var list: some View {
        let now = Date()
        let days = ReceiptDay.group(history.receipts)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.xl) {
                ForEach(days) { day in
                    CardSection(title: Copy.Receipts.dayHeader(day.day, now: now)) {
                        VStack(spacing: 0) {
                            ForEach(Array(day.receipts.enumerated()), id: \.element.id) { index, receipt in
                                if index > 0 { Divider().padding(.leading, HistoryRow.textInset) }
                                HistoryRow(receipt: receipt, now: now, action: action(for: receipt))
                                    .accessibilityRotorEntry(id: receipt.id, in: rotorNamespace)
                            }
                        }
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    }
                }
                Text(Copy.Receipts.footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Space.l)
            }
            .padding(.horizontal, Space.l)
            .padding(.top, Space.s)
            .padding(.bottom, Space.xl)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .accessibilityRotor(Copy.Receipts.canUndoRotor) {
            ForEach(history.receipts.filter(state.canUndo)) { receipt in
                AccessibilityRotorEntry(Text(Copy.Receipts.sentence(receipt)), id: receipt.id, in: rotorNamespace)
            }
        }
    }

    /// The row's one action: Undo, Put back or Review again, when the app can do it itself.
    private func action(for receipt: Receipt) -> HistoryRow.Action? {
        guard state.canUndo(receipt) else { return nil }
        return HistoryRow.Action(
            title: Copy.Receipts.actionTitle(receipt.kind),
            hint: Copy.Receipts.actionHint(receipt.kind),
            isBusy: working.contains(receipt.id)
        ) {
            guard !working.contains(receipt.id) else { return }
            working.insert(receipt.id)
            Task {
                await takeBack(receipt, state: state)
                working.remove(receipt.id)
                if history.receipt(receipt.id)?.status == .undone { undoneCount += 1 }
            }
        }
    }
}

/// Runs a receipt's way back. "Keep all" comes back to the list; everything else goes
/// through `AppState.undo`.
@MainActor
func takeBack(_ receipt: Receipt, state: AppState) async {
    if receipt.kind == .keptAll {
        state.photos.reviewAgain(receipt)
    } else {
        await state.undo(receipt)
    }
}

/// One day of History.
struct ReceiptDay: Identifiable, Equatable {
    /// The start of the day.
    let day: Date
    /// Newest first.
    let receipts: [Receipt]

    var id: Date { day }

    /// Receipts by the day they happened, newest day first and newest first within a day.
    static func group(_ receipts: [Receipt], calendar: Calendar = .current) -> [ReceiptDay] {
        Dictionary(grouping: receipts) { calendar.startOfDay(for: $0.date) }
            .map { ReceiptDay(day: $0.key, receipts: $0.value.sorted(by: newestFirst)) }
            .sorted { $0.day > $1.day }
    }

    private static func newestFirst(_ a: Receipt, _ b: Receipt) -> Bool {
        a.date != b.date ? a.date > b.date : a.id.uuidString < b.id.uuidString
    }
}

// MARK: - Row

/// A ledger row: a symbol in a tinted circle, the sentence, the time and status, and at most
/// one action. The whole row opens the receipt; for VoiceOver it is one element with the
/// action as a custom action.
struct HistoryRow: View {
    struct Action {
        var title: String
        var hint: String
        var isBusy: Bool
        var run: () -> Void
    }

    let receipt: Receipt
    var now = Date()
    let action: Action?
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Where the text starts, so dividers line up with it.
    static let textInset: CGFloat = Space.l + 36 + Space.m

    var body: some View {
        NavigationLink(value: Route.receipt(receipt.id)) {
            HStack(alignment: typeSize.isAccessibilitySize ? .top : .center, spacing: Space.m) {
                ReceiptSymbol(receipt: receipt)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(Copy.Receipts.sentence(receipt))
                        .font(.body)
                        .foregroundStyle(receipt.status == .undone ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Copy.Receipts.rowStatus(receipt, now: now))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(receipt.status == .failed ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if typeSize.isAccessibilitySize, let action {
                        actionButton(action)
                    }
                }
                Spacer(minLength: Space.s)
                if !typeSize.isAccessibilitySize, let action {
                    actionButton(action)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.m)
            .frame(minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Copy.Receipts.rowLabel(receipt, now: now))
        .accessibilityActions {
            if let action {
                Button(action.title, action: action.run)
            }
        }
        .accessibilityIdentifier("history.row.\(receipt.id.uuidString)")
    }

    /// A tinted capsule with a 44-point hit area. VoiceOver reaches it as the row's action.
    private func actionButton(_ action: Action) -> some View {
        Button(action: action.run) {
            ZStack {
                Text(action.title).opacity(action.isBusy ? 0 : 1)
                if action.isBusy { ProgressView().controlSize(.small) }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Palette.accent)
            .padding(.horizontal, Space.m)
            .padding(.vertical, 6)
            .background(Palette.accent.opacity(0.12), in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action.isBusy)
        .accessibilityHidden(true)
    }
}

/// A receipt's symbol in a tinted circle: accent when it stands, orange when nothing changed,
/// grey once undone or while it's being checked.
struct ReceiptSymbol: View {
    let receipt: Receipt
    var scale: CGFloat = 1
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 36

    var body: some View {
        let side = min(size, 56) * scale
        Image(systemName: Copy.Receipts.symbol(receipt.kind))
            .font(.system(size: side * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: side, height: side)
            .background(tint.opacity(0.14), in: Circle())
            .accessibilityHidden(true)
    }

    private var tint: Color {
        switch receipt.status {
        case .done, .partial: Palette.accent
        case .failed: .orange
        case .undone, .inProgress: .secondary
        }
    }
}

// MARK: - Receipt

/// The full receipt: what changed, when and how many, how to get them back, and the way back
/// the app can take itself.
struct ReceiptView: View {
    let receiptID: UUID
    @Environment(AppState.self) private var state
    @Environment(History.self) private var history
    @ViewState private var working = false
    @ViewState private var undoneCount = 0

    var body: some View {
        Group {
            if let receipt = history.receipt(receiptID) {
                content(receipt, now: Date())
            } else {
                ContentUnavailableView(
                    Copy.Receipts.missing,
                    systemImage: "clock.arrow.circlepath",
                    description: Text(Copy.Receipts.missingDetail)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.groupedBackground)
        .navigationTitle(Copy.Receipts.receiptTitle)
        .inlineNavigationTitle()
        .actionBar(primary: undoAction)
        .feedback(.success, trigger: undoneCount)
    }

    private func content(_ receipt: Receipt, now: Date) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                header(receipt, now: now)
                ReceiptSummaryCard(receipt: receipt, now: now)
                recovery(receipt, now: now)
            }
            .padding(.horizontal, Space.l)
            .padding(.top, Space.l)
            .padding(.bottom, Space.xl)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Header

    private func header(_ receipt: Receipt, now: Date) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            ReceiptSymbol(receipt: receipt, scale: 1.5)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(Copy.Receipts.sentence(receipt))
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(Copy.Receipts.status(receipt, now: now))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(receipt.status == .failed ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Space.xs)
    }

    // MARK: How to get them back

    private func recovery(_ receipt: Receipt, now: Date) -> some View {
        let steps = Copy.Receipts.recoverySteps(receipt, now: now)
        return CardSection(title: Copy.Receipts.howToGetBack) {
            VStack(alignment: .leading, spacing: Space.m) {
                Text(Copy.Receipts.recoveryIntro(receipt, now: now))
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                if !steps.isEmpty {
                    Divider()
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        RecoveryStep(number: index + 1, text: step)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.l)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
    }

    // MARK: Undo

    private var undoAction: BarAction? {
        guard let receipt = history.receipt(receiptID), state.canUndo(receipt) else { return nil }
        return BarAction(
            title: Copy.Receipts.actionTitle(receipt.kind),
            systemImage: "arrow.uturn.backward",
            isBusy: working,
            hint: Copy.Receipts.actionHint(receipt.kind)
        ) {
            guard !working else { return }
            working = true
            Task {
                await takeBack(receipt, state: state)
                working = false
                if history.receipt(receipt.id)?.status == .undone { undoneCount += 1 }
            }
        }
    }
}

/// What, when and how many, in the Reason card's style, ending with the Undo line.
private struct ReceiptSummaryCard: View {
    let receipt: Receipt
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            line(Copy.Receipts.what, symbol: "text.magnifyingglass", text: Copy.Receipts.whatHappened(receipt.kind))
            line(Copy.Receipts.when, symbol: "calendar", text: Copy.dayAndTime(receipt.date), tint: .secondary)
            line(Copy.Receipts.howMany, symbol: "number", text: Copy.Receipts.howManyValue(receipt), tint: .secondary)
            if isFileReceipt, let bytes = receipt.bytes {
                line(Copy.Receipts.size, symbol: "internaldrive", text: Copy.Receipts.exactSize(bytes), tint: .secondary)
            }
            if let names = Copy.Receipts.fileNameList(receipt) {
                line(Copy.Receipts.fileNames, symbol: "doc", text: names, tint: .secondary)
            }
            if receipt.kind == .contactsMerged, let title = receipt.title {
                line(Copy.Receipts.keptCard, symbol: "person.crop.circle", text: title, tint: .secondary)
            }
            line(Copy.Receipts.undoHeading, symbol: "arrow.uturn.backward", text: Copy.Receipts.undoLine(receipt, now: now))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.l)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reason.card")
    }

    /// Photos and videos never show a size; files always do.
    private var isFileReceipt: Bool {
        switch receipt.kind {
        case .filesHeld, .filesPutBack, .filesDeleted: true
        default: false
        }
    }

    private func line(_ title: String, symbol: String, text: String, tint: Color = Palette.accent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(minWidth: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(text.replacingOccurrences(of: "\n", with: ", "))")
    }
}

/// One numbered step of "How to get them back".
private struct RecoveryStep: View {
    let number: Int
    let text: String
    @ScaledMetric(relativeTo: .subheadline) private var badge: CGFloat = 24

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Text(number.formatted())
                .font(.footnote.weight(.bold).monospacedDigit())
                .foregroundStyle(Palette.accent)
                .frame(width: badge, height: badge)
                .background(Palette.accent.opacity(0.14), in: Circle())
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Receipts.stepLabel(number, text))
    }
}

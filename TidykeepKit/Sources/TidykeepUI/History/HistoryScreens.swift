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
    @ScaledMetric(relativeTo: .body) private var symbolSize = ReceiptSymbol.baseSize
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
        let inset = HistoryRow.textInset(symbolSize: symbolSize)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.xl) {
                ForEach(days) { day in
                    CardSection(title: Copy.Receipts.dayHeader(day.day, now: now)) {
                        VStack(spacing: 0) {
                            ForEach(Array(day.receipts.enumerated()), id: \.element.id) { index, receipt in
                                if index > 0 { Divider().padding(.leading, inset) }
                                HistoryRow(receipt: receipt, now: now, action: action(for: receipt), rotor: rotorNamespace)
                            }
                        }
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    }
                }
                Text(Copy.Receipts.footer)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
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
    /// It shows as busy wherever the undo was started: here, on the receipt or in the banner.
    private func action(for receipt: Receipt) -> HistoryRow.Action? {
        guard state.canUndo(receipt) else { return nil }
        return HistoryRow.Action(
            title: Copy.Receipts.actionTitle(receipt.kind),
            hint: Copy.Receipts.actionHint(receipt.kind),
            isBusy: history.isUndoing(receipt.id)
        ) {
            Task {
                await state.undo(receipt)
                if history.receipt(receipt.id)?.status == .undone { undoneCount += 1 }
            }
        }
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
/// one action. The whole row opens the receipt.
///
/// The link sits behind the row and the action button is its sibling, not inside it. For
/// VoiceOver the link is the one element, carrying the action as a custom action, and the
/// button is hidden. Voice Control and Switch Control see the button on its own, so "Tap
/// Undo" works.
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
    var rotor: Namespace.ID?
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn

    /// Where the text starts, so dividers line up with it at every text size.
    static func textInset(symbolSize: CGFloat) -> CGFloat {
        Space.l + ReceiptSymbol.side(symbolSize) + Space.m
    }

    var body: some View {
        content
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.m)
            .frame(minHeight: 64)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { link }
    }

    /// The action sits beside the text when the sentence and status each fit on one line next
    /// to it, and under the text otherwise, so neither squeezes the other.
    @ViewBuilder
    private var content: some View {
        if typeSize.isAccessibilitySize || action == nil {
            layout(actionBelow: true)
        } else {
            ViewThatFits(in: .horizontal) {
                layout(actionBelow: false)
                layout(actionBelow: true)
            }
        }
    }

    private func layout(actionBelow: Bool) -> some View {
        HStack(alignment: typeSize.isAccessibilitySize || actionBelow ? .top : .center, spacing: Space.m) {
            ReceiptSymbol(receipt: receipt)
                .allowsHitTesting(false)
            // The words are the link's label, so they're hidden here and taps go through.
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(Copy.Receipts.sentence(receipt))
                    .font(.body)
                    .foregroundStyle(receipt.status == .undone ? Palette.secondaryText : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                // Secondary even when nothing changed: the orange symbol says that, and orange
                // text on a white card is too faint to read.
                Text(Copy.Receipts.rowStatus(receipt, now: now))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                if actionBelow, let action {
                    actionButton(action)
                }
            }
            Spacer(minLength: Space.s)
            if !actionBelow, let action {
                actionButton(action)
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .frame(maxHeight: actionBelow ? .infinity : nil)
        }
    }

    /// The row's link and its one VoiceOver element.
    private var link: some View {
        NavigationLink(value: Route.receipt(receipt.id)) {
            Color.clear.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Copy.Receipts.rowLabel(receipt, now: now))
        .accessibilityHint(action.map { Copy.Receipts.actionRowHint(title: $0.title, hint: $0.hint) } ?? "")
        .accessibilityInputLabels([Text(Copy.Receipts.sentence(receipt))])
        .accessibilityActions {
            if let action, !action.isBusy {
                Button(action.title, action: action.run)
            }
        }
        .accessibilityIdentifier("history.row.\(receipt.id.uuidString)")
        .modifier(RotorEntry(id: receipt.id, namespace: rotor))
    }

    /// A tinted capsule with a 44-point hit area. VoiceOver reaches it as the row's custom
    /// action instead, so it's hidden only while VoiceOver runs.
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
        .fixedSize()
        .disabled(action.isBusy)
        .accessibilityLabel(action.title)
        .accessibilityHint(action.hint)
        .accessibilityHidden(voiceOverOn)
    }
}

/// Marks the row's link as a rotor entry when the list has a rotor.
private struct RotorEntry: ViewModifier {
    let id: UUID
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.accessibilityRotorEntry(id: id, in: namespace)
        } else {
            content
        }
    }
}

/// A receipt's symbol in a tinted circle: accent when it stands, orange when nothing changed,
/// grey once undone or while it's being checked.
struct ReceiptSymbol: View {
    /// The circle's side at the default text size.
    static let baseSize: CGFloat = 36

    let receipt: Receipt
    var scale: CGFloat = 1
    @ScaledMetric(relativeTo: .body) private var size = ReceiptSymbol.baseSize

    /// The circle's side for a scaled base size, capped so it never crowds the text.
    static func side(_ scaled: CGFloat, scale: CGFloat = 1) -> CGFloat {
        min(scaled, 56) * scale
    }

    var body: some View {
        let side = Self.side(size, scale: scale)
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
        case .undone, .inProgress: Palette.secondaryText
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
                    .foregroundStyle(Palette.secondaryText)
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
            isBusy: history.isUndoing(receipt.id),
            hint: Copy.Receipts.actionHint(receipt.kind)
        ) {
            Task {
                await state.undo(receipt)
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
            line(Copy.Receipts.when, symbol: "calendar", text: Copy.dayAndTime(receipt.date), tint: Palette.secondaryText)
            line(Copy.Receipts.howMany, symbol: "number", text: Copy.Receipts.howManyValue(receipt), tint: Palette.secondaryText)
            if let size = Copy.Receipts.sizeLine(receipt) {
                line(Copy.Receipts.size, symbol: "internaldrive", text: size, tint: Palette.secondaryText)
            }
            if let names = Copy.Receipts.fileNameList(receipt) {
                line(Copy.Receipts.fileNames, symbol: "doc", text: names, tint: Palette.secondaryText)
            }
            if receipt.kind == .contactsMerged, let title = receipt.title {
                line(Copy.Receipts.keptCard, symbol: "person.crop.circle", text: title, tint: Palette.secondaryText)
            }
            line(Copy.Receipts.undoHeading, symbol: "arrow.uturn.backward", text: Copy.Receipts.undoLine(receipt, now: now))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.l)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reason.card")
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
                    .foregroundStyle(Palette.secondaryText)
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

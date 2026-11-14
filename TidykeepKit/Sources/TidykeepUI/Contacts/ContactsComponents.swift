import SwiftUI
import TidykeepContacts
#if os(iOS)
import ContactsUI
#endif

// The pieces the contacts screens are built from: the monogram, the pre-permission screen,
// list rows, a card's details and the merged-card preview.

// MARK: Monogram

/// A contact's initials in a tinted circle, like Contacts without a photo. Decorative: the
/// row or card it sits in says the name.
struct ContactMonogram: View {
    let initials: String
    var size: CGFloat = 40
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        let side = size * min(scale, 1.6)
        Circle()
            .fill(LinearGradient(colors: [Palette.accent.opacity(0.22), Palette.accent.opacity(0.12)], startPoint: .top, endPoint: .bottom))
            .frame(width: side, height: side)
            .overlay {
                if initials.isEmpty {
                    Image(systemName: "person.fill")
                        .font(.system(size: side * 0.45))
                        .foregroundStyle(Palette.accent)
                } else {
                    // A text style, so the letters follow Dynamic Type; they shrink to fit the circle,
                    // which grows with it up to its cap.
                    Text(initials)
                        .font(size >= 48 ? .title3 : .subheadline)
                        .fontWeight(.semibold)
                        .fontDesign(.rounded)
                        .foregroundStyle(Palette.accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                        .padding(side * 0.14)
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: Before access

/// What the app reads and why, before iOS asks. Continue shows the system prompt.
struct ContactsIntroView: View {
    let isAsking: Bool
    let onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xxl) {
                VStack(alignment: .leading, spacing: Space.m) {
                    Image(systemName: "person.2.crop.square.stack")
                        .font(.largeTitle.weight(.medium))
                        .foregroundStyle(Palette.accent)
                        .accessibilityHidden(true)
                    Text(Copy.Contacts.introTitle)
                        .font(.title.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(Copy.Contacts.introDetail)
                        .font(.body)
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: Space.xl) {
                    ForEach(Copy.Contacts.introRows, id: \.text) { row in
                        HStack(alignment: .top, spacing: Space.l) {
                            Image(systemName: row.symbol)
                                .font(.title3.weight(.medium))
                                .foregroundStyle(Palette.accent)
                                .frame(width: 32)
                                .accessibilityHidden(true)
                            Text(row.text)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.horizontal, Space.xl)
            .padding(.top, Space.xl)
            .padding(.bottom, Space.xl)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .contactsBottomBar {
            Button(action: onContinue) {
                Text(Copy.Contacts.continue)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.glassProminent)
            .tint(Palette.accent)
            .controlSize(.large)
            .disabled(isAsking)
            .accessibilityIdentifier("contacts.continue")
            .padding(.horizontal, Space.xl)
            .padding(.bottom, Space.m)
        }
        .background(Palette.groupedBackground)
    }
}

extension View {
    /// The system's picker for sharing more contacts with limited access (iPhone only). The
    /// Mac renders draw the button, which does nothing there.
    @ViewBuilder
    func contactsAccessPicker(isPresented: Binding<Bool>, onChange: @escaping @MainActor @Sendable () -> Void) -> some View {
        // Not on Mac Catalyst, which the app doesn't ship on.
        #if os(iOS) && !targetEnvironment(macCatalyst)
        contactAccessPicker(isPresented: isPresented) { _ in
            Task { @MainActor in onChange() }
        }
        #else
        self
        #endif
    }

    /// Pins content to the bottom like `actionBar`: a glass bar on iPhone, a plain inset in
    /// the Mac renders.
    @ViewBuilder
    func contactsBottomBar(@ViewBuilder _ content: () -> some View) -> some View {
        #if os(iOS)
        safeAreaBar(edge: .bottom, content: content)
        #else
        safeAreaInset(edge: .bottom, content: content)
        #endif
    }
}

// MARK: List rows

/// A list row: monogram, name, "2 cards · Same phone · Same name", and the accounts. Cards in
/// different accounts carry a "Not merged" tag. At accessibility text sizes the monogram sits
/// above the text.
struct ContactGroupRow: View {
    let name: String
    let initials: String
    let cardCount: Int
    let reasons: Set<MatchReason>
    let accounts: [String]
    var mergeable = true
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s))
            : AnyLayout(HStackLayout(spacing: Space.m))
        layout {
            ContactMonogram(initials: initials)
            VStack(alignment: .leading, spacing: Space.hair) {
                Text(name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text(Copy.cards(cardCount) + " · " + Copy.Contacts.reasons(reasons))
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
                if !accounts.isEmpty {
                    Text(Copy.Contacts.accounts(accounts))
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            if !mergeable {
                Text(Copy.Contacts.notMergeable)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.secondaryText)
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, Space.hair)
                    .background(Palette.fill, in: Capsule())
            }
        }
        .padding(.vertical, Space.xs)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Contacts.rowLabel(name, cards: cardCount, reasons: reasons, accounts: accounts, mergeable: mergeable))
    }
}

// MARK: Card details

/// One value on a card: "mobile  +1 415 555 0134". `key` is its `MergeField` key, for the
/// merged card's "From card 2" captions.
struct ContactFieldLine: Hashable, Identifiable {
    var label: String
    var value: String
    var key: String
    var id: String { key }
}

enum ContactFields {
    /// Everything on the card a person would recognize it by, in Contacts' order. The name
    /// is left out; the views show it on its own.
    static func lines(_ card: ContactCard) -> [ContactFieldLine] {
        var lines: [ContactFieldLine] = []
        let job = [card.jobTitle, card.department, card.organization]
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !job.isEmpty, card.displayName != card.organization || !card.givenName.isEmpty || !card.familyName.isEmpty {
            lines.append(.init(label: Copy.Contacts.company, value: job.joined(separator: " · "), key: MergeField.organization))
        }
        if !card.nickname.isEmpty {
            lines.append(.init(label: Copy.Contacts.nickname, value: card.nickname, key: MergeField.nickname))
        }
        for (i, phone) in card.phones.enumerated() {
            lines.append(.init(label: Copy.Contacts.label(phone.label) ?? Copy.Contacts.phone, value: phone.value, key: MergeField.phone(i)))
        }
        for (i, email) in card.emails.enumerated() {
            lines.append(.init(label: Copy.Contacts.label(email.label) ?? Copy.Contacts.email, value: email.value, key: MergeField.email(i)))
        }
        for (i, address) in card.postalAddresses.enumerated() where !address.isEmpty {
            lines.append(.init(label: Copy.Contacts.label(address.label) ?? Copy.Contacts.address, value: Copy.Contacts.address(address), key: MergeField.postalAddress(i)))
        }
        for (i, url) in card.urls.enumerated() {
            lines.append(.init(label: Copy.Contacts.label(url.label) ?? Copy.Contacts.web, value: url.value, key: MergeField.url(i)))
        }
        if let birthday = card.birthday {
            lines.append(.init(label: Copy.Contacts.birthday, value: Copy.Contacts.date(birthday), key: MergeField.birthday))
        }
        for (i, date) in card.dates.enumerated() {
            lines.append(.init(label: Copy.Contacts.label(date.label) ?? Copy.Contacts.dateLabel, value: Copy.Contacts.date(date.date), key: MergeField.date(i)))
        }
        for (i, relation) in card.relations.enumerated() {
            lines.append(.init(label: Copy.Contacts.label(relation.label) ?? Copy.Contacts.related, value: relation.value, key: MergeField.relation(i)))
        }
        for (i, profile) in card.socialProfiles.enumerated() {
            let value = [profile.username, profile.urlString].first { !$0.isEmpty } ?? profile.userIdentifier
            lines.append(.init(label: profile.service.isEmpty ? Copy.Contacts.profile : profile.service, value: value, key: MergeField.socialProfile(i)))
        }
        for (i, im) in card.instantMessages.enumerated() {
            lines.append(.init(label: im.service.isEmpty ? Copy.Contacts.chat : im.service, value: im.username, key: MergeField.instantMessage(i)))
        }
        return lines
    }
}

/// A label over its value, with an optional caption in accent ("From card 2").
struct ContactFieldRow: View {
    let line: ContactFieldLine
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.hair) {
            Text(line.label)
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
            Text(line.value)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            if let caption {
                Label(caption, systemImage: "plus.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Palette.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.s)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([line.label, line.value, caption].compactMap { $0 }.joined(separator: ", "))
    }
}

// MARK: Merged card

/// The card as it will be after the merge, each value captioned with the card it comes from
/// when that isn't the card that stays.
struct MergedCardPreview: View {
    let plan: MergePlan
    /// Card numbers by identifier, from 0.
    let numbers: [String: Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(ContactFields.lines(plan.merged)) { line in
                Divider().padding(.leading, Space.l)
                ContactFieldRow(line: line, caption: caption(line.key))
            }
            if let photo = photoCaption {
                Divider().padding(.leading, Space.l)
                ContactFieldRow(line: ContactFieldLine(label: Copy.Contacts.photo, value: photo, key: MergeField.photo), caption: caption(MergeField.photo))
            }
        }
        .padding(.vertical, Space.s)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("contacts.merged")
    }

    private var header: some View {
        HStack(spacing: Space.m) {
            ContactMonogram(initials: Copy.Contacts.initials(plan.merged), size: 48)
            VStack(alignment: .leading, spacing: Space.hair) {
                Text(Copy.Contacts.name(plan.merged))
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let from = caption(MergeField.name) {
                    Label(from, systemImage: "plus.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Palette.accent)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.s)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([Copy.Contacts.name(plan.merged), caption(MergeField.name)].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isHeader)
    }

    private var photoCaption: String? {
        if let source = plan.photoFromID, let n = numbers[source] { return Copy.Contacts.photoFrom(n) }
        if plan.merged.hasImage, let n = numbers[plan.keeperID] { return Copy.Contacts.photoFrom(n) }
        return nil
    }

    /// "From card 2" when the value isn't the keeper's own.
    private func caption(_ key: String) -> String? {
        guard let source = plan.fieldSources[key], source != plan.keeperID, let n = numbers[source] else { return nil }
        return Copy.Contacts.fromCard(n)
    }
}

// MARK: Cards being merged

/// One of the cards being merged, as it is now. Tapping it makes it the card that stays.
struct MergeCardRow: View {
    let card: ContactCard
    let number: Int
    let isKeeper: Bool
    let select: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: Space.m) {
                Image(systemName: isKeeper ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isKeeper ? Palette.accent : Palette.secondaryText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.xs) {
                    title
                    Text(Copy.Contacts.name(card))
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    ForEach(lines) { line in
                        Text(line.label + "  " + line.value)
                            .font(.subheadline)
                            .foregroundStyle(Palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if card.hasImage {
                        Text(Copy.Contacts.hasPhoto)
                            .font(.subheadline)
                            .foregroundStyle(Palette.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.m)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityHint(isKeeper ? "" : Copy.Contacts.stayHint)
        .accessibilityAddTraits(isKeeper ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("contacts.card.\(number)")
    }

    private var title: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.xs))
            : AnyLayout(HStackLayout(spacing: Space.s))
        return layout {
            Text(Copy.Contacts.cardNumber(number))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            if !card.containerName.isEmpty {
                Text(card.containerName)
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: Space.s) }
            Text(isKeeper ? Copy.Contacts.stays : Copy.Contacts.goes)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isKeeper ? Palette.onAccent : Color.primary)
                .padding(.horizontal, Space.s)
                .padding(.vertical, Space.hair)
                .background(isKeeper ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Palette.fill), in: Capsule())
        }
    }

    private var lines: [ContactFieldLine] { ContactFields.lines(card) }

    private var spokenLabel: String {
        var parts = [Copy.Contacts.cardNumber(number)]
        if !card.containerName.isEmpty { parts.append(card.containerName) }
        parts.append(Copy.Contacts.name(card))
        parts += lines.map { "\($0.label) \($0.value)" }
        if card.hasImage { parts.append(Copy.Contacts.hasPhoto) }
        parts.append(isKeeper ? Copy.Contacts.stays : Copy.Contacts.goes)
        return parts.joined(separator: ", ")
    }
}

/// The one thing a merge can't carry over: notes on the cards it removes.
struct NotesCaveatRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Image(systemName: "note.text")
                .foregroundStyle(Palette.closeCall)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Space.m)
        .background(Palette.closeCall.opacity(0.1), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("contacts.notes")
    }
}

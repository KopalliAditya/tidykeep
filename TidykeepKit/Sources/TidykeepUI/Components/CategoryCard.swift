import SwiftUI

/// A Home card for one kind of photo clutter: a stack of examples, a title, a count and a
/// detail line. The whole card is one button for VoiceOver.
struct CategoryCard: View {
    let title: String
    let symbol: String
    let photoIDs: [String]
    /// "23 groups", or nil while checking with nothing found yet.
    let count: String?
    let detail: String?
    var isChecking = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .top) {
                ThumbnailStack(ids: photoIDs, symbol: symbol, size: 48)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: Space.hair) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Group {
                    if let count {
                        Text(count).foregroundStyle(.primary)
                    } else if isChecking {
                        Text(Copy.Home.checking).foregroundStyle(.secondary)
                    } else {
                        Text(Copy.Home.noneFound).foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline.weight(.medium))
                .contentTransition(.numericText())
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(2)
            .minimumScaleFactor(0.85)
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Home.cardLabel(title, count ?? (isChecking ? Copy.Home.checking : Copy.Home.noneFound), detail))
        .accessibilityAddTraits(.isButton)
    }
}

/// A Home row for files and contacts: an icon tile, a title, a detail line and a value.
struct CategoryRow: View {
    let title: String
    let symbol: String
    let detail: String?
    let value: String?
    var tint: Color = Palette.accent

    var body: some View {
        HStack(spacing: Space.m) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.hair) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(.primary)
                if let detail {
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Space.s)
            if let value {
                Text(value)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Home.cardLabel(title, value, detail))
        .accessibilityAddTraits(.isButton)
    }
}

/// A rounded group of rows on the grouped background, with an uppercase header, like an
/// inset-grouped list section, for screens laid out in a `ScrollView`.
struct CardSection<Content: View>: View {
    let title: String?
    var footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let title {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, Space.l)
                    .accessibilityAddTraits(.isHeader)
            }
            content
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Space.l)
            }
        }
    }
}

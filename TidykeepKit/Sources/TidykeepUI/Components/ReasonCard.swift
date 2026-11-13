import SwiftUI

/// Why something is suggested, what stays safe, and how to undo it. Every suggestion and every
/// receipt carries one; it is how Tidykeep keeps its promise that nothing changes without the
/// user and everything can be traced.
struct Reason: Hashable, Sendable {
    /// From the engine's own phrases only ("Sharpest and best faces.", "Same file, byte for byte.").
    var why: String
    /// Rule names with counts. Nil when nothing was protected: the card never says "0".
    var keptSafe: String?
    /// The destination and deadline, or "Can't be undone." Never empty.
    var undo: String
}

struct ReasonCard: View {
    let reason: Reason

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            line(Copy.Reason.why, symbol: "text.magnifyingglass", text: reason.why)
            if let keptSafe = reason.keptSafe {
                line(Copy.Reason.keptSafe, symbol: "lock.shield", text: keptSafe)
            }
            line(Copy.Reason.undo, symbol: "arrow.uturn.backward", text: reason.undo)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.l)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        // VoiceOver reads the why; the rest is under "More content", with the undo read
        // automatically because it matters most.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reason.why)
        .accessibilityCustomContent(Text(Copy.Reason.undo), Text(reason.undo), importance: .high)
        .accessibilityCustomContent(AccessibilityCustomContentKey(Text(Copy.Reason.keptSafe), id: "keptSafe"), reason.keptSafe.map { Text(verbatim: $0) })
        .accessibilityIdentifier("reason.card")
    }

    private func line(_ title: String, symbol: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Image(systemName: symbol)
                .foregroundStyle(Palette.accent)
                .frame(minWidth: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

import SwiftUI

/// One button in the bottom bar.
struct BarAction {
    var title: String
    var systemImage: String?
    var isEnabled = true
    var isBusy = false
    var hint: String?
    var action: () -> Void
}

/// The bottom bar: at most one secondary action and one prominent action, floating on glass
/// above the content. At accessibility text sizes the buttons stack, primary last, so neither
/// label is cut off.
struct ActionBar: View {
    var secondary: BarAction?
    var primary: BarAction?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: Space.m)) : AnyLayout(HStackLayout(spacing: Space.m))
        GlassEffectContainer(spacing: Space.m) {
            layout {
                if let secondary {
                    button(secondary)
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("actionbar.secondary")
                }
                if let primary {
                    button(primary, prominent: true)
                        .prominentGlassButton()
                        .accessibilityIdentifier("actionbar.primary")
                }
            }
        }
        .controlSize(.large)
        .tint(Palette.accent)
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.s)
    }

    private func button(_ item: BarAction, prominent: Bool = false) -> some View {
        Button(action: item.action) {
            HStack(spacing: Space.s) {
                if item.isBusy {
                    ProgressView().controlSize(.small)
                } else if let symbol = item.systemImage {
                    Image(systemName: symbol)
                }
                Text(item.title).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            }
            .font(.body.weight(prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? Palette.onAccent : Palette.accent)
            .frame(maxWidth: .infinity, minHeight: 30)
        }
        .disabled(!item.isEnabled || item.isBusy)
        .accessibilityHint(item.hint ?? "")
    }
}

extension View {
    /// Pins an `ActionBar` to the bottom, with the content scrolling under it.
    func actionBar(secondary: BarAction? = nil, primary: BarAction?) -> some View {
        bottomBar {
            if secondary != nil || primary != nil {
                ActionBar(secondary: secondary, primary: primary)
            }
        }
    }

    /// Pins `content` to the bottom on glass, with the content scrolling under it.
    @ViewBuilder
    func bottomBar(@ViewBuilder _ content: () -> some View) -> some View {
        #if os(iOS)
        safeAreaBar(edge: .bottom, content: content)
        #else
        // The Mac build only draws screens for review, and its snapshots can't capture the
        // scroll edge effect, which then hides the content.
        safeAreaInset(edge: .bottom, content: content)
        #endif
    }

    /// The prominent glass button style. The Mac build draws glass flat, so screens drawn for
    /// review show the tinted button iOS draws instead.
    @ViewBuilder
    func prominentGlassButton() -> some View {
        #if os(iOS)
        buttonStyle(.glassProminent)
        #else
        buttonStyle(MacProminentStyle())
        #endif
    }
}

#if !os(iOS)
/// A capsule filled with the tint, as iOS draws prominent glass. The Mac's own prominent style
/// draws grey in an offscreen window.
private struct MacProminentStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, Space.s)
            .padding(.horizontal, Space.l)
            .background(Capsule().fill(.tint))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}
#endif

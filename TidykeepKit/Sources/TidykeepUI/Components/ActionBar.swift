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
                        .buttonStyle(.glassProminent)
                        .accessibilityIdentifier("actionbar.primary")
                }
            }
        }
        .controlSize(.large)
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
        safeAreaBar(edge: .bottom) {
            if secondary != nil || primary != nil {
                ActionBar(secondary: secondary, primary: primary)
            }
        }
    }
}

import SwiftUI

/// First launch: what the app does, in four lines, then one button. Continue asks for
/// photos; files and contacts are asked for later, when the user opens them.
struct OnboardingView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dynamicTypeSize) private var typeSize
    @ViewState private var isContinuing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xxl) {
                VStack(alignment: .leading, spacing: Space.l) {
                    AppMark(size: typeSize.isAccessibilitySize ? 64 : 88)
                    Text(Copy.Onboarding.title)
                        .font(.largeTitle.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                .padding(.top, Space.xxl)

                VStack(alignment: .leading, spacing: Space.xl) {
                    ForEach(Copy.Onboarding.rows, id: \.text) { row in
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
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: Space.m) {
                Button {
                    isContinuing = true
                    Task { await state.finishOnboarding() }
                } label: {
                    Text(Copy.Onboarding.continue)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Palette.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.glassProminent)
                .tint(Palette.accent)
                .controlSize(.large)
                .disabled(isContinuing)
                .accessibilityIdentifier("onboarding.continue")
                Text("Free. No purchases, ads, tips or subscriptions.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Space.xl)
            .padding(.bottom, Space.m)
        }
        .background(Palette.groupedBackground)
        .interactiveDismissDisabled()
    }
}

/// The app's mark: a teal tile with a sparkle over a stack, like the icon.
struct AppMark: View {
    var size: CGFloat = 88

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.08, green: 0.55, blue: 0.6), Color(red: 0.03, green: 0.36, blue: 0.42)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Full screen on iPhone; a sheet on the Mac, where the render harness runs.
    @ViewBuilder
    func onboarding(isPresented: Binding<Bool>) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented) { OnboardingView() }
        #else
        sheet(isPresented: isPresented) { OnboardingView().frame(minWidth: 400, minHeight: 600) }
        #endif
    }
}

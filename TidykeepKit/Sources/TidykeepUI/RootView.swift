import TidykeepCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The app's whole UI. The app target creates the model and puts it in the environment.
public struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        Group {
            switch model.phase {
            case .launching: ProgressView()
            case .needsAccess: OnboardingView()
            case .denied: AccessDeniedView()
            case .ready: LibraryView()
            }
        }
        .task { await model.start() }
        .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(to: phase) }
        .overlay(alignment: .top) { NoticeBanner() }
    }
}

struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Keep the best shot")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("You take five photos to get one good one. \(AppInfo.name) finds those runs and picks the keeper, so the rest don't fill up your phone.")
                        .font(.title3)
                }
                VStack(alignment: .leading, spacing: 20) {
                    Feature(symbol: "square.stack.3d.down.right", title: "Finds near-identical photos",
                            detail: "Shots of the same moment, taken seconds apart.")
                    Feature(symbol: "star", title: "Picks the best one",
                            detail: "Sharpest, best faces, best overall look.")
                    Feature(symbol: "hand.raised", title: "You decide",
                            detail: "Nothing is removed until you say so. Favorites and edited photos are always kept.")
                    Feature(symbol: "lock.shield", title: "Stays on your phone",
                            detail: "No account, no ads, no internet. Photos are analyzed on the device and never leave it.")
                }
            }
            .padding(24)
            .frame(maxWidth: 600, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                Task { await model.requestAccess() }
            } label: {
                // App Review asks that this not say "Allow": the system prompt comes next.
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding()
            .background(.bar)
        }
    }

    struct Feature: View {
        let symbol: String
        let title: String
        let detail: String
        @ScaledMetric(relativeTo: .title2) private var iconWidth: CGFloat = 32

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: iconWidth)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

struct AccessDeniedView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("\(AppInfo.name) can't see your photos")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text("To find similar shots, allow access to your photos in Settings. Everything stays on your phone.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                #if os(iOS)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                #endif
            }
            .padding(32)
            .frame(maxWidth: 500)
            .frame(maxWidth: .infinity)
        }
    }
}

/// A short-lived banner for `AppModel.notice`. VoiceOver already heard it as an announcement.
struct NoticeBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let notice = model.notice {
            Text(notice)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 4, y: 2)
                .padding(.top, 8)
                .padding(.horizontal)
                .accessibilityHidden(true)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(4))
                    if model.notice == notice { withAnimation { model.clearNotice() } }
                }
        }
    }
}

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The few iPhone-only calls, in one place, with Mac stand-ins so the package builds and
/// renders on a Mac. They first compile for iOS in CI.
@MainActor
enum Platform {
    /// Opens Tidykeep's page in the Settings app (Photos and Contacts access).
    static func openSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }

    static var canOpenSettings: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    /// Banners stay until dismissed for people who can't catch them in time.
    static var assistiveTechRunning: Bool {
        #if os(iOS)
        UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
        #else
        false
        #endif
    }
}

extension View {
    @ViewBuilder
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Inset-grouped on iPhone; the Mac's closest match elsewhere.
    @ViewBuilder
    func groupedList() -> some View {
        #if os(iOS)
        listStyle(.insetGrouped)
        #else
        listStyle(.inset)
        #endif
    }

    /// The tab bar shrinks while reading a long list (iPhone only).
    @ViewBuilder
    func minimizingTabBar() -> some View {
        #if os(iOS)
        tabBarMinimizeBehavior(.onScrollDown)
        #else
        self
        #endif
    }
}

extension ToolbarItemPlacement {
    /// Top trailing on iPhone.
    static var topTrailing: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }
}

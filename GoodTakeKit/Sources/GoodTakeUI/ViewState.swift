import SwiftUI

/// SwiftUI's `State` property wrapper under a second name.
///
/// In the 2026 SDKs `@State` resolves to a compiler-plugin macro whose plugin ships only with
/// Xcode, so the package wouldn't build with the command-line tools alone. The property wrapper
/// behaves the same and builds everywhere.
typealias ViewState = SwiftUI.State

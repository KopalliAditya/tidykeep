import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Spacing on a 4-point grid. System margins everywhere else.
enum Space {
    static let hair: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum Radius {
    static let card: CGFloat = 20
    static let inner: CGFloat = 14
    static let preview: CGFloat = 16
    static let tile: CGFloat = 4
}

/// The app's colours: system colours plus one accent, Ledger teal. The photos supply the rest.
///
/// The accent is defined here as well as in the asset catalog so that previews rendered on a
/// Mac and the app agree. Each colour has light, dark and Increased Contrast variants.
enum Palette {
    static let accent = Color.dynamic(light: 0x0B6E78, dark: 0x5CC8D2, lightHigh: 0x05545E, darkHigh: 0x80D6DB)
    /// Secondary text. iOS's own secondary label is 3.3:1 on the grouped background, under the
    /// 4.5:1 small text needs. This grey is 5.6:1 or more on every background the app uses
    /// for text in light mode, and 5.0:1 or more in dark mode.
    static let secondaryText = Color.dynamic(light: 0x5E5E63, dark: 0xA1A1A8, lightHigh: 0x48484D, darkHigh: 0xC2C2C8)
    /// Text and symbols on an accent fill. White on the dark-mode teal is too faint, so dark
    /// mode uses a dark ink instead.
    static let onAccent = Color.dynamic(light: 0xFFFFFF, dark: 0x0A2A2E, lightHigh: 0xFFFFFF, darkHigh: 0x000000)
    static let remove = Color.dynamic(light: 0xFF3B30, dark: 0xFF453A, lightHigh: 0xD70015, darkHigh: 0xFF6961)
    static let closeCall = Color.orange
    static let favorite = Color.pink

    #if canImport(UIKit)
    static let groupedBackground = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let fill = Color(uiColor: .tertiarySystemFill)
    static let separator = Color(uiColor: .separator)
    #else
    // The iOS grouped colours, so screens drawn on a Mac for review look like the phone.
    static let groupedBackground = Color.dynamic(light: 0xF2F2F7, dark: 0x000000, lightHigh: 0xEBEBF0, darkHigh: 0x000000)
    static let card = Color.dynamic(light: 0xFFFFFF, dark: 0x1C1C1E, lightHigh: 0xFFFFFF, darkHigh: 0x242426)
    static let fill = Color(nsColor: .tertiarySystemFill)
    static let separator = Color(nsColor: .separatorColor)
    #endif
}

extension Color {
    /// A colour that follows light/dark mode and Increased Contrast.
    static func dynamic(light: UInt32, dark: UInt32, lightHigh: UInt32, darkHigh: UInt32) -> Color {
        #if canImport(UIKit)
        Color(uiColor: UIColor { traits in
            let high = traits.accessibilityContrast == .high
            let isDark = traits.userInterfaceStyle == .dark
            return UIColor(rgb: isDark ? (high ? darkHigh : dark) : (high ? lightHigh : light))
        })
        #else
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            switch match {
            case .darkAqua: return NSColor(rgb: dark)
            case .accessibilityHighContrastAqua: return NSColor(rgb: lightHigh)
            case .accessibilityHighContrastDarkAqua: return NSColor(rgb: darkHigh)
            default: return NSColor(rgb: light)
            }
        })
        #endif
    }
}

#if canImport(UIKit)
extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
#else
extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
#endif

/// System animations only, and none under Reduce Motion.
enum Motion {
    static func standard(_ reduceMotion: Bool) -> Animation? { reduceMotion ? nil : .smooth(duration: 0.25) }
}

/// The haptics switch in Rules. Every haptic is paired with something on screen, never alone.
enum Haptics {
    static let key = "haptics"
}

extension View {
    /// A haptic for a change, unless the user turned haptics off.
    func feedback<T: Equatable>(_ feedback: SensoryFeedback, trigger: T) -> some View {
        modifier(FeedbackModifier(feedback: feedback, trigger: trigger))
    }
}

private struct FeedbackModifier<T: Equatable>: ViewModifier {
    let feedback: SensoryFeedback
    let trigger: T
    @AppStorage(Haptics.key) private var hapticsOn = true

    func body(content: Content) -> some View {
        content.sensoryFeedback(trigger: trigger) { _, _ in hapticsOn ? feedback : nil }
    }
}

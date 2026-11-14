import Foundation
import Observation
import TidykeepCore

/// What the user chose in Rules. Saved in `UserDefaults`; changes take effect the next time
/// the app checks.
@MainActor
@Observable
public final class Preferences {
    public var scope: ScanScope { didSet { defaults.set(scope.rawValue, forKey: Keys.scope) } }
    public var sensitivity: Sensitivity { didSet { defaults.set(sensitivity.rawValue, forKey: Keys.sensitivity) } }
    public var rules: ProtectionRules { didSet { save(rules, Keys.rules) } }
    /// Big Videos lists videos at least this long.
    public var videoMinimum: TimeInterval { didSet { defaults.set(videoMinimum, forKey: Keys.videoMinimum) } }
    /// Large Files lists files at least this big.
    public var largeFileMinimum: Int64 { didSet { defaults.set(largeFileMinimum, forKey: Keys.largeFileMinimum) } }
    public var onboarded: Bool { didSet { defaults.set(onboarded, forKey: Keys.onboarded) } }
    /// Rules › My Card: when on, the user's own card is left out of duplicate matches. Either
    /// way, My Card is only ever the card that stays in a merge.
    public var protectsMyCard: Bool { didSet { defaults.set(protectsMyCard, forKey: Keys.protectsMyCard) } }

    public static let videoMinimums: [TimeInterval] = [60, 180, 300, 600]
    public static let largeFileMinimums: [Int64] = [50, 100, 250, 500, 1_000].map { $0 * 1_000_000 }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        scope = defaults.string(forKey: Keys.scope).flatMap(ScanScope.init) ?? .last12Months
        sensitivity = defaults.string(forKey: Keys.sensitivity).flatMap(Sensitivity.init) ?? .balanced
        rules = defaults.data(forKey: Keys.rules).flatMap { try? JSONDecoder().decode(ProtectionRules.self, from: $0) } ?? ProtectionRules()
        let video = defaults.double(forKey: Keys.videoMinimum)
        videoMinimum = video > 0 ? video : 60
        let large = Int64(defaults.integer(forKey: Keys.largeFileMinimum))
        largeFileMinimum = large > 0 ? large : 100_000_000
        onboarded = defaults.bool(forKey: Keys.onboarded)
        protectsMyCard = defaults.object(forKey: Keys.protectsMyCard) as? Bool ?? true
    }

    enum Keys {
        static let scope = "scanScope"
        static let sensitivity = "sensitivity"
        static let rules = "rules"
        static let videoMinimum = "videoMinimum"
        static let largeFileMinimum = "largeFileMinimum"
        static let onboarded = "onboarded"
        static let protectsMyCard = "protectsMyCard"
        static let all = [scope, sensitivity, rules, videoMinimum, largeFileMinimum, onboarded, protectsMyCard, Haptics.key]
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }
}

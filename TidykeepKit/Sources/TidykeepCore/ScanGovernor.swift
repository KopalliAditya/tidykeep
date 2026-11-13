import Foundation

/// Device state the scanner adapts to.
public struct DeviceConditions: Sendable, Equatable {
    public var thermal: ProcessInfo.ThermalState
    public var lowPowerMode: Bool

    public init(thermal: ProcessInfo.ThermalState, lowPowerMode: Bool) {
        self.thermal = thermal
        self.lowPowerMode = lowPowerMode
    }

    public static func current() -> DeviceConditions {
        DeviceConditions(thermal: ProcessInfo.processInfo.thermalState, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}

/// How many photos to analyze at once. Backs off as the phone heats up and stops at
/// `.critical`, so a long first scan never makes the phone hot in someone's hand.
public enum ScanGovernor {
    public static let maxConcurrency = 3

    public static func concurrency(for conditions: DeviceConditions, max: Int = maxConcurrency) -> Int {
        let byHeat: Int = switch conditions.thermal {
        case .nominal: max
        case .fair: Swift.max(1, max - 1)
        case .serious: 1
        case .critical: 0
        @unknown default: 1
        }
        return conditions.lowPowerMode ? min(byHeat, 1) : byHeat
    }
}

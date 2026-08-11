import Foundation

/// Pure derivation of BLE scan/advertise duty-cycle parameters from device
/// state. No CoreBluetooth / UIKit import anywhere in this file — battery
/// percent, charging state, app foreground/background state, and whether
/// any peer is currently connected are passed in as plain values, so
/// ``resolve(_:)`` is unit-testable without a device or simulator. The
/// framework glue that actually reads the battery level, hooks scene
/// lifecycle notifications, and feeds a fresh ``Inputs`` value on every
/// relevant transition lives OUTSIDE this type, in the app-target radio
/// runtime.
public enum MeshRadioSchedule {

    public struct Inputs: Equatable {
        public let batteryPercent: Int
        public let isCharging: Bool
        public let isAppForeground: Bool
        public let hasConnectedPeer: Bool

        public init(batteryPercent: Int, isCharging: Bool, isAppForeground: Bool, hasConnectedPeer: Bool) {
            precondition((0...100).contains(batteryPercent), "batteryPercent must be 0...100, got \(batteryPercent)")
            self.batteryPercent = batteryPercent
            self.isCharging = isCharging
            self.isAppForeground = isAppForeground
            self.hasConnectedPeer = hasConnectedPeer
        }
    }

    public enum TxPower: Equatable { case ultraLow, low, medium, high }

    public struct Profile: Equatable {
        public let name: String
        public let scanWindowMs: Int64
        public let scanIntervalMs: Int64
        public let advertiseIntervalMs: Int64
        public let txPower: TxPower
        public let maxConcurrentConnections: Int
    }

    public static let lowBatteryThreshold = 15

    /// Priority order (first match wins), roughly cheapest-first inputs to
    /// check but MOST-responsive-outcome-first in intent:
    ///  1. Foreground + plugged in -> go as responsive as this transport
    ///     ever gets.
    ///  2. Foreground on battery -> still responsive, slightly gentler.
    ///  3. Backgrounded but a peer is actively connected -> keep that link
    ///     alive at a moderate cadence rather than dropping to idle.
    ///  4. Backgrounded + plugged in -> can afford a slower background poll
    ///     without hurting anyone's battery.
    ///  5. Backgrounded + low battery -> as cheap as the mesh gets while
    ///     still nominally participating.
    ///  6. Otherwise -> ordinary idle background cadence.
    public static func resolve(_ inputs: Inputs) -> Profile {
        switch true {
        case inputs.isAppForeground && inputs.isCharging: return activeForegroundPlugged
        case inputs.isAppForeground: return activeForegroundBattery
        case inputs.hasConnectedPeer: return backgroundWithPeer
        case inputs.isCharging: return backgroundPlugged
        case inputs.batteryPercent <= lowBatteryThreshold: return backgroundLowBattery
        default: return backgroundIdle
        }
    }

    public static let activeForegroundPlugged = Profile(
        name: "active_foreground_plugged",
        scanWindowMs: 5_000, scanIntervalMs: 6_000, advertiseIntervalMs: 500,
        txPower: .high, maxConcurrentConnections: 6
    )
    public static let activeForegroundBattery = Profile(
        name: "active_foreground_battery",
        scanWindowMs: 3_000, scanIntervalMs: 8_000, advertiseIntervalMs: 1_000,
        txPower: .medium, maxConcurrentConnections: 4
    )
    public static let backgroundWithPeer = Profile(
        name: "background_with_peer",
        scanWindowMs: 2_000, scanIntervalMs: 15_000, advertiseIntervalMs: 3_000,
        txPower: .low, maxConcurrentConnections: 2
    )
    public static let backgroundPlugged = Profile(
        name: "background_plugged",
        scanWindowMs: 2_000, scanIntervalMs: 30_000, advertiseIntervalMs: 5_000,
        txPower: .low, maxConcurrentConnections: 2
    )
    public static let backgroundLowBattery = Profile(
        name: "background_low_battery",
        scanWindowMs: 1_000, scanIntervalMs: 120_000, advertiseIntervalMs: 15_000,
        txPower: .ultraLow, maxConcurrentConnections: 1
    )
    public static let backgroundIdle = Profile(
        name: "background_idle",
        scanWindowMs: 1_500, scanIntervalMs: 60_000, advertiseIntervalMs: 10_000,
        txPower: .ultraLow, maxConcurrentConnections: 1
    )
}

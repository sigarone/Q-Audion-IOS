import Foundation

public struct DeviceManagementViewModel: ViewModelProtocol {

    public struct Device: Equatable, Sendable, Hashable {
        public let deviceId: String
        public let deviceName: String
        public let platform: Platform
        public let linkedAt: Date
        public let lastSeen: Date
        public let isCurrentDevice: Bool
        public let canRevoke: Bool

        public enum Platform: String, Sendable {
            case iOS, android, desktop, unknown
        }

        public init(deviceId: String, deviceName: String, platform: Platform,
                    linkedAt: Date, lastSeen: Date,
                    isCurrentDevice: Bool, canRevoke: Bool) {
            self.deviceId = deviceId
            self.deviceName = deviceName
            self.platform = platform
            self.linkedAt = linkedAt
            self.lastSeen = lastSeen
            self.isCurrentDevice = isCurrentDevice
            self.canRevoke = canRevoke
        }
    }

    /// Sorted with current device first, then others by `lastSeen` descending.
    public let devices: [Device]

    public init(devices: [Device]) {
        self.devices = devices
    }

    public static let mock = DeviceManagementViewModel(devices: [
        Device(
            deviceId: "device-iphone-13-pavel",
            deviceName: "Pavel's iPhone 13",
            platform: .iOS,
            linkedAt: Date(timeIntervalSince1970: 1_740_000_000),
            lastSeen: Date(timeIntervalSince1970: 1_745_000_000),
            isCurrentDevice: true,
            canRevoke: false
        ),
        Device(
            deviceId: "device-pixel-7",
            deviceName: "Pixel 7",
            platform: .android,
            linkedAt: Date(timeIntervalSince1970: 1_741_000_000),
            lastSeen: Date(timeIntervalSince1970: 1_744_950_000),
            isCurrentDevice: false,
            canRevoke: true
        ),
        Device(
            deviceId: "device-macbook-pro",
            deviceName: "Pavel's MacBook Pro",
            platform: .desktop,
            linkedAt: Date(timeIntervalSince1970: 1_742_000_000),
            lastSeen: Date(timeIntervalSince1970: 1_744_900_000),
            isCurrentDevice: false,
            canRevoke: true
        )
    ])
}

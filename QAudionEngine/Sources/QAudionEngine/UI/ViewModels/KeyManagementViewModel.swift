import Foundation

public struct KeyManagementViewModel: ViewModelProtocol, Equatable, Sendable {

    public struct LinkedDevice: Equatable, Sendable, Hashable {
        public let deviceId: String
        public let deviceName: String
        public let lastSeen: Date
        public let isCurrentDevice: Bool

        public init(deviceId: String, deviceName: String, lastSeen: Date, isCurrentDevice: Bool) {
            self.deviceId = deviceId
            self.deviceName = deviceName
            self.lastSeen = lastSeen
            self.isCurrentDevice = isCurrentDevice
        }
    }

    public let userId: String
    /// `xxxx.xxxx.xxxx.xxxx` per spec §5.1.
    public let fingerprint: String
    public let linkedDevices: [LinkedDevice]
    /// Server-side last-rotation timestamp (nil if never rotated post-enrol).
    public let lastKeyRotation: Date?

    public init(userId: String, fingerprint: String, linkedDevices: [LinkedDevice], lastKeyRotation: Date?) {
        self.userId = userId
        self.fingerprint = fingerprint
        self.linkedDevices = linkedDevices
        self.lastKeyRotation = lastKeyRotation
    }

    public static let mock = KeyManagementViewModel(
        userId: "user-aabbccdd-1122-3344-5566-778899aabbcc",
        fingerprint: Fingerprint.format(pubkey: Data(repeating: 0x42, count: 32)),
        linkedDevices: [
            LinkedDevice(
                deviceId: "device-iphone-13-pavel",
                deviceName: "Pavel's iPhone 13",
                lastSeen: Date(timeIntervalSince1970: 1_745_000_000),
                isCurrentDevice: true
            ),
            LinkedDevice(
                deviceId: "device-pixel-7",
                deviceName: "Pixel 7 (Android)",
                lastSeen: Date(timeIntervalSince1970: 1_744_950_000),
                isCurrentDevice: false
            )
        ],
        lastKeyRotation: Date(timeIntervalSince1970: 1_744_000_000)
    )
}

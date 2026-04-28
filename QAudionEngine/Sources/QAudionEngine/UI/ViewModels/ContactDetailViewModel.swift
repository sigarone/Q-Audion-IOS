import Foundation

public struct ContactDetailViewModel: ViewModelProtocol {

    public enum TrustLevel: Sendable, Equatable {
        case unverified
        case sasVerified       // SAS confirmed by user during a call
        case nfcPaired         // PSK established via NFC
        case both              // sasVerified + nfcPaired
    }

    public let userId: String
    public let displayName: String
    public let phoneHash: String  // §5.1 64 lowercase hex
    public let fingerprint: String  // §5.1 4-group hex
    public let avatarUrl: URL?
    public let trustLevel: TrustLevel
    public let isBlocked: Bool
    public let lastSeen: Date?
    public let recentCallCount: Int
    public let unreadMessageCount: Int

    public init(userId: String, displayName: String, phoneHash: String,
                fingerprint: String, avatarUrl: URL?, trustLevel: TrustLevel,
                isBlocked: Bool, lastSeen: Date?, recentCallCount: Int,
                unreadMessageCount: Int) {
        self.userId = userId
        self.displayName = displayName
        self.phoneHash = phoneHash
        self.fingerprint = fingerprint
        self.avatarUrl = avatarUrl
        self.trustLevel = trustLevel
        self.isBlocked = isBlocked
        self.lastSeen = lastSeen
        self.recentCallCount = recentCallCount
        self.unreadMessageCount = unreadMessageCount
    }

    public static let mock = ContactDetailViewModel(
        userId: "user-aabbccdd-1122-3344-5566-778899aabbcc",
        displayName: "Alice (Pixel 7)",
        phoneHash: String(repeating: "ab", count: 32),
        fingerprint: Fingerprint.format(pubkey: Data(repeating: 0x44, count: 32)),
        avatarUrl: nil,
        trustLevel: .sasVerified,
        isBlocked: false,
        lastSeen: Date(timeIntervalSince1970: 1_745_000_000),
        recentCallCount: 3,
        unreadMessageCount: 0
    )
}

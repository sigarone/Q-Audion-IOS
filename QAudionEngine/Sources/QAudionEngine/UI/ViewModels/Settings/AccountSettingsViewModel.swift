import Foundation

public struct AccountSettingsViewModel: ViewModelProtocol {
    public let userId: String
    public let phoneHash: String  // §5.1: 64 lowercase hex chars
    public let displayName: String?
    public let statusMessage: String?
    public let avatarUrl: URL?
    public let dialExtension: String?  // server-issued dial-by-extension number

    public init(userId: String, phoneHash: String, displayName: String?,
                statusMessage: String?, avatarUrl: URL?, dialExtension: String?) {
        self.userId = userId
        self.phoneHash = phoneHash
        self.displayName = displayName
        self.statusMessage = statusMessage
        self.avatarUrl = avatarUrl
        self.dialExtension = dialExtension
    }

    public static let mock = AccountSettingsViewModel(
        userId: "user-aabbccdd-1122-3344-5566-778899aabbcc",
        phoneHash: String(repeating: "ab", count: 32),  // 64 hex chars
        displayName: "Pavel",
        statusMessage: "Working remotely",
        avatarUrl: nil,
        dialExtension: "4242"
    )
}

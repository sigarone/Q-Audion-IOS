import Foundation

public struct PrivacySettingsViewModel: ViewModelProtocol, Codable {
    public let readReceiptsEnabled: Bool
    public let typingIndicatorEnabled: Bool
    public let presenceVisibleToContacts: Bool
    /// 0 = off, otherwise seconds until message auto-deletes. Allowed
    /// values: 0, 60 (1m), 3600 (1h), 86400 (1d), 604800 (7d).
    public let disappearingMessagesDuration: TimeInterval
    public let blockedUserIds: [String]
    public let torEnabled: Bool

    public init(readReceiptsEnabled: Bool, typingIndicatorEnabled: Bool,
                presenceVisibleToContacts: Bool, disappearingMessagesDuration: TimeInterval,
                blockedUserIds: [String], torEnabled: Bool) {
        self.readReceiptsEnabled = readReceiptsEnabled
        self.typingIndicatorEnabled = typingIndicatorEnabled
        self.presenceVisibleToContacts = presenceVisibleToContacts
        self.disappearingMessagesDuration = disappearingMessagesDuration
        self.blockedUserIds = blockedUserIds
        self.torEnabled = torEnabled
    }

    public static let mock = PrivacySettingsViewModel(
        readReceiptsEnabled: true,
        typingIndicatorEnabled: true,
        presenceVisibleToContacts: true,
        disappearingMessagesDuration: 0,
        blockedUserIds: ["user-blocked-1", "user-blocked-2"],
        torEnabled: false
    )
}

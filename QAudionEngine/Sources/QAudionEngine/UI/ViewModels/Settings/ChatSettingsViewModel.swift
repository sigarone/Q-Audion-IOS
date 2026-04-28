import Foundation

/// Drives Settings → Chat screen.
///
/// Exposes read-receipts, typing indicators, and whether message content is
/// previewed inside push notifications.  The mock disables notification
/// previews to reflect a security-conscious default: the app targets users
/// who care about metadata leakage, so showing message content on the lock
/// screen is off by default.
public struct ChatSettingsViewModel: ViewModelProtocol, Codable {
    public let readReceiptsEnabled: Bool
    public let typingIndicatorsEnabled: Bool
    public let messagePreviewInNotifications: Bool

    public init(readReceiptsEnabled: Bool, typingIndicatorsEnabled: Bool,
                messagePreviewInNotifications: Bool) {
        self.readReceiptsEnabled = readReceiptsEnabled
        self.typingIndicatorsEnabled = typingIndicatorsEnabled
        self.messagePreviewInNotifications = messagePreviewInNotifications
    }

    public static let mock = ChatSettingsViewModel(
        readReceiptsEnabled: true,
        typingIndicatorsEnabled: true,
        messagePreviewInNotifications: false
    )
}

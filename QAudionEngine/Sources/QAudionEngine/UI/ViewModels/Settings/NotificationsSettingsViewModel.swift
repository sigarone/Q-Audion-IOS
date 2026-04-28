import Foundation

/// Drives Settings → Notifications screen.
///
/// Exposes ringtone selection, in-app sound / vibration toggles, a quiet-hours
/// window (nested value type), and a count of muted contacts.  Quiet hours
/// default to 22:00–08:00 but are disabled in the mock, letting the UI show
/// the controls without silently muting a first-run tester's device.
public struct NotificationsSettingsViewModel: ViewModelProtocol, Codable {

    /// A time window during which incoming-call and message sounds are muted.
    public struct QuietHours: Equatable, Sendable, Codable {
        public let startHour: Int      // 0...23
        public let startMinute: Int    // 0...59
        public let endHour: Int
        public let endMinute: Int
        public let enabled: Bool

        public init(startHour: Int, startMinute: Int, endHour: Int, endMinute: Int, enabled: Bool) {
            self.startHour = startHour
            self.startMinute = startMinute
            self.endHour = endHour
            self.endMinute = endMinute
            self.enabled = enabled
        }
    }

    public let ringtoneId: String
    public let inAppSoundEnabled: Bool
    public let vibrationEnabled: Bool
    public let quietHours: QuietHours
    public let mutedContactsCount: Int

    public init(ringtoneId: String, inAppSoundEnabled: Bool, vibrationEnabled: Bool,
                quietHours: QuietHours, mutedContactsCount: Int) {
        self.ringtoneId = ringtoneId
        self.inAppSoundEnabled = inAppSoundEnabled
        self.vibrationEnabled = vibrationEnabled
        self.quietHours = quietHours
        self.mutedContactsCount = mutedContactsCount
    }

    public static let mock = NotificationsSettingsViewModel(
        ringtoneId: "qaudion-default",
        inAppSoundEnabled: true,
        vibrationEnabled: true,
        quietHours: QuietHours(startHour: 22, startMinute: 0, endHour: 8, endMinute: 0, enabled: false),
        mutedContactsCount: 0
    )
}

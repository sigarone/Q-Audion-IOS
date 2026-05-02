import Foundation

/// W404 — single source of truth for privacy / notification gates.
///
/// Before W404, the app had two parallel ViewModel + SettingsStore
/// paths (PrivacySettingsScreen + ChatSettingsScreen) that each
/// persisted boolean state for "read receipts", "typing indicator",
/// "presence visible to contacts", "message preview in notifications".
/// Neither path was actually consulted by ChatContainer.sendRead-
/// Receipts / sendTypingIndicator / presence service — they shipped
/// unconditionally. Result: the toggles persisted but did nothing.
///
/// W404 collapses both paths onto a single canonical UserDefaults
/// key per setting and adds a thin `PrivacyGate` reader so the
/// production code path can check the flag with one line. The
/// SettingsStore-mediated ViewModels become read-only mirrors of
/// the same UserDefaults keys (kept for back-compat with the View
/// init that loads them).
///
/// **Defaults match prior production behavior** so users who never
/// opened Settings observe no behavior change.
public enum PrivacyGate {

    // MARK: - Canonical UserDefaults keys

    public static let keyReadReceipts        = "qaudion.privacy.read_receipts_enabled"
    public static let keyTypingIndicator     = "qaudion.privacy.typing_indicator_enabled"
    public static let keyPresence            = "qaudion.privacy.presence_visible_to_contacts"
    public static let keyDisappearingSeconds = "qaudion.privacy.disappearing_seconds"
    public static let keyTorEnabled          = "qaudion.privacy.tor_enabled"
    public static let keyMessagePreview      = "qaudion.privacy.message_preview_in_notifications"

    // MARK: - Reads (with safe defaults)

    /// Default ON — current shipped behavior emits read receipts.
    public static var readReceiptsEnabled: Bool {
        return readBoolWithDefault(keyReadReceipts, default: true)
    }

    /// Default ON.
    public static var typingIndicatorEnabled: Bool {
        return readBoolWithDefault(keyTypingIndicator, default: true)
    }

    /// Default ON. (presence service already flips this; the UI
    /// previously set the same flag through the SettingsStore — we
    /// now centralise the reader here.)
    public static var presenceVisibleToContacts: Bool {
        return readBoolWithDefault(keyPresence, default: true)
    }

    /// Default 0 (= disabled). Other values: TTL seconds applied to
    /// outbound message metadata. The receiver's UI auto-deletes the
    /// row at `sentAt + disappearingSeconds`.
    public static var disappearingSeconds: TimeInterval {
        let v = UserDefaults.standard.double(forKey: keyDisappearingSeconds)
        return max(0, v)
    }

    /// Default OFF. Tor is "preferred" hint — the network layer is
    /// expected to use a SOCKS proxy when ON. iOS doesn't support
    /// system-wide SOCKS; the flag currently surfaces as a UX warning.
    public static var torEnabled: Bool {
        return readBoolWithDefault(keyTorEnabled, default: false)
    }

    /// Default true — banner body shows full message preview.
    public static var messagePreviewInNotifications: Bool {
        return readBoolWithDefault(keyMessagePreview, default: true)
    }

    // MARK: - Writes

    public static func setReadReceiptsEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: keyReadReceipts)
    }
    public static func setTypingIndicatorEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: keyTypingIndicator)
    }
    public static func setPresenceVisibleToContacts(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: keyPresence)
    }
    public static func setDisappearingSeconds(_ value: TimeInterval) {
        UserDefaults.standard.set(value, forKey: keyDisappearingSeconds)
    }
    public static func setTorEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: keyTorEnabled)
    }
    public static func setMessagePreviewInNotifications(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: keyMessagePreview)
    }

    // MARK: - Helpers

    /// `UserDefaults.bool(forKey:)` returns false on missing key,
    /// erasing the difference between "user toggled off" and "never
    /// touched". Use object-presence to reapply the documented default.
    private static func readBoolWithDefault(_ key: String, default fallback: Bool) -> Bool {
        if let raw = UserDefaults.standard.object(forKey: key) as? Bool {
            return raw
        }
        return fallback
    }
}

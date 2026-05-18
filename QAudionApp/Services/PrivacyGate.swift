import Foundation
import Security

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
    public static let keyDisappearingSeconds  = "qaudion.privacy.disappearing_seconds"
    public static let keyTorEnabled           = "qaudion.privacy.tor_enabled"
    public static let keyMessagePreview       = "qaudion.privacy.message_preview_in_notifications"
    /// W441 — device security
    public static let keyScreenshotProtection = "qaudion.privacy.screenshot_protection"
    public static let keyAppLockEnabled       = "qaudion.privacy.app_lock_enabled"
    /// Grace period before the lock triggers, in milliseconds. Default 60 000 (1 min).
    public static let keyAppLockTimeoutMs     = "qaudion.privacy.app_lock_timeout_ms"

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

    /// Default OFF. When on, the app detects screenshots and applies
    /// UIKit secure layer to block OS-level screen capture.
    /// SECURITY M-28: Keychain-backed (security-affecting flag).
    public static var screenshotProtectionEnabled: Bool {
        return readSecureBoolWithDefault(keyScreenshotProtection, default: false)
    }

    /// Default OFF. Prompts biometric/passcode after the grace period
    /// elapses while in background.
    /// SECURITY M-28: Keychain-backed (security-affecting flag).
    public static var appLockEnabled: Bool {
        return readSecureBoolWithDefault(keyAppLockEnabled, default: false)
    }

    /// Background grace period before lock triggers, in milliseconds.
    /// Default 60 000 (1 min).
    /// SECURITY M-28: Keychain-backed (security-affecting flag).
    public static var appLockTimeoutMs: Int {
        let v = readSecureInt(keyAppLockTimeoutMs)
        return v > 0 ? v : 60_000
    }

    // MARK: - Writes

    public static func setReadReceiptsEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: keyReadReceipts)
        RTLog.info("settings", "PrivacyGate.readReceipts=\(value)")
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
        RTLog.info("settings", "PrivacyGate.tor=\(value)")
    }
    public static func setMessagePreviewInNotifications(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: keyMessagePreview)
    }
    public static func setScreenshotProtectionEnabled(_ value: Bool) {
        // SECURITY M-28: Keychain-backed.
        writeSecureBool(keyScreenshotProtection, value)
        // SECURITY L-8: audit-parity log line.
        let line: String = "PrivacyGate.screenshotProtection=" + String(value)
        RTLog.info("settings", line)
    }
    public static func setAppLockEnabled(_ value: Bool) {
        // SECURITY M-28: Keychain-backed.
        writeSecureBool(keyAppLockEnabled, value)
        // SECURITY L-8: audit-parity log line.
        let line: String = "PrivacyGate.appLock=" + String(value)
        RTLog.info("settings", line)
    }
    public static func setAppLockTimeoutMs(_ value: Int) {
        // SECURITY M-28: Keychain-backed.
        writeSecureInt(keyAppLockTimeoutMs, value)
        // SECURITY L-8: audit-parity log line.
        let line: String = "PrivacyGate.appLockTimeoutMs=" + String(value)
        RTLog.info("settings", line)
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

    // MARK: - SECURITY M-28 Keychain-backed security flags
    //
    // Only the security-affecting flags (appLockEnabled,
    // appLockTimeoutMs, screenshotProtection) are stored here. The
    // non-sensitive preferences (read receipts, typing indicator,
    // presence, message preview, etc.) intentionally remain in
    // UserDefaults — they are UX, not a security boundary.

    private static let keychainService = "com.qaudion.privacy"

    /// Bool read with one-time UserDefaults→Keychain migration.
    private static func readSecureBoolWithDefault(_ key: String, default fallback: Bool) -> Bool {
        if let v = keychainGet(key) {
            return v.first.map { $0 != 0 } ?? fallback
        }
        if let legacy = UserDefaults.standard.object(forKey: key) as? Bool {
            keychainSet(key, Data([legacy ? 1 : 0]))
            UserDefaults.standard.removeObject(forKey: key)
            return legacy
        }
        return fallback
    }

    private static func writeSecureBool(_ key: String, _ value: Bool) {
        keychainSet(key, Data([value ? 1 : 0]))
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Int read with one-time UserDefaults→Keychain migration.
    /// Returns 0 when absent (callers apply their own default).
    private static func readSecureInt(_ key: String) -> Int {
        if let v = keychainGet(key) {
            return Self.intFromData(v)
        }
        let legacy = UserDefaults.standard.integer(forKey: key)
        if legacy > 0 {
            writeSecureInt(key, legacy)
            UserDefaults.standard.removeObject(forKey: key)
            return legacy
        }
        return 0
    }

    private static func writeSecureInt(_ key: String, _ value: Int) {
        var v = Int64(value).littleEndian
        let data = withUnsafeBytes(of: &v) { Data($0) }
        keychainSet(key, data)
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func intFromData(_ data: Data) -> Int {
        guard data.count == 8 else { return 0 }
        var raw: Int64 = 0
        _ = withUnsafeMutableBytes(of: &raw) { data.copyBytes(to: $0) }
        return Int(Int64(littleEndian: raw))
    }

    /// SECURITY F-2: atomic write. The old `SecItemDelete` then
    /// `SecItemAdd` (status ignored) could lose the
    /// `AfterFirstUnlockThisDeviceOnly` accessibility class if the add
    /// silently failed (e.g. `errSecInteractionNotAllowed` while the
    /// device is locked), silently downgrading these security-affecting
    /// flags (app-lock, screenshot protection). Mirrors
    /// `TokenVault.save`: update-first, add when absent, delete+add as a
    /// last resort, and the terminal OSStatus is checked + logged.
    /// Default-on-absence semantics are unchanged (a failed write just
    /// means the key stays absent → caller's documented default).
    private static func keychainSet(_ account: String, _ data: Data) {
        let base: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account
        ]
        let attributes: [CFString: Any] = [
            kSecValueData:      data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(base as CFDictionary,
                                         attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var add = base
            for (k, v) in attributes { add[k] = v }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            logIfFailed("add", account: account, status: addStatus)
            return
        }
        SecItemDelete(base as CFDictionary)
        var add = base
        for (k, v) in attributes { add[k] = v }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        logIfFailed("reset", account: account, status: addStatus)
    }

    /// SECURITY F-2: surface a failed keychain write instead of
    /// swallowing it. Log string built into a single `let line: String`
    /// outside any closure (CLAUDE.md Swift-6 type-checker trap).
    private static func logIfFailed(_ op: String,
                                    account: String,
                                    status: OSStatus) {
        if status == errSecSuccess { return }
        let statusText: String = String(describing: status)
        let line: String = "PrivacyGate keychain "
            + op + " failed status=" + statusText
        RTLog.error("security", line)
    }

    private static func keychainGet(_ account: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return data
    }
}

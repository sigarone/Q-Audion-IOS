import Foundation
import Security

/// SECURITY C-5 + M-2 — single source of truth for auth-token storage.
///
/// Tokens were previously kept in `UserDefaults`, which is a plaintext
/// `.plist` inside the app container — readable by any process with file
/// access (jailbroken device, iTunes/Finder backup, forensic extraction).
/// `TokenVault` moves the access + refresh tokens into the iOS Keychain
/// (`kSecClassGenericPassword`) with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`:
///   - encrypted at rest by the Secure Enclave-derived class key,
///   - not synced to iCloud / not included in unencrypted backups,
///   - available to background tasks (CallKit / VoIP push) after the
///     first device unlock following a reboot.
///
/// API is **static only** and takes/returns primitives (`String`). It
/// MUST NOT reference `AppState` (see CLAUDE.md §16 — taking `AppState`
/// as a parameter type in a NEW Swift file silently breaks the build).
enum TokenVault {

    /// Keychain service scope. All Q-Audion auth items share this so a
    /// single `clear()` wipes the whole credential set on logout.
    private static let service = "com.qaudion.auth"

    /// Logical account keys inside the `service` scope.
    private static let accessAccount = "access_token"
    private static let refreshAccount = "refresh_token"

    // MARK: - Public API

    static func saveAccessToken(_ token: String) {
        save(account: accessAccount, value: token)
    }

    static func saveRefreshToken(_ token: String) {
        save(account: refreshAccount, value: token)
    }

    static func loadAccessToken() -> String? {
        load(account: accessAccount)
    }

    static func loadRefreshToken() -> String? {
        load(account: refreshAccount)
    }

    /// Remove every credential item in the `com.qaudion.auth` scope.
    static func clear() {
        delete(account: accessAccount)
        delete(account: refreshAccount)
    }

    // MARK: - Keychain primitives

    private static func baseQuery(account: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func save(account: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        var query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus == errSecItemNotFound {
            for (k, v) in attributes { query[k] = v }
            SecItemAdd(query as CFDictionary, nil)
            return
        }
        // Any other status (e.g. duplicate after a race): hard-reset the
        // item so the value is never left stale.
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        var addQuery = baseQuery(account: account)
        for (k, v) in attributes { addQuery[k] = v }
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private static func load(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}

import Foundation
import Security
import QAudionEngine

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
    /// SEC-DEVICEID-REINSTALL (2026-08-03) — see `saveDeviceId` doc.
    private static let deviceIdAccount = "device_id"
    /// W-USERID-PLAINTEXT (2026-08-15) — see `saveUserId` doc.
    private static let userIdAccount = "user_id"
    /// Entitlements Task 2 (2026-08-17) — see `saveEntitlement` doc.
    private static let entitlementAccount = "entitlement_blob"

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

    /// SEC-DEVICEID-REINSTALL (2026-08-03) — the device-renew silent-auth
    /// fallback (`AppState.wireDeviceRenewFallback`) needs this deviceId to
    /// even ATTEMPT recovery. It used to live only in `UserDefaults`, which
    /// iOS wipes on app delete — while the Keychain-stored refresh token
    /// (`loadRefreshToken` above) survives delete+reinstall by design. That
    /// split let a device end up with a real (but now-dead) refresh token
    /// and NO deviceId: every refresh 401 fell through to the fallback,
    /// which read a `nil` deviceId and threw before ever calling
    /// `/auth/device-challenge` — confirmed on a live device via the server
    /// journal (five straight "refresh token rejected" cycles, zero
    /// device-challenge/device-renew requests, over 6 hours) while a
    /// second device with an intact Keychain+UserDefaults pair self-healed
    /// via device-renew every ~10-15 min all day. Keychain-backing this
    /// value the same way as the tokens closes that split for good.
    static func saveDeviceId(_ deviceId: String) {
        save(account: deviceIdAccount, value: deviceId)
    }

    static func loadDeviceId() -> String? {
        load(account: deviceIdAccount)
    }

    /// W-USERID-PLAINTEXT (2026-08-15) — the account UUID used to be kept
    /// in TWO separate plaintext `UserDefaults` keys (`AppState`'s
    /// `"currentUserId"` and `AuthService`'s own
    /// `"com.qaudion.auth.user_id"`), each written on every login/profile
    /// refresh. Both are `.plist` files inside the app container: readable
    /// on a jailbroken device or extracted straight out of an unencrypted
    /// iTunes/Finder backup — see `exploiting-insecure-data-storage-in-mobile`
    /// (OWASP M9). The userId is what ties every locally-cached message,
    /// call log and PSK derivation to a real account, so it's PII worth the
    /// same protection as the tokens above, not "just an identifier".
    static func saveUserId(_ userId: String) {
        save(account: userIdAccount, value: userId)
    }

    static func loadUserId() -> String? {
        load(account: userIdAccount)
    }

    /// Entitlements Task 2 (2026-08-17) — the current EGT (`header.payload.sig`,
    /// design doc §3.1) is cached VERBATIM as an opaque string, exactly like
    /// `EgtStore` on Android (`core-data/.../entitlements/EgtStore.kt`):
    /// nothing here parses, decodes, or verifies it. `EgtVerifier` (Task 1)
    /// re-checks the Ed25519 signature over the blob on every read
    /// (`CapabilityGate.loadCached`/`.refresh`, Task 3), so a tampered or
    /// corrupted cache entry simply fails verification and yields no
    /// capabilities — it is never trusted just because it round-tripped
    /// through this store. Kept in the SAME `com.qaudion.auth` Keychain
    /// service as the tokens above (unlike Android's separate prefs file)
    /// so it clears in lockstep with `clear()` below without a second wipe
    /// path to keep in sync — Android achieves the same "never outlives its
    /// user" property via `CapabilityGate`'s explicit `sub` check instead.
    static func saveEntitlement(_ blob: String) {
        save(account: entitlementAccount, value: blob)
    }

    static func loadEntitlement() -> String? {
        load(account: entitlementAccount)
    }

    static func clearEntitlement() {
        delete(account: entitlementAccount)
    }

    /// Remove every credential item in the `com.qaudion.auth` scope.
    static func clear() {
        delete(account: accessAccount)
        delete(account: refreshAccount)
        delete(account: deviceIdAccount)
        delete(account: userIdAccount)
        delete(account: entitlementAccount)
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

// MARK: - BCryptoBackendProvider persistence wiring

extension BCryptoBackendProvider {
    /// Wire this provider's `onTokenRotated` hook so ANY rotation it
    /// performs (leg-1 REST refresh, leg-2 device-renew, or a manual
    /// `applyTokenPair`) is written into the shared Keychain. Call on
    /// EVERY `BCryptoBackendProvider` construction — see `onTokenRotated`'s
    /// doc for the forced-logout / QR-re-pair bug this closes.
    @discardableResult
    func persistingRotatedTokens() -> BCryptoBackendProvider {
        onTokenRotated = { access, refresh in
            TokenVault.saveAccessToken(access)
            if let r = refresh, !r.isEmpty { TokenVault.saveRefreshToken(r) }
        }
        return self
    }
}

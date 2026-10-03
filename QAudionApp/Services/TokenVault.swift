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
        casLock.withLock { _ = saveUnlocked(account: accessAccount, value: token) }
    }

    static func saveRefreshToken(_ token: String) {
        casLock.withLock { _ = saveUnlocked(account: refreshAccount, value: token) }
    }

    // MARK: - Shared credential store for the refresh coordinator

    /// Serialises every write of the access/refresh pair in this process with the
    /// compare-and-swap below, so a plain `saveRefreshToken` cannot interleave with it.
    private static let casLock = NSLock()

    /// UserDefaults key of the absolute expiry epoch (seconds) of the current access token.
    static let accessExpiryEpochKey = "com.qaudion.auth.access_expiry_epoch"

    /// The pair as stored. An absent item reads as nil; any other Keychain status (locked,
    /// interaction not allowed) THROWS, unlike `loadAccessToken()`/`loadRefreshToken()`
    /// which fold "unreadable" into "absent" and so cannot tell a signed-out device
    /// from a locked Keychain.
    static func loadCredentials() throws -> AuthStoredCredentials {
        try casLock.withLock {
            AuthStoredCredentials(
                access: try loadChecked(account: accessAccount),
                refresh: try loadChecked(account: refreshAccount))
        }
    }

    /// Write `tokens` only if the stored refresh token is still `expectedRefresh`.
    /// Returns false (nothing written) when another path already rotated it: an older
    /// pair must never overwrite a newer one. Refresh token first, access token second:
    /// if the process dies in between, the stored refresh token is already the live one.
    static func compareAndSwapTokens(expectedRefresh: String?, with tokens: AuthTokenSet) throws -> Bool {
        try casLock.withLock {
            let current = try loadChecked(account: refreshAccount)
            guard AuthRefreshCoordinator.sameRefreshToken(current, expectedRefresh) else { return false }
            // Never write into an empty store. A session without a refresh token (device-renew
            // only) has `nil == nil` here, so the comparison above cannot tell "unchanged" from
            // "logged out while the renew was on the wire" (`clear()` ran, then this CAS):
            // writing would put tokens back into a store whose device and user ids are gone.
            let currentAccess = try loadChecked(account: accessAccount)
            guard AuthRefreshCoordinator.hasAnyToken(access: currentAccess, refresh: current) else { return false }
            if let r = tokens.refreshToken, !r.isEmpty {
                let st = saveUnlocked(account: refreshAccount, value: r)
                guard st == errSecSuccess else { throw AuthCredentialStoreError.unreadable(status: st) }
            }
            let st = saveUnlocked(account: accessAccount, value: tokens.accessToken)
            guard st == errSecSuccess else { throw AuthCredentialStoreError.unreadable(status: st) }
            recordAccessExpiry(expiresInSec: tokens.expiresInSec, accessToken: tokens.accessToken)
            return true
        }
    }

    /// Persist when the current access token stops being valid, so the proactive-refresh
    /// scheduler can renew ahead of expiry: the server's `expires_in` when it gave one,
    /// else the JWT `exp`, else nothing (the stale epoch is cleared, otherwise the
    /// scheduler would see a past value and loop).
    static func recordAccessExpiry(expiresInSec: Int?, accessToken: String) {
        if let secs = expiresInSec, secs > 0 {
            UserDefaults.standard.set(Date().timeIntervalSince1970 + Double(secs), forKey: accessExpiryEpochKey)
        } else if let parsed = jwtExpiryEpoch(accessToken) {
            UserDefaults.standard.set(parsed, forKey: accessExpiryEpochKey)
        } else {
            UserDefaults.standard.removeObject(forKey: accessExpiryEpochKey)
        }
    }

    /// Best-effort extraction of the JWT `exp` (seconds since epoch) from the payload
    /// segment of a compact JWS; nil when the token is opaque or malformed.
    static func jwtExpiryEpoch(_ token: String) -> Double? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = b64.count % 4
        if rem > 0 { b64 += String(repeating: "=", count: 4 - rem) }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let exp = obj["exp"] as? Double { return exp }
        if let expInt = obj["exp"] as? Int { return Double(expInt) }
        return nil
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
    ///
    /// Under `casLock`: a compare-and-swap that already read the old refresh token must not
    /// write its pair back between two of these deletions and leave a half-signed-in store
    /// (an access token with no refresh token) after a logout.
    static func clear() {
        casLock.withLock {
            delete(account: accessAccount)
            delete(account: refreshAccount)
            delete(account: deviceIdAccount)
            delete(account: userIdAccount)
            delete(account: entitlementAccount)
        }
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
        casLock.withLock { _ = saveUnlocked(account: account, value: value) }
    }

    /// Caller holds `casLock`. Returns the Keychain status of the write that took effect.
    private static func saveUnlocked(account: String, value: String) -> OSStatus {
        guard let data = value.data(using: .utf8) else { return errSecParam }
        var query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return errSecSuccess
        }
        if updateStatus == errSecItemNotFound {
            for (k, v) in attributes { query[k] = v }
            return SecItemAdd(query as CFDictionary, nil)
        }
        // Any other status (e.g. duplicate after a race): hard-reset the
        // item so the value is never left stale.
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        var addQuery = baseQuery(account: account)
        for (k, v) in attributes { addQuery[k] = v }
        return SecItemAdd(addQuery as CFDictionary, nil)
    }

    /// Like `load(account:)` but only "item not found" reads as nil; every other status
    /// throws so the caller never mistakes a locked Keychain for a signed-out device.
    private static func loadChecked(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AuthCredentialStoreError.unreadable(status: status) }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
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
        // The same store, read back: lets this provider's socket pick up a rotation another
        // provider persisted (see `storedTokenPair`).
        storedTokenPair = { (access: TokenVault.loadAccessToken(), refresh: TokenVault.loadRefreshToken()) }
        // The refresh coordinator reads the refresh token from here (never from a provider's
        // own, possibly stale, copy) and writes results back with compare-and-swap.
        credentialStore = KeychainAuthCredentialStore.shared
        AuthCoordinatorLogging.installIfNeeded()
        return self
    }
}

// MARK: - Refresh coordinator wiring

/// The Keychain-backed `AuthCredentialStore`. Every read goes through `TokenVault`'s
/// checked loader, so a locked Keychain surfaces as `unreadable`, never as "no token".
final class KeychainAuthCredentialStore: AuthCredentialStore, @unchecked Sendable {
    static let shared = KeychainAuthCredentialStore()

    func load() throws -> AuthStoredCredentials {
        try TokenVault.loadCredentials()
    }

    func compareAndSwap(expectedRefresh: String?, with tokens: AuthTokenSet) throws -> Bool {
        try TokenVault.compareAndSwapTokens(expectedRefresh: expectedRefresh, with: tokens)
    }
}

/// Routes the coordinator's log lines to `RTLog` (tag `auth`), once per process. The lines
/// carry reason codes and numbers only: no token, no token hash, no user data.
enum AuthCoordinatorLogging {
    private static let once: Void = {
        AuthRefreshCoordinator.shared.setLogger { level, message in
            switch level {
            case .debug: RTLog.debug("auth", message)
            case .info:  RTLog.info("auth", message)
            case .warn:  RTLog.warn("auth", message)
            case .error: RTLog.error("auth", message)
            }
        }
    }()

    static func installIfNeeded() { _ = once }
}

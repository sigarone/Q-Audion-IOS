import Foundation
import UIKit
import QAudionEngine

final class AuthService {
    // SECURITY C-5 + M-2 — access/refresh tokens now live in the iOS
    // Keychain via `TokenVault`, not UserDefaults. These string keys are
    // kept ONLY for the one-time migration (and because AppState's
    // device-renew fallback still writes the raw UserDefaults keys; the
    // migration on the next load path sweeps them into the Keychain).
    private let tokenKey = "com.qaudion.auth.token"
    private let refreshTokenKey = "com.qaudion.auth.refresh_token"
    private let userIdKey = "com.qaudion.auth.user_id"
    private let deviceIdKey = "com.qaudion.auth.device_id"

    /// One-time (idempotent) sweep: if the Keychain has no access token
    /// but the legacy UserDefaults keys do, copy them into the Keychain
    /// and erase the plaintext UserDefaults copies. Also catches tokens
    /// written by AppState's device-renew fallback (which still pokes the
    /// raw UserDefaults keys) so a cold start never reloads a stale
    /// plaintext token.
    private func migrateTokensToKeychainIfNeeded() {
        let ud = UserDefaults.standard
        if TokenVault.loadAccessToken() == nil,
           let legacyAccess = ud.string(forKey: tokenKey), !legacyAccess.isEmpty {
            TokenVault.saveAccessToken(legacyAccess)
        }
        if TokenVault.loadRefreshToken() == nil,
           let legacyRefresh = ud.string(forKey: refreshTokenKey), !legacyRefresh.isEmpty {
            TokenVault.saveRefreshToken(legacyRefresh)
        }
        // Remove the plaintext copies regardless — the Keychain is now
        // authoritative for both tokens.
        ud.removeObject(forKey: tokenKey)
        ud.removeObject(forKey: refreshTokenKey)
    }

    func login(phoneNumber: String, password: String, serverUrl: String) async throws -> AuthCredentials {
        let phoneHash = try PhoneHash.hash(phoneNumber)
        return try await loginWithPhoneHash(phoneHash: phoneHash, password: password, serverUrl: serverUrl)
    }

    /// Login wire shape with a PRE-COMPUTED `phone_hash` (lowercase hex
    /// SHA-256). Mirrors Android's `LoginUseCase.invoke(phoneHash, ...)`
    /// which receives the hash already produced by the caller (e.g.
    /// `FastSetupUseCase` hashes the opaque `phone_id` from the QR).
    ///
    /// **Why this exists**: the QR `phone_id` is NOT an E.164 number, so
    /// the regular `login(phoneNumber:)` path fails at `PhoneHash.hash`
    /// (E.164 regex rejects hex). FastSetup MUST go through this method
    /// so the already-derived `phone_hash` flows straight to the wire,
    /// matching Android's behaviour byte-for-byte.
    func loginWithPhoneHash(phoneHash: String, password: String, serverUrl: String) async throws -> AuthCredentials {
        let backendConfig = BackendConfig.pinned(serverUrl: serverUrl)
        let provider = BCryptoBackendProvider(config: backendConfig)
        let deviceName: String
        #if canImport(UIKit)
        deviceName = await UIDevice.current.name
        #else
        deviceName = "iOS Device"
        #endif
        let creds = try await provider.accountApi.login(phoneHash: phoneHash, password: password, deviceName: deviceName)
        saveCredentials(creds)
        return creds
    }

    func register(phoneNumber: String, password: String, inviteCode: String?, serverUrl: String) async throws -> String {
        let backendConfig = BackendConfig.pinned(serverUrl: serverUrl)
        let provider = BCryptoBackendProvider(config: backendConfig)
        let userId = try await provider.accountApi.register(
            phoneNumber: phoneNumber,
            password: password,
            inviteCode: inviteCode,
            displayName: nil
        )
        return userId
    }

    func saveCredentials(_ creds: AuthCredentials) {
        // SECURITY C-5 — tokens → Keychain; userId/deviceId stay in
        // UserDefaults (not credentials; deviceId is read directly by
        // AppState's device-renew fallback under deviceIdKey).
        TokenVault.saveAccessToken(creds.accessToken)
        if let refresh = creds.refreshToken, !refresh.isEmpty {
            TokenVault.saveRefreshToken(refresh)
        }
        UserDefaults.standard.set(creds.userId, forKey: userIdKey)
        UserDefaults.standard.set(creds.deviceId, forKey: deviceIdKey)
    }

    func saveToken(_ token: String) {
        TokenVault.saveAccessToken(token)
    }

    /// SECURITY H-2 — persist a refreshed token pair so a cold start
    /// never reloads a stale token from the Keychain.
    func saveRefreshToken(_ token: String) {
        TokenVault.saveRefreshToken(token)
    }

    func loadToken() -> String? {
        // Sweep any legacy plaintext token into the Keychain before the
        // first read so callers always get the authoritative value.
        migrateTokensToKeychainIfNeeded()
        return TokenVault.loadAccessToken()
    }

    func loadRefreshToken() -> String? {
        migrateTokensToKeychainIfNeeded()
        return TokenVault.loadRefreshToken()
    }

    func loadUserId() -> String? {
        UserDefaults.standard.string(forKey: userIdKey)
    }

    func clearToken() {
        TokenVault.clear()
        UserDefaults.standard.removeObject(forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: refreshTokenKey)
        UserDefaults.standard.removeObject(forKey: userIdKey)
        UserDefaults.standard.removeObject(forKey: deviceIdKey)
    }

    func isLoggedIn() -> Bool {
        loadToken() != nil
    }
}

enum AuthError: Error, LocalizedError {
    case invalidCredential
    case tokenExpired

    var errorDescription: String? {
        switch self {
        case .invalidCredential: return "Invalid credential format"
        case .tokenExpired: return "Authentication token has expired"
        }
    }
}

import Foundation
import UIKit
import QAudionEngine

final class AuthService {
    private let tokenKey = "com.qaudion.auth.token"
    private let refreshTokenKey = "com.qaudion.auth.refresh_token"
    private let userIdKey = "com.qaudion.auth.user_id"
    private let deviceIdKey = "com.qaudion.auth.device_id"

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
        UserDefaults.standard.set(creds.accessToken, forKey: tokenKey)
        UserDefaults.standard.set(creds.refreshToken, forKey: refreshTokenKey)
        UserDefaults.standard.set(creds.userId, forKey: userIdKey)
        UserDefaults.standard.set(creds.deviceId, forKey: deviceIdKey)
    }

    func saveToken(_ token: String) {
        UserDefaults.standard.set(token, forKey: tokenKey)
    }

    func loadToken() -> String? {
        UserDefaults.standard.string(forKey: tokenKey)
    }

    func loadUserId() -> String? {
        UserDefaults.standard.string(forKey: userIdKey)
    }

    func clearToken() {
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

import Foundation
import QAudionEngine

final class AuthService {
    private let tokenKey = "com.qaudion.auth.token"
    private let refreshTokenKey = "com.qaudion.auth.refresh_token"
    private let userIdKey = "com.qaudion.auth.user_id"
    private let deviceIdKey = "com.qaudion.auth.device_id"

    func login(phoneNumber: String, password: String, serverUrl: String) async throws -> AuthCredentials {
        let backendConfig = BackendConfig(serverUrl: serverUrl)
        let provider = BCryptoBackendProvider(config: backendConfig)
        let phoneHash = BCryptoAccountApiImpl.hashPhone(phoneNumber)
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

    func register(phoneNumber: String, inviteCode: String?, serverUrl: String) async throws -> String {
        let backendConfig = BackendConfig(serverUrl: serverUrl)
        let provider = BCryptoBackendProvider(config: backendConfig)
        let userId = try await provider.accountApi.register(phoneNumber: phoneNumber, inviteCode: inviteCode)
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

import Foundation
import QAudionEngine

final class AuthService {
    private let tokenKey = "com.qaudion.auth.token"

    func login(userId: String, credential: String, serverUrl: String) async throws -> String {
        let backendConfig = BackendConfig(serverUrl: serverUrl)
        let rest = BCryptoRestClient(config: backendConfig)
        let accountApi = BCryptoAccountApiImpl(rest: rest)

        guard let credentialData = credential.data(using: .utf8) else {
            throw AuthError.invalidCredential
        }
        let token = try await accountApi.login(userId: userId, credential: credentialData)
        return token
    }

    func register(userId: String, credential: String, serverUrl: String) async throws {
        let backendConfig = BackendConfig(serverUrl: serverUrl)
        let rest = BCryptoRestClient(config: backendConfig)
        let accountApi = BCryptoAccountApiImpl(rest: rest)

        guard let credentialData = credential.data(using: .utf8) else {
            throw AuthError.invalidCredential
        }
        try await accountApi.register(userId: userId, credential: credentialData)
    }

    func saveToken(_ token: String) {
        UserDefaults.standard.set(token, forKey: tokenKey)
    }

    func loadToken() -> String? {
        UserDefaults.standard.string(forKey: tokenKey)
    }

    func clearToken() {
        UserDefaults.standard.removeObject(forKey: tokenKey)
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

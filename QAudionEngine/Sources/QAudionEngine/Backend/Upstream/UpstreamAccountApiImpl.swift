import Foundation

/// Account management routed through Signal-compatible REST endpoints.
///
/// Handles registration, authentication, token refresh, and profile management
/// against Signal's server API. Auth tokens returned by login/refresh are stored
/// in the `BackendConfig` by the engine layer and used by the REST/WS clients
/// for subsequent requests.
public final class UpstreamAccountApiImpl: AccountApi {
    private let rest: BCryptoRestClient

    init(rest: BCryptoRestClient) {
        self.rest = rest
    }

    // MARK: - AccountApi

    /// Register a new account with Signal-compatible server.
    ///
    /// Signal uses phone-number-based registration with verification codes.
    /// The `userId` maps to the phone number / UUID, and `credential` carries
    /// the verification payload (code + registration data).
    public func register(userId: String, credential: Data) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "userId": userId,
            "credential": credential.base64EncodedString()
        ])
        _ = try await rest.post("/v1/accounts/register", body: body)
    }

    /// Authenticate and obtain an access token.
    ///
    /// Returns a Bearer token string that should be set on the `BackendConfig`
    /// for subsequent REST and WebSocket requests.
    public func login(userId: String, credential: Data) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: [
            "userId": userId,
            "credential": credential.base64EncodedString()
        ])
        let data = try await rest.post("/v1/accounts/login", body: body)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String else {
            throw BCryptoError.decodingError
        }
        return token
    }

    /// Refresh an expiring token.
    ///
    /// Returns a new Bearer token. The caller is responsible for updating
    /// the `BackendConfig` and propagating the new token to REST/WS clients.
    public func refreshToken(currentToken: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: [
            "token": currentToken
        ])
        let data = try await rest.post("/v1/accounts/token/refresh", body: body)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String else {
            throw BCryptoError.decodingError
        }
        return token
    }

    /// Fetch the authenticated user's profile from the server.
    public func getProfile() async throws -> UserProfile {
        let data = try await rest.get("/v1/profile")
        return try JSONDecoder().decode(UserProfile.self, from: data)
    }

    /// Update the authenticated user's profile on the server.
    public func updateProfile(_ profile: UserProfile) async throws {
        let body = try JSONEncoder().encode(profile)
        _ = try await rest.post("/v1/profile", body: body)
    }
}

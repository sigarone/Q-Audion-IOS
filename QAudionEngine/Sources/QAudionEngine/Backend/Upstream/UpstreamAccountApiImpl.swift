import Foundation

/// Account management routed through Signal-compatible REST endpoints.
public final class UpstreamAccountApiImpl: AccountApi {
    private let rest: BCryptoRestClient
    init(rest: BCryptoRestClient) { self.rest = rest }

    public func register(phoneNumber: String, inviteCode: String?) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["phone_number": phoneNumber])
        let data = try await rest.post("/v1/accounts/register", body: body)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userId = json["user_id"] as? String ?? json["uuid"] as? String else { throw BCryptoError.decodingError }
        return userId
    }

    public func login(phoneHash: String, password: String, deviceName: String) async throws -> AuthCredentials {
        let body = try JSONSerialization.data(withJSONObject: [
            "phone_hash": phoneHash, "password": password, "device_name": deviceName
        ])
        let data = try await rest.post("/v1/accounts/login", body: body)
        return try JSONDecoder().decode(AuthCredentials.self, from: data)
    }

    public func refreshToken(_ refreshToken: String) async throws -> AuthTokenPair {
        let body = try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
        let data = try await rest.post("/v1/accounts/token/refresh", body: body)
        return try JSONDecoder().decode(AuthTokenPair.self, from: data)
    }

    public func logout() async throws {
        _ = try await rest.delete("/v1/accounts/logout")
    }

    public func getProfile() async throws -> UserProfile {
        let data = try await rest.get("/v1/profile")
        return try JSONDecoder().decode(UserProfile.self, from: data)
    }

    public func updateProfile(displayName: String, statusMessage: String, avatarData: Data?) async throws {
        let dict: [String: Any] = ["display_name": displayName, "status_message": statusMessage]
        let body = try JSONSerialization.data(withJSONObject: dict)
        _ = try await rest.put("/v1/profile", body: body)
    }

    public func registerPushToken(_ token: String, platform: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["token": token, "platform": platform])
        _ = try await rest.post("/v1/accounts/push-token", body: body)
    }
}

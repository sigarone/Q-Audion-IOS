import Foundation

/// Account management routed through Signal-compatible REST endpoints.
public final class UpstreamAccountApiImpl: AccountApi {
    private let rest: BCryptoRestClient
    init(rest: BCryptoRestClient) { self.rest = rest }

    public func register(phoneNumber: String, password: String, inviteCode: String?, displayName: String?) async throws -> String {
        var dict: [String: Any] = ["phone_number": phoneNumber, "password": password]
        if let code = inviteCode, !code.isEmpty { dict["invite_code"] = code }
        if let name = displayName, !name.isEmpty { dict["display_name"] = name }
        let body = try JSONSerialization.data(withJSONObject: dict)
        let data = try await rest.post("/v1/accounts/register", body: body)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userId = (json["user_id"] as? String) ?? (json["uuid"] as? String) else { throw BCryptoError.decodingError }
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

    /// Audit P0 #2.12 — Upstream backend stub. Mirrors the bcrypto
    /// shape; Upstream's own /accounts/* paths can be wired here when
    /// they ship.
    public func accountExport() async throws -> Data {
        return try await rest.get("/v1/accounts/export")
    }

    public func deleteAccount() async throws {
        _ = try await rest.delete("/v1/accounts")
    }

    public func revokeDevice(deviceId: String) async throws {
        _ = try await rest.delete("/v1/devices/\(deviceId)")
    }

    public func getProfile() async throws -> UserProfile {
        let data = try await rest.get("/v1/profile")
        return try JSONDecoder().decode(UserProfile.self, from: data)
    }

    public func updateProfile(displayName: String?, statusMessage: String?, avatarUrl: String?) async throws {
        var dict: [String: Any] = [:]
        if let displayName { dict["display_name"] = displayName }
        if let statusMessage { dict["status_message"] = statusMessage }
        if let avatarUrl { dict["avatar_url"] = avatarUrl }
        let body = try JSONSerialization.data(withJSONObject: dict)
        _ = try await rest.put("/v1/profile", body: body)
    }

    public func registerPushToken(_ token: String, platform: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["token": token, "platform": platform])
        _ = try await rest.post("/v1/accounts/push-token", body: body)
    }

    /// The upstream (Signal-style) backend does not expose the bcrypto
    /// recovery/setup-verify or users-by-id endpoints. These stubs exist only
    /// so the class conforms to `AccountApi`; they throw a `notFound` to make
    /// it obvious if the runtime accidentally routes one of these calls here.
    public func recoverySetup(recoveryHash: String) async throws -> Bool {
        throw BCryptoError.notFound
    }

    public func recoveryVerify(identifier: String, recoverySecret: String, deviceName: String) async throws -> AuthCredentials {
        throw BCryptoError.notFound
    }

    public func getPublicUser(userId: String) async throws -> PublicUser {
        throw BCryptoError.notFound
    }
}

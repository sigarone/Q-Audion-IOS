import Foundation

public final class BCryptoAccountApiImpl: AccountApi {
    private let rest: BCryptoRestClient
    public init(rest: BCryptoRestClient) { self.rest = rest }

    public func register(phoneNumber: String, password: String, inviteCode: String?, displayName: String?) async throws -> String {
        let phoneHash = try PhoneHash.hash(phoneNumber)
        var dict: [String: Any] = [
            "phone_number": phoneHash,
            "password": password,
        ]
        if let code = inviteCode, !code.isEmpty { dict["invite_code"] = code }
        if let name = displayName, !name.isEmpty { dict["display_name"] = name }
        let body = try JSONSerialization.data(withJSONObject: dict)
        let data = try await rest.post("/api/v1/register", body: body)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userId = json["user_id"] as? String else { throw BCryptoError.decodingError }
        return userId
    }

    public func login(phoneHash: String, password: String, deviceName: String) async throws -> AuthCredentials {
        let dict: [String: Any] = ["phone_number": phoneHash, "password": password, "device_name": deviceName]
        let body = try JSONSerialization.data(withJSONObject: dict)
        let data = try await rest.post("/api/v1/auth/login", body: body)
        return try JSONDecoder().decode(AuthCredentials.self, from: data)
    }

    public func refreshToken(_ refreshToken: String) async throws -> AuthTokenPair {
        let dict = ["refresh_token": refreshToken]
        let body = try JSONSerialization.data(withJSONObject: dict)
        let data = try await rest.post("/api/v1/auth/refresh", body: body)
        return try JSONDecoder().decode(AuthTokenPair.self, from: data)
    }

    public func logout() async throws {
        _ = try await rest.delete("/api/v1/auth/logout")
    }

    public func getProfile() async throws -> UserProfile {
        let data = try await rest.get("/api/v1/profile")
        return try JSONDecoder().decode(UserProfile.self, from: data)
    }

    public func updateProfile(displayName: String?, statusMessage: String?, avatarUrl: String?) async throws {
        var dict: [String: Any] = [:]
        if let displayName { dict["display_name"] = displayName }
        if let statusMessage { dict["status_message"] = statusMessage }
        if let avatarUrl { dict["avatar_url"] = avatarUrl }
        let body = try JSONSerialization.data(withJSONObject: dict)
        _ = try await rest.put("/api/v1/profile", body: body)
    }

    public func registerPushToken(_ token: String, platform: String = "ios") async throws {
        let dict: [String: Any] = ["token": token, "platform": platform]
        let body = try JSONSerialization.data(withJSONObject: dict)
        _ = try await rest.post("/api/v1/account/fcm-token", body: body)
    }

    @available(*, deprecated, message: "Use PhoneHash.hash(_:) — matches Android PhoneHashHelper byte-for-byte. This forwarder is kept only to avoid breaking callers in the in-progress BCrypto workstream.")
    public static func hashPhone(_ phone: String) -> String {
        // Forward to the canonical helper. Falls back to raw-hex only if
        // normalization fails (legacy callers sometimes pass already-E.164
        // input where invalidE164 would be spurious — callers should migrate).
        return PhoneHash.hashOrNil(phone) ?? PhoneHash.sha256Hex(phone)
    }
}

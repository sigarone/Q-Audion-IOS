import Foundation
import CommonCrypto

public final class BCryptoAccountApiImpl: AccountApi {
    private let rest: BCryptoRestClient
    public init(rest: BCryptoRestClient) { self.rest = rest }

    public func register(phoneNumber: String, inviteCode: String?) async throws -> String {
        var dict: [String: Any] = ["phone_number": phoneNumber]
        if let code = inviteCode { dict["invite_code"] = code }
        let body = try JSONSerialization.data(withJSONObject: dict)
        let data = try await rest.post("/api/v1/register", body: body)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userId = json["user_id"] as? String else { throw BCryptoError.decodingError }
        return userId
    }

    public func login(phoneHash: String, password: String, deviceName: String) async throws -> AuthCredentials {
        let dict: [String: Any] = ["phone_hash": phoneHash, "password": password, "device_name": deviceName]
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

    public func updateProfile(displayName: String, statusMessage: String, avatarData: Data?) async throws {
        if let avatar = avatarData {
            _ = try await rest.postMultipart("/api/v1/profile",
                                             fields: ["display_name": displayName, "status_message": statusMessage],
                                             fileField: "avatar", fileData: avatar)
        } else {
            let dict: [String: Any] = ["display_name": displayName, "status_message": statusMessage]
            let body = try JSONSerialization.data(withJSONObject: dict)
            _ = try await rest.put("/api/v1/profile", body: body)
        }
    }

    public func registerPushToken(_ token: String, platform: String = "ios") async throws {
        let dict: [String: Any] = ["token": token, "platform": platform]
        let body = try JSONSerialization.data(withJSONObject: dict)
        _ = try await rest.post("/api/v1/account/fcm-token", body: body)
    }

    /// SHA-256 hash of phone number (matches server's hashPhone).
    public static func hashPhone(_ phone: String) -> String {
        let data = Data(phone.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash) }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

import Foundation

public final class BCryptoAccountApiImpl: AccountApi {
    private let rest: BCryptoRestClient
    init(rest: BCryptoRestClient) { self.rest = rest }

    public func register(userId: String, credential: Data) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["userId": userId, "credential": credential.base64EncodedString()])
        _ = try await rest.post("/api/v1/auth/register", body: body)
    }
    public func login(userId: String, credential: Data) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["userId": userId, "credential": credential.base64EncodedString()])
        let data = try await rest.post("/api/v1/auth/login", body: body)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String else { throw BCryptoError.decodingError }
        return token
    }
    public func refreshToken(currentToken: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["token": currentToken])
        let data = try await rest.post("/api/v1/auth/refresh", body: body)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String else { throw BCryptoError.decodingError }
        return token
    }
    public func getProfile() async throws -> UserProfile {
        let data = try await rest.get("/api/v1/profile")
        return try JSONDecoder().decode(UserProfile.self, from: data)
    }
    public func updateProfile(_ profile: UserProfile) async throws {
        let body = try JSONEncoder().encode(profile)
        _ = try await rest.post("/api/v1/profile", body: body)
    }
}

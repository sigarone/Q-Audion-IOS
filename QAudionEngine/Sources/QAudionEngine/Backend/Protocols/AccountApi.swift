import Foundation

public protocol AccountApi {
    /// Register with E.164 phone number + password.
    /// Phone is normalised + SHA-256-hashed and sent on the wire under the
    /// `phone_number` key (Android contract: server treats the hash as an
    /// opaque identifier). Server returns userId.
    func register(phoneNumber: String, password: String, inviteCode: String?, displayName: String?) async throws -> String
    /// Login with phone hash + password + device name. Returns auth credentials.
    /// The hash value travels on the wire under the `phone_number` key to match
    /// the Android/server contract (`LoginRequest`).
    func login(phoneHash: String, password: String, deviceName: String) async throws -> AuthCredentials
    /// Refresh access token.
    func refreshToken(_ refreshToken: String) async throws -> AuthTokenPair
    /// Logout (revokes all tokens).
    func logout() async throws
    /// Get current user's profile.
    func getProfile() async throws -> UserProfile
    /// Update profile (display name, status, optional avatar).
    func updateProfile(displayName: String, statusMessage: String, avatarData: Data?) async throws
    /// Register APNS push token.
    func registerPushToken(_ token: String, platform: String) async throws
}

public struct AuthCredentials: Codable {
    public let userId: String
    public let deviceId: String
    public let accessToken: String
    public let refreshToken: String?
    public let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case deviceId = "device_id"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

public struct AuthTokenPair: Codable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

public struct UserProfile: Codable {
    public var userId: String
    public var displayName: String?
    public var avatarUrl: String?
    public var statusMessage: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case statusMessage = "status_message"
    }

    public init(userId: String, displayName: String? = nil, avatarUrl: String? = nil, statusMessage: String? = nil) {
        self.userId = userId; self.displayName = displayName
        self.avatarUrl = avatarUrl; self.statusMessage = statusMessage
    }
}

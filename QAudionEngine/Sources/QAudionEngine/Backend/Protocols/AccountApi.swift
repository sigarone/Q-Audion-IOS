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
    /// Update profile. All three fields are independently optional and only
    /// included in the wire payload when non-nil — matches Android
    /// `UpdateProfileRequest` (see `ProfileDto.kt`).
    ///
    /// Note: `avatarUrl` is a **URL string**, not binary data. The avatar
    /// must be uploaded via the dedicated storage endpoint first; the
    /// profile endpoint only persists the resulting URL. The previous
    /// multipart branch targeted an endpoint the server does not expose
    /// and would 404/405.
    func updateProfile(displayName: String?, statusMessage: String?, avatarUrl: String?) async throws
    /// Register APNS push token.
    func registerPushToken(_ token: String, platform: String) async throws
    /// Enroll a seed-phrase-derived recovery hash while authenticated so the
    /// account can later be re-provisioned on a fresh install without losing
    /// contacts/keys. Returns `enrolled` flag from the server.
    /// Matches Android `POST /api/v1/auth/recovery-setup`.
    func recoverySetup(recoveryHash: String) async throws -> Bool
    /// Re-provision a device from a recovery secret on a fresh install (no
    /// active session). Returns a new credentials pair.
    /// Matches Android `POST /api/v1/auth/recovery-verify`.
    func recoveryVerify(identifier: String, recoverySecret: String, deviceName: String) async throws -> AuthCredentials
    /// Look up a peer user's public profile by user_id.
    /// Matches Android `GET /api/v1/users/{user_id}`.
    func getPublicUser(userId: String) async throws -> PublicUser
}

/// Public-profile projection returned by `GET /api/v1/users/{user_id}`.
/// Matches Android `PublicUserResponse`.
public struct PublicUser: Codable, Hashable {
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
        self.userId = userId
        self.displayName = displayName
        self.avatarUrl = avatarUrl
        self.statusMessage = statusMessage
    }
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
    /// SHA-256 hex of the user's phone identifier as stored on the
    /// server. For fast-setup users this is the SHA-256 of the
    /// `fastsetup-<uuid>` phone_id from the QR; for legacy phone
    /// signups it's SHA-256 of the E.164 number. Surfaced so the
    /// Account Settings screen can show the canonical identifier.
    public var phoneHash: String?
    /// Sequential dial-by-extension number assigned at fast-setup
    /// time. `nil` (or 0) when the account was created via the legacy
    /// phone-number signup path. Maps to `User.Extension` server-side.
    public var dialExtension: Int64?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case statusMessage = "status_message"
        case phoneHash = "phone_hash"
        case dialExtension = "extension"
    }

    public init(userId: String,
                displayName: String? = nil,
                avatarUrl: String? = nil,
                statusMessage: String? = nil,
                phoneHash: String? = nil,
                dialExtension: Int64? = nil) {
        self.userId = userId
        self.displayName = displayName
        self.avatarUrl = avatarUrl
        self.statusMessage = statusMessage
        self.phoneHash = phoneHash
        self.dialExtension = dialExtension
    }
}

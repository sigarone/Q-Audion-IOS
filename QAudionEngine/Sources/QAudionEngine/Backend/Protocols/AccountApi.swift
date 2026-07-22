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

    /// Audit P0 #2.12 — server-side GDPR data export. Returns the raw
    /// JSON envelope containing the user's profile + device list +
    /// identity-key bundle. The caller merges this with its local
    /// archive into the final Art. 20 export.
    func accountExport() async throws -> Data

    /// Audit P0 #2.12 — server-side account deletion. 204 on success.
    /// Caller MUST treat the JWT as invalidated even on error.
    func deleteAccount() async throws

    /// Audit P0 #2.11 — per-device revocation. The deviceId MUST be
    /// linked to the authenticated user (server returns 403 otherwise).
    func revokeDevice(deviceId: String) async throws
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
    /// W-ORPHANPEER — same lookup as ``getPublicUser(userId:)`` but returning
    /// `nil` on a 404 and throwing on everything else, so a caller can tell
    /// "this account does not exist" apart from "we could not reach the
    /// server". The throwing form flattens both into one error, and
    /// `try? await getPublicUser(...)` flattens them into one `nil` — neither
    /// can drive a decision to hide a contact.
    ///
    /// Same contract as the pre-existing ``lookupByExtension(_:)``.
    func getPublicUserIfExists(userId: String) async throws -> PublicUser?
    /// W414 — dial-by-extension lookup. Resolves a short PBX extension
    /// (e.g. 175) to a `UserProfile`. Returns `nil` on 404 (extension
    /// not assigned), throws on other errors. Used by the iOS DialPad
    /// to translate a typed number into the BCrypto userId the call
    /// signaling layer needs.
    /// Matches `GET /api/v1/directory/by-extension/{n}`.
    func lookupByExtension(_ ext: Int64) async throws -> UserProfile?
}

/// Public-profile projection returned by `GET /api/v1/users/{user_id}`.
/// Matches Android `PublicUserResponse`.
public struct PublicUser: Codable, Hashable {
    public var userId: String
    public var displayName: String?
    public var avatarUrl: String?
    public var statusMessage: String?
    /// PBX internal extension ("interno"). The server GUARANTEES every
    /// userId has one (bcrypto-lite `handleUserProfile` returns
    /// `"extension": user.Extension` on both `/users/{id}` and
    /// `/users/{id}/profile`). Optional here only for decode tolerance
    /// against older payloads — a missing/zero value at runtime is an
    /// upstream data error, not an acceptable state (Pavel rule
    /// 2026-07-20: the display chain must END in "Int. NNN", never in a
    /// steady-state short8 placeholder).
    public var extensionNumber: Int64?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case statusMessage = "status_message"
        case extensionNumber = "extension"
    }

    public init(userId: String, displayName: String? = nil, avatarUrl: String? = nil, statusMessage: String? = nil, extensionNumber: Int64? = nil) {
        self.userId = userId
        self.displayName = displayName
        self.avatarUrl = avatarUrl
        self.statusMessage = statusMessage
        self.extensionNumber = extensionNumber
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

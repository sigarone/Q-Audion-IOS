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
    /// Login with PBX extension number + password + device name. Restricted
    /// server-side to Fast Setup accounts (accounts with no real phone
    /// number) — a manual-entry alternative to the QR scan/upload, for
    /// reviewers (App Store, Google Play) or anyone else who cannot scan a
    /// QR image. Matches `POST /api/v1/auth/login/extension`.
    func loginWithExtension(extension ext: Int64, password: String, deviceName: String) async throws -> AuthCredentials
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

    // MARK: - SMS-OTP + extension-only registration (2026-07-29)

    /// Request an SMS-OTP code for `phoneNumber` (the RAW E.164 number —
    /// NOT a hash: the server itself sends the SMS and cannot deliver to a
    /// hash). `purpose` distinguishes a brand-new registration from a
    /// login on an existing account so the server can 404 (login, unknown
    /// number) or 409 (register, number already taken) appropriately.
    /// Matches `POST /api/v1/auth/otp/request`.
    func requestOtp(phoneNumber: String, purpose: OtpPurpose) async throws -> OtpRequestResponse

    /// Verify a previously-requested SMS-OTP code and complete register OR
    /// login — no password: possession of the code IS the credential.
    /// `inviteCode`/`displayName` are only meaningful when
    /// `purpose == .register` (both optional even then). `deviceName`
    /// mirrors the same field on ``login(phoneHash:password:deviceName:)``.
    /// Matches `POST /api/v1/auth/otp/verify`.
    func verifyOtp(phoneNumber: String, code: String, purpose: OtpPurpose, deviceName: String,
                    inviteCode: String?, displayName: String?) async throws -> OtpAuthResult

    /// Extension-only registration — no phone number at all, just a PBX
    /// extension the server assigns. Email is REQUIRED (no phone means no
    /// other recovery/support channel for the account). Matches
    /// `POST /api/v1/auth/register/extension`.
    func registerExtensionOnly(displayName: String?, email: String) async throws -> OtpAuthResult

    /// Authenticated — request a verification link/token for the email on
    /// the current account. Matches `POST /api/v1/auth/email/verify-request`.
    func requestEmailVerification(email: String) async throws -> EmailVerifyRequestResponse

    /// Authenticated — confirm a previously requested email-verification
    /// token (pasted manually, or extracted from the deep-linked
    /// verify-landing URL). Matches `POST /api/v1/auth/email/verify-confirm`.
    func confirmEmailVerification(token: String) async throws -> EmailVerifyConfirmResponse
}

/// Distinguishes a brand-new account from an existing one across the
/// SMS-OTP endpoints — same enum reused by both `otp/request` and
/// `otp/verify` since the server needs to know which flow it's in.
public enum OtpPurpose: String, Codable {
    case register
    case login
}

/// Response of `POST /api/v1/auth/otp/request`.
public struct OtpRequestResponse: Codable {
    /// Seconds until the issued code expires.
    public let expiresIn: Int
    /// Seconds the client must wait before it may request a fresh code
    /// (drives the resend-timer UI).
    public let resendAfter: Int

    enum CodingKeys: String, CodingKey {
        case expiresIn = "expires_in"
        case resendAfter = "resend_after"
    }
}

/// Response of `POST /api/v1/auth/otp/verify` and
/// `POST /api/v1/auth/register/extension` — both endpoints return the same
/// credential shape (plus a couple of endpoint-specific extras), so one
/// type covers both.
public struct OtpAuthResult: Codable {
    public let userId: String
    public let deviceId: String
    public let accessToken: String
    public let refreshToken: String?
    public let expiresIn: Int?
    public let tokenType: String?
    /// The server-assigned PBX extension. Present on a successful
    /// `register` (either via `otp/verify` or `register/extension`);
    /// absent on `otp/verify` with `purpose == .login`.
    public let assignedExtension: Int64?
    /// `register/extension` only — whether the email the user supplied
    /// still needs the confirm-link/token flow. Nil on `otp/verify`.
    public let emailPendingVerification: Bool?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case deviceId = "device_id"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case assignedExtension = "extension"
        case emailPendingVerification = "email_pending_verification"
    }

    /// Projects the shared credential fields into ``AuthCredentials`` so
    /// callers can reuse the exact same post-login plumbing (Keychain
    /// persistence, WS connect, presence bind…) that the password-based
    /// register/login paths already use — see `AuthService.saveCredentials`
    /// in the app layer.
    public var asAuthCredentials: AuthCredentials {
        AuthCredentials(userId: userId, deviceId: deviceId, accessToken: accessToken,
                         refreshToken: refreshToken, expiresIn: expiresIn)
    }
}

/// Response of `POST /api/v1/auth/email/verify-request`.
public struct EmailVerifyRequestResponse: Codable {
    public let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case expiresIn = "expires_in"
    }
}

/// Response of `POST /api/v1/auth/email/verify-confirm`.
public struct EmailVerifyConfirmResponse: Codable {
    public let verified: Bool
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
    ///
    /// 2026-07-29 reconciliation with ``UserProfile/dialExtension``: as of
    /// the SMS-OTP + extension-only registration server rollout, EVERY
    /// newly-created account (any registration path — OTP, extension-only,
    /// legacy phone) is assigned a non-zero extension at creation time, so
    /// the "guarantee" above is now literally true for accounts created
    /// after that date. Accounts created before the rollout are NOT
    /// backfilled — a pre-existing account can still legitimately carry a
    /// nil/0 extension, which is why this field stays `Optional` rather
    /// than becoming non-optional.
    public var extensionNumber: Int64?
    /// Opt-in PUBLIC phone number the peer has chosen to publish on their
    /// profile (server field `User.PublicPhoneNumber`, set via
    /// `UpdateUserProfile`, surfaced by `handleUserProfile` in
    /// `cmd/bcrypto-lite/main.go` as `"phone_number"`). Distinct from the
    /// private auth phone hash / `PhoneHash`: this is only ever populated
    /// when the user explicitly opted their number into their public
    /// profile. `nil` when the peer has not opted in (the common case).
    ///
    /// 2026-07-29: the server has sent this field on
    /// `GET /api/v1/users/{id}` all along — this struct's `Codable` decode
    /// simply had no field for it and silently dropped it on the floor.
    /// Added so the auto-save-from-call address-book enrichment
    /// (`NameResolutionService.enrichFromCallProfile`) can actually see it.
    public var phoneNumber: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case statusMessage = "status_message"
        case extensionNumber = "extension"
        case phoneNumber = "phone_number"
    }

    public init(userId: String, displayName: String? = nil, avatarUrl: String? = nil, statusMessage: String? = nil, extensionNumber: Int64? = nil, phoneNumber: String? = nil) {
        self.userId = userId
        self.displayName = displayName
        self.avatarUrl = avatarUrl
        self.statusMessage = statusMessage
        self.extensionNumber = extensionNumber
        self.phoneNumber = phoneNumber
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

    /// 2026-07-29 — the synthesized Swift memberwise init for a struct is
    /// only ever `internal`, never `public`, regardless of member access
    /// level, so without this explicit initializer no code outside this
    /// module (e.g. the `QAudionApp` app target) could construct a value —
    /// only decode one via `Codable`. Added so app-layer code has a
    /// documented, supported way to build one if a future call site needs
    /// to (``OtpAuthResult/asAuthCredentials`` itself is same-module and
    /// doesn't strictly need this, but relies on the type being
    /// constructible without reaching for `Codable` round-tripping).
    /// Purely additive: does not affect the compiler-synthesized
    /// `Codable` conformance above.
    public init(userId: String, deviceId: String, accessToken: String,
                refreshToken: String?, expiresIn: Int?) {
        self.userId = userId
        self.deviceId = deviceId
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
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
    /// Sequential dial-by-extension number assigned at account-creation
    /// time. Maps to `User.Extension` server-side.
    ///
    /// 2026-07-29: previously documented as "nil/0 when created via legacy
    /// phone-number signup, i.e. NOT guaranteed" — that is now stale. The
    /// server assigns a non-zero extension on EVERY registration path
    /// (fast-setup, SMS-OTP register/login, extension-only registration)
    /// as of the SMS-OTP rollout. `nil`/0 can still occur for accounts
    /// created BEFORE that rollout (not backfilled) — this field stays
    /// `Optional` for that reason, not because new accounts are exempt.
    /// See the matching note on ``PublicUser/extensionNumber``.
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

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

    /// Audit P0 #2.12 — server-side GDPR data export. Returns the
    /// raw JSON envelope; caller merges this with its local archive.
    public func accountExport() async throws -> Data {
        return try await rest.get("/api/v1/account/export")
    }

    /// Audit P0 #2.12 — server-side account deletion. 204 on success.
    /// Caller MUST treat the JWT as invalidated even on error.
    public func deleteAccount() async throws {
        _ = try await rest.delete("/api/v1/account")
    }

    /// Audit P0 #2.11 — per-device revocation. The deviceId path
    /// component MUST be linked to the authenticated user (server
    /// returns 403 otherwise).
    public func revokeDevice(deviceId: String) async throws {
        _ = try await rest.delete("/api/v1/devices/\(deviceId)")
    }

    public func getProfile() async throws -> UserProfile {
        let data = try await rest.get("/api/v1/profile")
        return try JSONDecoder().decode(UserProfile.self, from: data)
    }

    /// W414 — dial-by-extension lookup. Resolves a short PBX extension
    /// (e.g. 175) to a `UserProfile` so the iOS DialPad can call
    /// `startCall(contactId: profile.userId, ...)` instead of passing
    /// the raw extension string (which the server cannot route since
    /// `recipient_id` must be the BCrypto userId).
    ///
    /// Server endpoint: `GET /api/v1/directory/by-extension/{n}`.
    /// Returns `nil` on 404 (extension not assigned), throws on other
    /// errors (auth, network, malformed response).
    public func lookupByExtension(_ ext: Int64) async throws -> UserProfile? {
        let path = "/api/v1/directory/by-extension/\(ext)"
        do {
            let data = try await rest.get(path)
            return try JSONDecoder().decode(UserProfile.self, from: data)
        } catch BCryptoError.httpError(let status) where status == 404 {
            return nil
        } catch BCryptoError.notFound {
            return nil
        } catch {
            throw error
        }
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

    /// Registers an APNs VoIP push token (PushKit) with the bcrypto-server.
    /// Wave 2B-3 / WIRE_SPEC §3.8.1.
    ///
    /// Use this in preference to ``registerPushToken(_:platform:)`` for iOS
    /// devices that integrate `PushKit` for incoming-call wakeup. The
    /// server stores the token in its `push_tokens` bucket alongside any
    /// existing FCM token; the dispatcher will route call_offer events to
    /// APNs HTTP/2 instead of FCM when this is present (commit `3ceccf4`
    /// `FanOutCallOffer`).
    ///
    /// - Parameters:
    ///   - voipTokenHex: 64-character hex string of the 32-byte device
    ///     token returned by `PushKit` (`PKPushCredentials.token` ->
    ///     `map { String(format: "%02x", $0) }.joined()`).
    ///   - bundleId: typically `com.bcrypto.qaudion.voip` — must match the
    ///     server's `BCRYPTO_APNS_BUNDLE_ID` env var when configured.
    public func registerApnsVoipToken(_ voipTokenHex: String, bundleId: String) async throws {
        precondition(voipTokenHex.count == 64, "voip token must be 64 hex chars (32 bytes)")
        let dict: [String: Any] = [
            "voip_token": voipTokenHex,
            "bundle_id": bundleId,
        ]
        let body = try JSONSerialization.data(withJSONObject: dict)
        _ = try await rest.post("/api/v1/account/apns-voip-token", body: body)
    }

    public func recoverySetup(recoveryHash: String) async throws -> Bool {
        let body = try JSONSerialization.data(withJSONObject: ["recovery_hash": recoveryHash])
        let data = try await rest.post("/api/v1/auth/recovery-setup", body: body)
        let response = try JSONDecoder().decode(RecoverySetupResponse.self, from: data)
        if let error = response.error { throw BCryptoError.server(error) }
        return response.enrolled
    }

    public func recoveryVerify(identifier: String, recoverySecret: String, deviceName: String) async throws -> AuthCredentials {
        let dict: [String: Any] = [
            "identifier": identifier,
            "recovery_secret": recoverySecret,
            "device_name": deviceName,
        ]
        let body = try JSONSerialization.data(withJSONObject: dict)
        let data = try await rest.post("/api/v1/auth/recovery-verify", body: body)
        return try JSONDecoder().decode(AuthCredentials.self, from: data)
    }

    public func getPublicUser(userId: String) async throws -> PublicUser {
        let data = try await rest.get("/api/v1/users/\(userId)")
        return try JSONDecoder().decode(PublicUser.self, from: data)
    }

    /// W-ORPHANPEER — 404 becomes `nil`, everything else still throws. Body
    /// deliberately identical in shape to `lookupByExtension` above: a genuine
    /// "not found" reaches us only as `BCryptoError.httpError(404)` (nothing
    /// in `BCryptoRestClient` ever throws `.notFound`, but it is matched too
    /// so a later change there cannot silently turn absences into errors).
    public func getPublicUserIfExists(userId: String) async throws -> PublicUser? {
        do {
            let data = try await rest.get("/api/v1/users/\(userId)")
            return try JSONDecoder().decode(PublicUser.self, from: data)
        } catch BCryptoError.httpError(let status) where status == 404 {
            return nil
        } catch BCryptoError.notFound {
            return nil
        } catch {
            throw error
        }
    }

    // MARK: - SMS-OTP + extension-only registration (2026-07-29)

    public func requestOtp(phoneNumber: String, purpose: OtpPurpose) async throws -> OtpRequestResponse {
        let dict: [String: Any] = ["phone_number": phoneNumber, "purpose": purpose.rawValue]
        let body = try JSONSerialization.data(withJSONObject: dict)
        let data = try await rest.post("/api/v1/auth/otp/request", body: body)
        return try JSONDecoder().decode(OtpRequestResponse.self, from: data)
    }

    public func verifyOtp(phoneNumber: String, code: String, purpose: OtpPurpose, deviceName: String,
                           inviteCode: String?, displayName: String?) async throws -> OtpAuthResult {
        var dict: [String: Any] = [
            "phone_number": phoneNumber,
            "code": code,
            "purpose": purpose.rawValue,
            "device_name": deviceName,
            "platform": "ios",
        ]
        if let invite = inviteCode, !invite.isEmpty { dict["invite_code"] = invite }
        if let name = displayName, !name.isEmpty { dict["display_name"] = name }
        let body = try JSONSerialization.data(withJSONObject: dict)
        let data = try await rest.post("/api/v1/auth/otp/verify", body: body)
        return try JSONDecoder().decode(OtpAuthResult.self, from: data)
    }

    public func registerExtensionOnly(displayName: String?, email: String) async throws -> OtpAuthResult {
        var dict: [String: Any] = ["email": email, "platform": "ios"]
        if let name = displayName, !name.isEmpty { dict["display_name"] = name }
        let body = try JSONSerialization.data(withJSONObject: dict)
        let data = try await rest.post("/api/v1/auth/register/extension", body: body)
        do {
            return try JSONDecoder().decode(OtpAuthResult.self, from: data)
        } catch {
            // 2026-08-06 diagnostic -- a Simulator-only decode failure was
            // reported here with zero visibility into what actually came
            // back (network layer confirmed 200 + full body via
            // CFNETWORK_DIAGNOSTICS, but the raw bytes were never logged).
            // print() is captured by RuntimeLogSink's stdout tee even from
            // this package (no RTLog here -- app-layer only). Remove once
            // root-caused, or keep as a general decode-failure diagnostic.
            let preview = String(data: data.prefix(2000), encoding: .utf8) ?? "<non-UTF8, \(data.count) bytes>"
            print("[BCryptoAccountApiImpl] registerExtensionOnly decode failed: \(error). Raw response (\(data.count) bytes): \(preview)")
            throw error
        }
    }

    public func requestEmailVerification(email: String) async throws -> EmailVerifyRequestResponse {
        let dict: [String: Any] = ["email": email]
        let body = try JSONSerialization.data(withJSONObject: dict)
        let data = try await rest.post("/api/v1/auth/email/verify-request", body: body)
        return try JSONDecoder().decode(EmailVerifyRequestResponse.self, from: data)
    }

    public func confirmEmailVerification(token: String) async throws -> EmailVerifyConfirmResponse {
        let dict: [String: Any] = ["token": token]
        let body = try JSONSerialization.data(withJSONObject: dict)
        let data = try await rest.post("/api/v1/auth/email/verify-confirm", body: body)
        return try JSONDecoder().decode(EmailVerifyConfirmResponse.self, from: data)
    }

    @available(*, deprecated, message: "Use PhoneHash.hash(_:) — matches Android PhoneHashHelper byte-for-byte. This forwarder is kept only to avoid breaking callers in the in-progress BCrypto workstream.")
    public static func hashPhone(_ phone: String) -> String {
        // Forward to the canonical helper. Falls back to raw-hex only if
        // normalization fails (legacy callers sometimes pass already-E.164
        // input where invalidE164 would be spurious — callers should migrate).
        return PhoneHash.hashOrNil(phone) ?? PhoneHash.sha256Hex(phone)
    }
}

private struct RecoverySetupResponse: Codable {
    let enrolled: Bool
    let error: String?
}

import Foundation
import CryptoKit

/// Phase 2 of the 2026-05-06 session-renewal design — iOS client.
///
/// Talks to `/api/v1/auth/device-challenge` and `/auth/device-renew`
/// using the Ed25519 device-key managed by `DeviceKeyManager`. Domain
/// separation is enforced by the `QAUDION-DEVICE-RENEW-v1` prefix in
/// the canonical signed blob — see `DeviceRenewBlob.swift`.
///
/// Mirror of:
///   - Android   : `core-data/auth/DeviceRenewClient.kt`
///   - Desktop   : `src/main/transport/DeviceRenewClient.ts`
///   - Go server : `cmd/bcrypto-lite/device_renew_handlers.go`
///
/// `@unchecked Sendable` because the type is final + the only mutable
/// state lives inside the underlying RestClient (which already
/// serialises concurrent refresh attempts via OSAllocatedUnfairLock).
public final class BCryptoDeviceRenewClient: @unchecked Sendable {

    public struct RenewedTokens: Sendable {
        public let accessToken: String
        public let refreshToken: String
        public let userId: String
        public let deviceId: String
        public let expiresInSec: Int
    }

    public enum Error: Swift.Error {
        /// `DeviceKeyManager.ensureProvisioned()` was never called (or
        /// failed) so the Ed25519 seed is not yet on disk.
        case ed25519PrivateNotProvisioned
        /// Server responded with a non-2xx status; underlying HTTP code in
        /// `BCryptoError.httpError`.
        case serverRejected(BCryptoError)
        case malformedNonceHex
    }

    private let rest: BCryptoRestClient
    private let deviceKeyManager: DeviceKeyManager

    public init(rest: BCryptoRestClient, deviceKeyManager: DeviceKeyManager) {
        self.rest = rest
        self.deviceKeyManager = deviceKeyManager
    }

    /// Run the cascade. Returns the fresh tokens; caller is responsible
    /// for calling `BackendConfig.update(...)` so subsequent REST calls
    /// pick up the new bearer.
    public func renew(deviceId: String) async throws -> RenewedTokens {
        guard let edPriv = try deviceKeyManager.currentEd25519Priv() else {
            throw Error.ed25519PrivateNotProvisioned
        }

        // 1. Fetch challenge.
        let challengeData = try await rest.get(
            "/api/v1/auth/device-challenge?device_id=\(urlEncode(deviceId))"
        )
        let challenge = try JSONDecoder().decode(ChallengeResp.self, from: challengeData)
        guard let nonceBytes = DeviceRenewBlob.hexDecode(challenge.nonceHex),
              nonceBytes.count == DeviceRenewBlob.nonceLenBytes else {
            throw Error.malformedNonceHex
        }

        // 2. Build canonical blob + sign with Ed25519.
        // Use Int64 on the wire (Go server's struct tag is `int64`).
        // Cross-platform JSON safe: max signed 64-bit fits comfortably.
        let epochMs = Int64(Date().timeIntervalSince1970 * 1000)
        let blob = DeviceRenewBlob.buildRenew(
            serverId: challenge.serverId,
            deviceId: deviceId,
            nonce: nonceBytes,
            epochMs: UInt64(bitPattern: epochMs)
        )
        let priv = try Curve25519.Signing.PrivateKey(rawRepresentation: edPriv)
        let signature = try priv.signature(for: blob)
        let sigHex = DeviceRenewBlob.hexEncode(signature)

        // 3. POST /auth/device-renew.
        let body = try JSONSerialization.data(withJSONObject: [
            "device_id": deviceId,
            "epoch_ms": epochMs,
            "signature_hex": sigHex,
        ])
        let respData: Data
        do {
            respData = try await rest.post("/api/v1/auth/device-renew", body: body)
        } catch let err as BCryptoError {
            throw Error.serverRejected(err)
        }
        let resp = try JSONDecoder().decode(RenewResp.self, from: respData)
        return RenewedTokens(
            accessToken: resp.accessToken,
            refreshToken: resp.refreshToken,
            userId: resp.userId,
            deviceId: resp.deviceId,
            expiresInSec: resp.expiresIn
        )
    }

    /// Two-factor revocation: bearer token of THIS device + Ed25519
    /// signature over the canonical revoke blob. Server kicks the
    /// target's WS and invalidates its refresh tokens.
    public func revoke(targetDeviceId: String, requestingDeviceId: String) async throws -> Int64 {
        guard let edPriv = try deviceKeyManager.currentEd25519Priv() else {
            throw Error.ed25519PrivateNotProvisioned
        }

        let challengeData = try await rest.get(
            "/api/v1/auth/device-challenge?device_id=\(urlEncode(requestingDeviceId))"
        )
        let challenge = try JSONDecoder().decode(ChallengeResp.self, from: challengeData)
        guard let nonceBytes = DeviceRenewBlob.hexDecode(challenge.nonceHex),
              nonceBytes.count == DeviceRenewBlob.nonceLenBytes else {
            throw Error.malformedNonceHex
        }

        let epochMs = Int64(Date().timeIntervalSince1970 * 1000)
        let blob = DeviceRenewBlob.buildRevoke(
            requestingDeviceId: requestingDeviceId,
            targetDeviceId: targetDeviceId,
            nonce: nonceBytes,
            epochMs: UInt64(bitPattern: epochMs)
        )
        let priv = try Curve25519.Signing.PrivateKey(rawRepresentation: edPriv)
        let signature = try priv.signature(for: blob)
        let sigHex = DeviceRenewBlob.hexEncode(signature)

        let body = try JSONSerialization.data(withJSONObject: [
            "target_device_id": targetDeviceId,
            "requesting_device_id": requestingDeviceId,
            "nonce_hex": challenge.nonceHex,
            "epoch_ms": epochMs,
            "signature_hex": sigHex,
        ])
        let respData = try await rest.post("/api/v1/auth/revoke-device", body: body)
        let resp = try JSONDecoder().decode(RevokeResp.self, from: respData)
        return resp.revokedAt
    }

    // MARK: - Wire types (match Go struct tags exactly)

    private struct ChallengeResp: Decodable {
        let nonceHex: String
        let serverId: String
        let ttl: Int

        private enum CodingKeys: String, CodingKey {
            case nonceHex = "nonce_hex"
            case serverId = "server_id"
            case ttl
        }
    }

    private struct RenewResp: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int
        let tokenType: String
        let userId: String
        let deviceId: String

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case tokenType = "token_type"
            case userId = "user_id"
            case deviceId = "device_id"
        }
    }

    private struct RevokeResp: Decodable {
        let revokedAt: Int64

        private enum CodingKeys: String, CodingKey {
            case revokedAt = "revoked_at"
        }
    }

    private func urlEncode(_ s: String) -> String {
        return s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }
}

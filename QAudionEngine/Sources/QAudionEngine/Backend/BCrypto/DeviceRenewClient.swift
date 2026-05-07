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
public final class BCryptoDeviceRenewClient {

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
        guard let nonceBytes = DeviceRenewBlob.hexDecode(challenge.nonce_hex),
              nonceBytes.count == DeviceRenewBlob.nonceLenBytes else {
            throw Error.malformedNonceHex
        }

        // 2. Build canonical blob + sign with Ed25519.
        let epochMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let blob = DeviceRenewBlob.buildRenew(
            serverId: challenge.server_id,
            deviceId: deviceId,
            nonce: nonceBytes,
            epochMs: epochMs
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
            accessToken: resp.access_token,
            refreshToken: resp.refresh_token,
            userId: resp.user_id,
            deviceId: resp.device_id,
            expiresInSec: resp.expires_in
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
        guard let nonceBytes = DeviceRenewBlob.hexDecode(challenge.nonce_hex),
              nonceBytes.count == DeviceRenewBlob.nonceLenBytes else {
            throw Error.malformedNonceHex
        }

        let epochMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let blob = DeviceRenewBlob.buildRevoke(
            requestingDeviceId: requestingDeviceId,
            targetDeviceId: targetDeviceId,
            nonce: nonceBytes,
            epochMs: epochMs
        )
        let priv = try Curve25519.Signing.PrivateKey(rawRepresentation: edPriv)
        let signature = try priv.signature(for: blob)
        let sigHex = DeviceRenewBlob.hexEncode(signature)

        let body = try JSONSerialization.data(withJSONObject: [
            "target_device_id": targetDeviceId,
            "requesting_device_id": requestingDeviceId,
            "nonce_hex": challenge.nonce_hex,
            "epoch_ms": epochMs,
            "signature_hex": sigHex,
        ])
        let respData = try await rest.post("/api/v1/auth/revoke-device", body: body)
        let resp = try JSONDecoder().decode(RevokeResp.self, from: respData)
        return resp.revoked_at
    }

    // MARK: - Wire types (match Go struct tags exactly)

    private struct ChallengeResp: Decodable {
        let nonce_hex: String
        let server_id: String
        let ttl: Int
    }

    private struct RenewResp: Decodable {
        let access_token: String
        let refresh_token: String
        let expires_in: Int
        let token_type: String
        let user_id: String
        let device_id: String
    }

    private struct RevokeResp: Decodable {
        let revoked_at: Int64
    }

    private func urlEncode(_ s: String) -> String {
        return s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }
}

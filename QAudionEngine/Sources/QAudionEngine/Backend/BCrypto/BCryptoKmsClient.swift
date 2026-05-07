import Foundation

/// KMS (Key Management Service) client for device key registration and key provisioning.
/// Matches server endpoints: /api/v1/device/publickey, /api/v1/kms/pending, /api/v1/kms/acknowledge
///
/// Payload/envelope shapes are pinned to Android `BCryptoApi.kt` +
/// `KmsDto.kt` (see `docs/progress/PHASE1_REST_AUDIT.md` §3.9 / §3.10).
public final class BCryptoKmsClient {
    private let rest: BCryptoRestClient

    public init(rest: BCryptoRestClient) { self.rest = rest }

    /// Register device public key(s) with server.
    /// POST /api/v1/device/publickey
    ///
    /// Android `DevicePublicKeyRequest`: `{ public_key,
    /// mlkem_encapsulation_key?, key_type }`. The server derives the
    /// device id from the auth token, so iOS must NOT include an
    /// extra `device_id` field.
    ///
    /// When `mlkemEncapKey` is non-nil the server-side
    /// `device_pq_keys` bbolt bucket gets populated and the dashboard
    /// admin will subsequently emit binding-hybrid (92-byte) packages
    /// for this device. With only the X25519 public key registered,
    /// the admin path falls back to classical (60-byte) packages.
    /// WIRE_SPEC.md §2.6.
    ///
    /// The legacy KEM-hybrid path (1628+ byte packages with full
    /// ML-KEM ciphertext) does NOT need any extra registration —
    /// the server emits them only for compatibility with
    /// pre-binding-rollout clients.
    public func registerPublicKey(
        publicKey: Data,
        mlkemEncapKey: Data? = nil,
        keyType: String = "x25519",
        ed25519PubKey: Data? = nil
    ) async throws {
        var dict: [String: Any] = [
            "public_key": publicKey.base64EncodedString(),
            "key_type": keyType
        ]
        if let mlkemEncapKey = mlkemEncapKey {
            dict["mlkem_encapsulation_key"] = mlkemEncapKey.base64EncodedString()
        }
        // 2026-05-06 session-renewal Phase 2 — optional Ed25519 device
        // signing pubkey (32 bytes base64). Server stores it under
        // `device_ed25519_keys` and uses it to verify
        // `/api/v1/auth/device-renew` blobs. Backwards-compat: older
        // servers ignore the field; our server stores it under a new
        // bucket and emits an `ed25519_stored: true` flag in the
        // response we currently discard.
        if let edPub = ed25519PubKey, edPub.count == 32 {
            dict["ed25519_pubkey"] = edPub.base64EncodedString()
        }
        let body = try JSONSerialization.data(withJSONObject: dict)
        _ = try await rest.post("/api/v1/device/publickey", body: body)
    }

    /// Get pending KMS keys for this device.
    /// GET /api/v1/kms/pending
    ///
    /// Android `KmsPendingResponse` wraps the array in a `keys` field.
    /// The per-entry DTO `KmsKeyDto` exposes `encrypted_package` +
    /// `fingerprint` + `ephemeral_pubkey` + `nonce` — not `encrypted_key` +
    /// `algorithm` which the old iOS shape assumed.
    public func getPendingKeys() async throws -> [PendingKey] {
        let data = try await rest.get("/api/v1/kms/pending")
        let response = try JSONDecoder().decode(PendingKeysResponse.self, from: data)
        return response.keys
    }

    /// Acknowledge receipt of a KMS key.
    /// POST /api/v1/kms/acknowledge/{keyId}
    public func acknowledgeKey(keyId: String) async throws {
        _ = try await rest.post("/api/v1/kms/acknowledge/\(keyId)", body: nil)
    }
}

/// Single pending-key entry. Matches Android `KmsKeyDto`.
public struct PendingKey: Codable {
    public let keyId: String
    public let keyName: String
    public let fingerprint: String
    public let status: String
    public let encryptedPackage: String
    public let ephemeralPubkey: String
    public let nonce: String
    public let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case keyId = "key_id"
        case keyName = "key_name"
        case fingerprint
        case status
        case encryptedPackage = "encrypted_package"
        case ephemeralPubkey = "ephemeral_pubkey"
        case nonce
        case createdAt = "created_at"
    }

    public init(
        keyId: String,
        keyName: String,
        fingerprint: String,
        status: String = "pending",
        encryptedPackage: String,
        ephemeralPubkey: String,
        nonce: String,
        createdAt: String? = nil
    ) {
        self.keyId = keyId
        self.keyName = keyName
        self.fingerprint = fingerprint
        self.status = status
        self.encryptedPackage = encryptedPackage
        self.ephemeralPubkey = ephemeralPubkey
        self.nonce = nonce
        self.createdAt = createdAt
    }
}

private struct PendingKeysResponse: Codable {
    let keys: [PendingKey]
}

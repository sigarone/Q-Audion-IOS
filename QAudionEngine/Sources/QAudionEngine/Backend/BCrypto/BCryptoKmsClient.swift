import Foundation

/// KMS (Key Management Service) client for device key registration and key provisioning.
/// Matches server endpoints: /api/v1/device/publickey, /api/v1/kms/pending, /api/v1/kms/acknowledge
///
/// Payload/envelope shapes are pinned to Android `BCryptoApi.kt` +
/// `KmsDto.kt` (see `docs/progress/PHASE1_REST_AUDIT.md` §3.9 / §3.10).
public final class BCryptoKmsClient {
    private let rest: BCryptoRestClient

    public init(rest: BCryptoRestClient) { self.rest = rest }

    /// Register device public key with server.
    /// POST /api/v1/device/publickey
    ///
    /// Android `DevicePublicKeyRequest`: `{ public_key, key_type }`. The
    /// server derives the device id from the auth token, so iOS must
    /// NOT include an extra `device_id` field. Default key type matches
    /// Android's x25519 (post-quantum hybrid handshake uses x25519 +
    /// ML-KEM-1024).
    public func registerPublicKey(publicKey: Data, keyType: String = "x25519") async throws {
        let dict: [String: Any] = [
            "public_key": publicKey.base64EncodedString(),
            "key_type": keyType
        ]
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

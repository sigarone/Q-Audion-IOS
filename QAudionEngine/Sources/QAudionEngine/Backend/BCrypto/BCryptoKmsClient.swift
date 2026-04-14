import Foundation

/// KMS (Key Management Service) client for device key registration and key provisioning.
/// Matches server endpoints: /api/v1/device/publickey, /api/v1/kms/pending, /api/v1/kms/acknowledge
public final class BCryptoKmsClient {
    private let rest: BCryptoRestClient

    public init(rest: BCryptoRestClient) { self.rest = rest }

    /// Register device public key with server.
    /// POST /api/v1/device/publickey
    public func registerPublicKey(deviceId: String, publicKey: Data, keyType: String = "P-256") async throws {
        let dict: [String: Any] = [
            "device_id": deviceId,
            "public_key": publicKey.base64EncodedString(),
            "key_type": keyType
        ]
        let body = try JSONSerialization.data(withJSONObject: dict)
        _ = try await rest.post("/api/v1/device/publickey", body: body)
    }

    /// Get pending KMS keys for this device.
    /// GET /api/v1/kms/pending
    public func getPendingKeys() async throws -> [PendingKey] {
        let data = try await rest.get("/api/v1/kms/pending")
        return try JSONDecoder().decode([PendingKey].self, from: data)
    }

    /// Acknowledge receipt of a KMS key.
    /// POST /api/v1/kms/acknowledge/{keyId}
    public func acknowledgeKey(keyId: String) async throws {
        _ = try await rest.post("/api/v1/kms/acknowledge/\(keyId)", body: nil)
    }
}

public struct PendingKey: Codable {
    public let keyId: String
    public let encryptedKey: String
    public let algorithm: String
    public let createdAt: String

    enum CodingKeys: String, CodingKey {
        case keyId = "key_id"
        case encryptedKey = "encrypted_key"
        case algorithm
        case createdAt = "created_at"
    }
}

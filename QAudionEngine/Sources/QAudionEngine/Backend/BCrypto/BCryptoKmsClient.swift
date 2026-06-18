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
        ed25519PubKey: Data? = nil,
        kmsProtoVersion: Int = 2
    ) async throws {
        // KMS Rotation v2 (§3.6): advertise the proto version so the
        // server emits v1 (no-AAD) packages to legacy devices and v2
        // (AAD-bound, real-hybrid) packages to upgraded ones. Mixed
        // fleet supported during rollout. The ML-KEM encapsulation key
        // field name is the FROZEN `mlkem_encapsulation_key` (§3.0).
        var dict: [String: Any] = [
            "public_key": publicKey.base64EncodedString(),
            "key_type": keyType,
            "kms_proto_version": kmsProtoVersion
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

    /// Acknowledge receipt of a KMS key (v1 / legacy path).
    /// POST /api/v1/kms/acknowledge/{keyId}
    public func acknowledgeKey(keyId: String) async throws {
        _ = try await rest.post("/api/v1/kms/acknowledge/\(keyId)", body: nil)
    }

    /// §3.6 POST /api/v1/kms/ack-pop response.
    ///
    /// FROZEN 2026-06-16 (§3.0): `epoch` is a DECIMAL STRING (uint64
    /// exceeds JS safe-integer range; cross-platform parity). Callers
    /// parse it with `UInt64(resp.epoch)`.
    public struct AckPopResponse: Codable {
        public let verified: Bool
        public let commit: Bool
        public let epoch: String
    }

    /// Build the §3.6 ack-pop request body. `static` so it is unit-testable
    /// without a live REST client. `epoch` is serialized as a DECIMAL
    /// STRING (§3.0 freeze).
    public static func encodeAckPopBody(
        keyId: String, deviceId: String, epoch: UInt64, txnId: String, popB64: String
    ) throws -> Data {
        let dict: [String: Any] = [
            "key_id": keyId,
            "device_id": deviceId,
            "epoch": String(epoch),
            "txn_id": txnId,
            "pop": popB64
        ]
        return try JSONSerialization.data(withJSONObject: dict)
    }

    /// §3.6 POST /api/v1/kms/ack-pop — replaces the bare /acknowledge for
    /// v2 devices. Returns the server's verify/commit verdict. The server
    /// ignores the request `epoch` for verification (reads its ledger
    /// row); we still send it per the wire shape.
    public func ackPop(
        keyId: String, deviceId: String, epoch: UInt64, txnId: String, pop: Data
    ) async throws -> AckPopResponse {
        let body = try Self.encodeAckPopBody(
            keyId: keyId, deviceId: deviceId, epoch: epoch,
            txnId: txnId, popB64: pop.base64EncodedString())
        let data = try await rest.post("/api/v1/kms/ack-pop", body: body)
        return try JSONDecoder().decode(AckPopResponse.self, from: data)
    }

    /// Acknowledge earbud-exclusive hw_only key delivery with SE PoP.
    /// POST /api/v1/kms/earbud-ack-pop
    ///
    /// CL-5.4 — frozen server contract (FLAG-2):
    ///   key_id  = rowID (entry.keyId)  — server looks up the row by PK
    ///   txn_id  = keyIDStr (entry.txnId) — matches the PoP-INPUTS frame binding
    ///
    /// The PoP-INPUTS frame uses uuid16(txnId) in BOTH the +0 and +16 slots
    /// (FLAG-2 contract). The ACK body uses keyId for the DB lookup and txnId
    /// for the server's ExpectedPoP verification — they differ for earbud_pair
    /// rows where rowID != keyIDStr.
    public func earbudAckPop(
        keyId: String,      // rowID = entry.keyId (server PK for row lookup)
        earbudId: String,   // hex of SHA-256(pkSe)
        epoch: String,      // decimal epoch string
        txnId: String,      // keyIDStr = entry.txnId (PoP-INPUTS binding)
        pop: Data           // 32B SE PoP
    ) async throws {
        let dict: [String: Any] = [
            "key_id": keyId,
            "earbud_id": earbudId,
            "epoch": epoch,
            "txn_id": txnId,
            "pop": pop.base64EncodedString()
        ]
        let body = try JSONSerialization.data(withJSONObject: dict)
        _ = try await rest.post("/api/v1/kms/earbud-ack-pop", body: body)
    }
}

/// Single pending-key entry. Matches Android `KmsKeyDto`.
///
/// v2 (KMS Rotation v2, §3.1) extends this with the rotation primitives
/// (`key_class`/`key_epoch`/`slot_id`/`txn_id`/`supersedes`/`server_nonce`)
/// and the server-authoritative identity bytes (`user_id`/`device_id`)
/// the client MUST use verbatim for the AAD + PoP. All v2 fields are
/// OPTIONAL so a legacy v1 entry (none of them present) still decodes;
/// `proto_version` defaults to 1 when absent.
public struct PendingKey: Codable {
    public let keyId: String
    public let keyName: String
    public let fingerprint: String
    public let status: String
    public let encryptedPackage: String
    public let ephemeralPubkey: String
    public let nonce: String
    public let createdAt: String?
    // -- v2 fields (§3.1). Optional so v1 (legacy) entries still decode. --
    public let keyType: String?
    public let earbudId: String?
    public let keyClass: String?
    public let keyEpoch: String?      // decimal uint64 STRING
    public let slotId: String?
    public let txnId: String?
    public let supersedes: String?
    public let serverNonce: String?   // base64, 16 bytes
    /// FROZEN 2026-06-16 (§3.0): server-authoritative identity bytes used
    /// verbatim in this row's AES-GCM AAD + the qa-kms-pop-v1 PoP. The
    /// client NEVER sources these locally for a v2 entry.
    public let userId: String?
    public let deviceId: String?
    public let protoVersion: Int

    enum CodingKeys: String, CodingKey {
        case keyId = "key_id"
        case keyName = "key_name"
        case fingerprint
        case status
        case encryptedPackage = "encrypted_package"
        case ephemeralPubkey = "ephemeral_pubkey"
        case nonce
        case createdAt = "created_at"
        case keyType = "key_type"
        case earbudId = "earbud_id"
        case keyClass = "key_class"
        case keyEpoch = "key_epoch"
        case slotId = "slot_id"
        case txnId = "txn_id"
        case supersedes
        case serverNonce = "server_nonce"
        case userId = "user_id"
        case deviceId = "device_id"
        case protoVersion = "proto_version"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyId = try c.decode(String.self, forKey: .keyId)
        keyName = try c.decode(String.self, forKey: .keyName)
        fingerprint = try c.decode(String.self, forKey: .fingerprint)
        status = try c.decode(String.self, forKey: .status)
        encryptedPackage = try c.decode(String.self, forKey: .encryptedPackage)
        ephemeralPubkey = (try? c.decode(String.self, forKey: .ephemeralPubkey)) ?? ""
        nonce = (try? c.decode(String.self, forKey: .nonce)) ?? ""
        createdAt = try? c.decode(String.self, forKey: .createdAt)
        keyType = try? c.decode(String.self, forKey: .keyType)
        earbudId = try? c.decode(String.self, forKey: .earbudId)
        keyClass = try? c.decode(String.self, forKey: .keyClass)
        keyEpoch = try? c.decode(String.self, forKey: .keyEpoch)
        slotId = try? c.decode(String.self, forKey: .slotId)
        txnId = try? c.decode(String.self, forKey: .txnId)
        supersedes = try? c.decode(String.self, forKey: .supersedes)
        serverNonce = try? c.decode(String.self, forKey: .serverNonce)
        userId = try? c.decode(String.self, forKey: .userId)
        deviceId = try? c.decode(String.self, forKey: .deviceId)
        protoVersion = (try? c.decode(Int.self, forKey: .protoVersion)) ?? 1
    }

    public init(
        keyId: String, keyName: String, fingerprint: String, status: String = "pending",
        encryptedPackage: String, ephemeralPubkey: String, nonce: String,
        createdAt: String? = nil, keyType: String? = nil, earbudId: String? = nil,
        keyClass: String? = nil, keyEpoch: String? = nil, slotId: String? = nil,
        txnId: String? = nil, supersedes: String? = nil, serverNonce: String? = nil,
        userId: String? = nil, deviceId: String? = nil, protoVersion: Int = 1
    ) {
        self.keyId = keyId; self.keyName = keyName; self.fingerprint = fingerprint
        self.status = status; self.encryptedPackage = encryptedPackage
        self.ephemeralPubkey = ephemeralPubkey; self.nonce = nonce; self.createdAt = createdAt
        self.keyType = keyType; self.earbudId = earbudId; self.keyClass = keyClass
        self.keyEpoch = keyEpoch; self.slotId = slotId; self.txnId = txnId
        self.supersedes = supersedes; self.serverNonce = serverNonce
        self.userId = userId; self.deviceId = deviceId
        self.protoVersion = protoVersion
    }
}

private struct PendingKeysResponse: Codable {
    let keys: [PendingKey]
}

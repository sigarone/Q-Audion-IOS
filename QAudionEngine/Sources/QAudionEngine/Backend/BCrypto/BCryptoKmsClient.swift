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

    /// Publish the user-level Ed25519 identity key.
    /// POST /api/v1/users/me/identity-key
    ///
    /// This is distinct from the device key registered via `registerPublicKey`.
    /// Callee clients (Android, iOS) call GET /api/v1/users/{id}/identity-key
    /// during call setup to verify the caller's identity. Without this
    /// registration the callee receives a 404 and hangs up immediately.
    ///
    /// Idempotent — a second publish overwrites the previous record server-side.
    public func publishUserIdentityKey(ed25519PubKey: Data, deviceId: String) async throws {
        precondition(ed25519PubKey.count == 32, "Ed25519 public key must be 32 bytes")
        let dict: [String: Any] = [
            "public_key_b64": ed25519PubKey.base64EncodedString(),
            "alg": "Ed25519",
            "device_id": deviceId
        ]
        let body = try JSONSerialization.data(withJSONObject: dict)
        _ = try await rest.post("/api/v1/users/me/identity-key", body: body)
    }

    /// XC-3 (2026-08-05, v2 bundle parity follow-up) — publish the FULL v2
    /// identity bundle: the PQ (ML-KEM-1024) and X25519 long-term legs, plus
    /// a self-signature over `IdentityKeyV2Preimage.buildV2`'s canonical
    /// preimage. Same endpoint as the v1 publish above (`version` in the
    /// body is what routes the server to the v2 path), same field names as
    /// Android `DeviceKeyProvisioner.publishIdentityBundleV2` / Desktop
    /// `IdentityKeyStore`'s v2 publish (server
    /// `cmd/bcrypto-lite/users_identity_key.go::handlePublishIdentityKeyV2`).
    ///
    /// `uuid` is deliberately NOT sent — the server derives it from the JWT
    /// (`claims.UserID`), never from client input, so the CALLER's local
    /// preimage must already have been built with that same uuid (see
    /// `AppState.publishIdentityKeyWithRetry`) or the self-sig verify (server-
    /// side, over the server's OWN uuid) will fail with 400 `self_sig invalid`.
    public func publishUserIdentityBundleV2(
        ed25519Pub: Data, ikPqPub: Data, ikX25519Pub: Data, selfSig: Data, createdAtMs: Int64
    ) async throws {
        precondition(ed25519Pub.count == 32, "Ed25519 public key must be 32 bytes")
        precondition(ikX25519Pub.count == 32, "X25519 public key must be 32 bytes")
        precondition(selfSig.count == 64, "self-signature must be 64 bytes")
        let dict: [String: Any] = [
            "public_key_b64": ed25519Pub.base64EncodedString(),
            "alg": "Ed25519",
            "ed25519_pub_b64": ed25519Pub.base64EncodedString(),
            "ik_pq_pub_b64": ikPqPub.base64EncodedString(),
            "ik_x25519_pub_b64": ikX25519Pub.base64EncodedString(),
            "version": 2,
            "created_at_ms": createdAtMs,
            "self_sig_b64": selfSig.base64EncodedString(),
        ]
        let body = try JSONSerialization.data(withJSONObject: dict)
        _ = try await rest.post("/api/v1/users/me/identity-key", body: body)
    }

    /// Fetch a peer's published long-term Ed25519 identity key (RAW 32 bytes),
    /// or `nil` when the peer has not published one (404) or on any transport /
    /// decode error. This is the iOS mirror of Android
    /// `BCryptoApi.fetchIdentityKey` + Desktop `BCryptoApi.fetchIdentityKey`,
    /// used as the spec-§5c "server" trust source for the call handshake
    /// (`integration.resolveServerPeerKey`).
    ///
    /// GET /api/v1/users/{id}/identity-key returns either the v2 bundle
    /// (`ed25519_pub_b64` + ik_* + self_sig) or the v1 fallback shape
    /// (`ed25519_pub_b64` only). Both carry the Ed25519 SIGNING key under
    /// `ed25519_pub_b64`; after the 2026-06-23 publish fix every platform's
    /// published key equals its handshake signing key, so this is a safe
    /// cross-check. Returns nil (never a partial/garbage key) so the caller
    /// falls through to bundle-TOFU on first contact rather than aborting.
    public func fetchUserIdentityKey(userId: String) async -> Data? {
        return await fetchUserIdentityKey(userId: userId, deviceId: nil)
    }

    /// D11 per-device fetch: `GET /api/v1/users/{id}/identity-key?device_id=<id>`.
    /// Returns the SPECIFIC sender device's published Ed25519 key (RAW 32 bytes),
    /// or `nil` on 404 / transport / decode error. The server falls through to
    /// the latest/v1 bundle when that device hasn't published, so a non-nil
    /// result is "the best key the server has for this (user, device)". A nil
    /// `deviceId` is the legacy single-key fetch (no query parameter) — identical
    /// to the bare `fetchUserIdentityKey(userId:)`. Never a partial/garbage key
    /// (caller falls through to bundle-TOFU on first contact rather than aborting).
    public func fetchUserIdentityKey(userId: String, deviceId: String?) async -> Data? {
        guard !userId.isEmpty else { return nil }
        var path = "/api/v1/users/\(userId)/identity-key"
        if let d = deviceId, !d.isEmpty {
            // device_id is a server-stamped UUID (`sender_device_id`), URL-safe,
            // but encode defensively to mirror the Android/Desktop @Query escaping.
            let enc = d.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? d
            path += "?device_id=\(enc)"
        }
        do {
            let data = try await rest.get(path)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let b64: String? = (json["ed25519_pub_b64"] as? String) ?? (json["public_key_b64"] as? String)
            guard let keyB64 = b64,
                  let raw = Data(base64Encoded: keyB64),
                  raw.count == 32 else {
                return nil
            }
            return raw
        } catch {
            return nil
        }
    }

    /// D11 trust-on-publish floor: fetch the SET of a peer's published per-device
    /// Ed25519 identity keys via `GET /api/v1/users/{id}/identity-key?all=1`.
    ///
    /// The server returns `{ "uuid": <id>, "devices": [ { "ed25519_pub_b64": …,
    /// "device_id": …, … }, … ] }` (users_identity_key.go `?all=1` branch). Pre-
    /// rollout publishers with no per-device record fall back server-side to the
    /// single latest bundle, so the array is never empty for a user who has
    /// published anything.
    ///
    /// Returns the set of RAW 32-byte keys (only valid 32-byte entries are kept;
    /// malformed entries are skipped, never a partial key). Returns an EMPTY set
    /// on 404 / transport / decode error — the caller treats an empty set as "no
    /// floor" and degrades to legacy pin-only TOFU (NEVER a fatal mismatch). This
    /// is the iOS mirror of Android `fetchIdentityKey(all=1)` / Desktop
    /// `fetchIdentityKey({all:true})`.
    public func fetchUserIdentityKeySet(userId: String) async -> Set<Data> {
        guard !userId.isEmpty else { return [] }
        do {
            let data = try await rest.get("/api/v1/users/\(userId)/identity-key?all=1")
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return []
            }
            var out = Set<Data>()
            if let devices = json["devices"] as? [[String: Any]] {
                for dev in devices {
                    if let b64 = (dev["ed25519_pub_b64"] as? String) ?? (dev["public_key_b64"] as? String),
                       let raw = Data(base64Encoded: b64), raw.count == 32 {
                        out.insert(raw)
                    }
                }
            }
            // Defensive: a server that doesn't honour ?all=1 returns the single-
            // key shape. Fold it into a 1-element set so the floor still works.
            if out.isEmpty,
               let b64 = (json["ed25519_pub_b64"] as? String) ?? (json["public_key_b64"] as? String),
               let raw = Data(base64Encoded: b64), raw.count == 32 {
                out.insert(raw)
            }
            return out
        } catch {
            return []
        }
    }

    /// ADR-014a §2.3 — full v2 identity bundle for a peer, used by the
    /// group-call KMS-prebootstrap send path (gap A2, see
    /// `AppState.attemptGroupCtrlKmsPreBootstrap`). Unlike
    /// `fetchUserIdentityKey`/`fetchUserIdentityKeySet` (which only read the
    /// Ed25519 signing key), this decodes the FULL v2 bundle the server
    /// already returns from the SAME endpoint: the post-quantum
    /// (ML-KEM-1024) and X25519 long-term public legs plus the self-
    /// signature over them. Mirrors Android
    /// `KmsPreBootstrapSender.ResolvedPeerIdentity` /
    /// `parseAndVerifyIdentityKey` (`feature-chat/.../KmsPreBootstrapSender.kt`
    /// L203-302) and the server response shape (`bcrypto-server`
    /// `cmd/bcrypto-lite/users_identity_key.go` `bundlePayload()` L252-269).
    ///
    /// Returns `nil` on 404 (peer hasn't published), transport error, or a
    /// pre-v2/legacy response missing `ik_pq_pub_b64` (no PQ leg — a
    /// KMS-prebootstrap encap is impossible against that peer; the caller
    /// falls back to the existing default flow). Deliberately does NOT
    /// verify the self-signature — that requires porting Android's
    /// `IdentityKeyV2Preimage` preimage builder + Ed25519 verify, which does
    /// not exist on iOS yet (see the TODO on
    /// `AppState.attemptGroupCtrlKmsPreBootstrap`). Do not treat an
    /// unverified bundle as trusted key material beyond that TODO's scope.
    public struct IdentityBundleV2 {
        public let uuidRaw: Data          // 16B, RFC 4122 raw form
        public let ed25519Pub: Data       // 32B
        public let pqPub: Data            // ~1568B ML-KEM-1024 public key
        public let x25519Pub: Data?       // 32B, nil on a v1-fallback peer
        public let selfSig: Data?         // 64B Ed25519 sig, nil on a pre-self-sig server row
        public let version: Int
        public let createdAtMs: Int64
    }

    public func fetchUserIdentityBundleV2(userId: String) async -> IdentityBundleV2? {
        guard !userId.isEmpty else { return nil }
        do {
            let data = try await rest.get("/api/v1/users/\(userId)/identity-key")
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            guard let edB64 = (json["ed25519_pub_b64"] as? String) ?? (json["public_key_b64"] as? String),
                  let edPub = Data(base64Encoded: edB64), edPub.count == 32 else {
                return nil
            }
            // No PQ leg published (pre-v2 / legacy peer) — a KMS-prebootstrap
            // encap is impossible; caller must fall back to the default flow.
            guard let pqB64 = json["ik_pq_pub_b64"] as? String, !pqB64.isEmpty,
                  let pqPub = Data(base64Encoded: pqB64), !pqPub.isEmpty else {
                return nil
            }
            let x25519Pub: Data? = (json["ik_x25519_pub_b64"] as? String).flatMap { Data(base64Encoded: $0) }
            let selfSig: Data? = (json["self_sig_b64"] as? String).flatMap { Data(base64Encoded: $0) }
            let uuidStr = json["uuid"] as? String ?? userId
            guard let uuidRaw = Self.uuidToRawBytes(uuidStr) else { return nil }
            let version = json["version"] as? Int ?? 1
            let createdAtMs = (json["created_at_ms"] as? NSNumber)?.int64Value ?? 0
            return IdentityBundleV2(
                uuidRaw: uuidRaw,
                ed25519Pub: edPub,
                pqPub: pqPub,
                x25519Pub: x25519Pub,
                selfSig: selfSig,
                version: version,
                createdAtMs: createdAtMs
            )
        } catch {
            return nil
        }
    }

    /// Convert a canonical UUID string to its 16 raw bytes (RFC 4122
    /// §4.1.2), matching Android `KmsPreBootstrapSender.uuidToRaw`. Returns
    /// nil if `uuidStr` is not a well-formed UUID.
    private static func uuidToRawBytes(_ uuidStr: String) -> Data? {
        guard let u = UUID(uuidString: uuidStr) else { return nil }
        return withUnsafeBytes(of: u.uuid) { Data($0) }
    }

    /// One-time prekey DTO — `GET /api/v1/identity/{uuid}/prekey/next`
    /// (ADR-014a §2.3 step 2 / §4.1 sig preimage). Mirrors Android's prekey
    /// DTO (`BCryptoApi.kt` / `KmsPreBootstrapSender.fetchAndVerifyPrekey`)
    /// and the server handler `handleFetchNextPrekey`
    /// (`bcrypto-server/cmd/bcrypto-lite/prekeys.go` L272-341).
    public struct OneTimePrekeyDTO {
        public let prekeyId: UInt32
        public let pqPub: Data        // ~1568B ML-KEM-1024 public key
        public let x25519Pub: Data    // 32B
        public let createdAtMs: Int64
        public let sig: Data          // 64B Ed25519, over sha256(pq_pub||x25519_pub||createdAtMs_be64)
    }

    /// Fetch + atomically consume one of the peer's published one-time
    /// prekeys (server does get-then-delete under a per-target mutex).
    /// Returns `nil` on 204 (pool empty — caller falls back to the peer's
    /// long-term bundle keys per ADR-014a §3.4), 404 (peer doesn't exist),
    /// 429 (rate-limited), 503 (DR read-only replica — see `prekeys.go`
    /// L317-324), transport error, or a malformed response. All of these
    /// collapse to `nil` here because `BCryptoRestClient.get` throws
    /// `BCryptoError.httpError(code)` uniformly for any non-2xx status — the
    /// caller cannot and does not need to distinguish them.
    ///
    /// Deliberately does NOT verify the per-prekey signature — that
    /// requires the same Ed25519-over-SHA256(pq_pub‖x25519_pub‖
    /// createdAtMs_be64) check Android does
    /// (`KmsPreBootstrapSender.fetchAndVerifyPrekey` L318-368) against the
    /// peer's pinned key from `fetchUserIdentityBundleV2`; not implemented
    /// on iOS yet (see the TODO on
    /// `AppState.attemptGroupCtrlKmsPreBootstrap`).
    public func fetchNextPrekey(userId: String) async -> OneTimePrekeyDTO? {
        guard !userId.isEmpty else { return nil }
        do {
            let data = try await rest.get("/api/v1/identity/\(userId)/prekey/next")
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            guard let prekeyIdNum = json["prekey_id"] as? NSNumber,
                  let pqB64 = json["pq_pub_b64"] as? String, let pqPub = Data(base64Encoded: pqB64),
                  let xB64 = json["x25519_pub_b64"] as? String, let xPub = Data(base64Encoded: xB64),
                  let sigB64 = json["sig_b64"] as? String, let sig = Data(base64Encoded: sigB64) else {
                return nil
            }
            let createdAtMs = (json["created_at_ms"] as? NSNumber)?.int64Value ?? 0
            return OneTimePrekeyDTO(
                prekeyId: prekeyIdNum.uint32Value,
                pqPub: pqPub,
                x25519Pub: xPub,
                createdAtMs: createdAtMs,
                sig: sig
            )
        } catch {
            return nil
        }
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

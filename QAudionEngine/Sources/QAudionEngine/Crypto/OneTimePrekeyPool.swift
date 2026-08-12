import Foundation
import CryptoKit

/// The device's pool of one-time prekeys: generate, keep the private halves,
/// hand out the public halves for upload, and consume one on arrival.
///
/// A `qa_kms_prebootstrap:1` envelope works without any of this — the sender
/// falls back to the peer's long-term bundle keys when the pool is empty. What
/// it loses is the one-time part: with a prekey, the shared secret for that
/// first message depends on a keypair that exists exactly once and is deleted
/// on use, so an attacker who later compromises the long-term identity keys
/// still cannot reconstruct it. Android has had this since the pool endpoint
/// shipped; this side has been consuming prekeys from other people's pools
/// while offering none of its own.
///
/// Deliberately `nonisolated` and dependency-free of AppState: generating a
/// hundred ML-KEM-1024 keypairs on the main actor would stall the UI, and this
/// type has to be callable from a detached task.
public struct OneTimePrekeyPool {

    /// One prekey as it exists on this device: public halves for upload, and
    /// the private halves nobody else ever sees.
    public struct StoredPrekey: Codable, Sendable {
        public let prekeyId: UInt32
        public let pqPub: Data
        public let pqPriv: Data
        public let x25519Pub: Data
        public let x25519Priv: Data
        public let createdAtMs: Int64
        /// Ed25519 over `SHA256(pq_pub || x25519_pub || be64(created_at_ms))`.
        public let sig: Data
    }

    /// How many prekeys the pool aims to hold, and when it bothers refilling.
    /// Same numbers as Android, so the two platforms behave alike under the
    /// server's cap of 1000 per user and 200 per batch.
    public static let poolTarget = 100
    public static let poolLowWater = 20
    public static let maxBatch = 200

    public init() {}

    /// Mint [count] prekeys, signed with the device's long-term Ed25519
    /// identity key.
    ///
    /// Ids are drawn at random across the full UInt32 range, never as a
    /// counter: the server keys a prekey by `user_id || id` with no device
    /// component, so a user's phone and their laptop starting at 1 would
    /// silently overwrite each other's prekeys.
    public func generate(count: Int, identityEd25519Priv: Data, nowMs: Int64) throws -> [StoredPrekey] {
        guard count > 0 else { return [] }
        let signer = try Curve25519.Signing.PrivateKey(rawRepresentation: identityEd25519Priv)
        let kem = PqcKeyExchange()
        var out: [StoredPrekey] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            let pq = try kem.generateKeyPair()
            let x = Curve25519.KeyAgreement.PrivateKey()
            let xPub = x.publicKey.rawRepresentation
            let id = UInt32.random(in: 1...UInt32.max)
            let digest = Self.signingDigest(pqPub: pq.publicKey, x25519Pub: xPub, createdAtMs: nowMs)
            let sig = try signer.signature(for: digest)
            out.append(StoredPrekey(
                prekeyId: id,
                pqPub: pq.publicKey,
                pqPriv: pq.secretKey,
                x25519Pub: xPub,
                x25519Priv: x.rawRepresentation,
                createdAtMs: nowMs,
                sig: sig
            ))
        }
        return out
    }

    /// The bytes the per-prekey signature covers.
    ///
    /// Note this signs the 32-byte digest, while the identity BUNDLE self-sig
    /// signs its 1719-byte preimage raw. Two conventions one keystroke apart,
    /// and both fail with the same opaque 400 — see `prekeys.go`'s verifier.
    public static func signingDigest(pqPub: Data, x25519Pub: Data, createdAtMs: Int64) -> Data {
        var buf = Data()
        buf.append(pqPub)
        buf.append(x25519Pub)
        var be = createdAtMs.bigEndian
        withUnsafeBytes(of: &be) { buf.append(contentsOf: $0) }
        return Data(SHA256.hash(data: buf))
    }

    /// The upload body the server accepts: `{"prekeys":[…]}`, standard padded
    /// base64, all-or-nothing validation server-side.
    public static func uploadBody(_ prekeys: [StoredPrekey]) throws -> Data {
        let items: [[String: Any]] = prekeys.map {
            [
                "prekey_id": $0.prekeyId,
                "pq_pub_b64": $0.pqPub.base64EncodedString(),
                "x25519_pub_b64": $0.x25519Pub.base64EncodedString(),
                "created_at_ms": $0.createdAtMs,
                "sig_b64": $0.sig.base64EncodedString(),
            ]
        }
        return try JSONSerialization.data(withJSONObject: ["prekeys": items])
    }
}

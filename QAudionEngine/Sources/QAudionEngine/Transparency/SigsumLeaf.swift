import Foundation
import CryptoKit

/// TRUST-1 residual (`CRYPTO_PROTOCOL_AUDIT_2026-09-01.md` backlog item 7,
/// this app's Key-Transparency finding: "only key transparency ... or
/// cross-signing ... removes the server from this decision for TOFU peers")
/// — the identity-binding preimage that a Q-Audion Sigsum log entry logs.
///
/// Direct byte-for-byte port of Android
/// `qaudion-android-new/qaudion-engine/.../transparency/SigsumProof.computeLeaf`
/// (ADR-026 §4.2) — that layout is confirmed correct and is NOT changed
/// here. What Android's `SigsumProof.kt` got wrong is everything AFTER this
/// step: it never turns this value into a real Sigsum `tree_leaf`
/// (checksum||signature||key_hash), never applies the RFC 6962 leaf-hash
/// prefix byte, and its inclusion-proof loop skips the path-length check.
/// This iOS port fixes all of that in `SigsumMerkle`/`SigsumVerifier` rather
/// than reproducing the bug — see those files' kdoc.
///
/// ## Naming note
///
/// Despite the name (kept identical to the Android port for cross-platform
/// grep-ability), this does **not** return a Sigsum Merkle-tree leaf hash.
/// It returns the 32-byte **message** that feeds the real Sigsum leaf-hash
/// chain:
/// ```
/// message   = computeLeaf(...)                        // this function
/// checksum  = SHA-256(message)
/// signature = Ed25519(submitter_priv, "sigsum.org/v1/tree-leaf" || 0x00 || checksum)
/// key_hash  = SHA-256(submitter_pub)
/// tree_leaf = checksum || signature || key_hash        // 128 bytes
/// leaf_hash = SHA-256(0x00 || tree_leaf)                // what inclusion proofs are keyed on
/// ```
/// See `SigsumCrypto` for the checksum/signature/key_hash steps and
/// `SigsumMerkle` for `tree_leaf` → `leaf_hash` and inclusion verification.
///
/// ## Preimage layout (ADR-026 §4.2 — byte-identical across Android/iOS/Desktop)
/// ```
/// "qaudion-kt-leaf-v1 "   || 19 bytes  ASCII "qaudion-kt-leaf-v1" + trailing 0x20 (space)
/// uuid_raw                || 16 bytes  the user's UUID, raw octets, big-endian field layout
/// ed25519_pub             || 32 bytes  raw bytes (NOT base64)
/// be64(created_at_ms)     ||  8 bytes  big-endian signed int64
///                         = 75 bytes
/// message = SHA-256(preimage)  = 32 bytes
/// ```
/// The trailing domain-tag byte is ASCII space (0x20), not NUL — same
/// rationale as the Android kdoc: SHA-256 preimages are sometimes inspected
/// in hex dumps and a NUL byte can be silently truncated by C-string-aware
/// tooling.
public enum SigsumLeaf {

    /// ASCII domain-separation tag — MUST stay byte-identical to Android's
    /// `SigsumProof.LEAF_DOMAIN_TAG` / Desktop's equivalent. 19 bytes:
    /// 18-byte ASCII "qaudion-kt-leaf-v1" + trailing 0x20 (space).
    static let leafDomainTag = Data("qaudion-kt-leaf-v1 ".utf8)

    /// SHA-256 digest length, used throughout this package for clarity.
    public static let digestLen = 32

    /// Raw UUID octet length.
    public static let uuidLen = 16

    /// Total preimage size: 19 (domain tag) + 16 (uuid) + 32 (ed25519 pub) + 8 (created_at_ms) = 75.
    public static let preimageLen = 19 + uuidLen + digestLen + 8

    public enum LeafError: Error, Equatable {
        case wrongLength(field: String, expected: Int, got: Int)
    }

    /// Build the 32-byte message bound into the Q-Audion Key-Transparency
    /// log for the binding `(userUuidRaw, ed25519Pub, createdAtMs)`.
    ///
    /// - Parameters:
    ///   - userUuidRaw: the user's UUID as 16 raw octets, in the SAME field
    ///     order Android's `java.util.UUID.getMostSignificantBits()` /
    ///     `getLeastSignificantBits()` produce (== the standard RFC 4122
    ///     big-endian octet layout — see `computeLeaf(userUuid:...)` below
    ///     for a `Foundation.UUID` convenience that supplies this directly).
    ///     Matches this file's sibling `IdentityKeyV2Preimage.buildV2`'s own
    ///     `uuidRaw: Data` convention rather than taking `Foundation.UUID`
    ///     as the primary parameter type, so callers that already hold raw
    ///     bytes (e.g. parsed off the wire) never round-trip through a
    ///     `UUID` value just to call this.
    ///   - ed25519Pub: raw 32-byte Ed25519 long-term identity public key.
    ///   - createdAtMs: server-recorded publish timestamp (ms) — a
    ///     tie-breaker so a no-op republish of the same binding still hashes
    ///     to a fresh message.
    /// - Returns: 32-byte SHA-256 digest ("message" in the Sigsum sense —
    ///   see this type's header for the naming caveat).
    public static func computeLeaf(userUuidRaw: Data, ed25519Pub: Data, createdAtMs: Int64) throws -> Data {
        guard userUuidRaw.count == uuidLen else {
            throw LeafError.wrongLength(field: "userUuidRaw", expected: uuidLen, got: userUuidRaw.count)
        }
        guard ed25519Pub.count == digestLen else {
            throw LeafError.wrongLength(field: "ed25519Pub", expected: digestLen, got: ed25519Pub.count)
        }
        var preimage = Data(capacity: preimageLen)
        preimage.append(leafDomainTag)
        preimage.append(userUuidRaw)
        preimage.append(ed25519Pub)
        var createdBe = UInt64(bitPattern: createdAtMs).bigEndian
        preimage.append(withUnsafeBytes(of: &createdBe) { Data($0) })
        precondition(preimage.count == preimageLen, "preimage length drift: \(preimage.count) != \(preimageLen)")
        return Data(SHA256.hash(data: preimage))
    }

    /// Convenience overload taking a `Foundation.UUID` directly. `UUID.uuid`
    /// is the raw 16-byte `uuid_t` in standard RFC 4122 octet order —
    /// byte-identical to what `java.util.UUID`'s msb/lsb longs encode to and
    /// to what every other platform in this codebase treats as "raw UUID
    /// bytes" (see `IdentityKeyV2Preimage`'s own `uuidRaw: Data` callers).
    /// Non-load-bearing convenience: any caller who doubts this mapping can
    /// always call the primary `userUuidRaw:`-based overload with bytes it
    /// built itself.
    public static func computeLeaf(userUuid: UUID, ed25519Pub: Data, createdAtMs: Int64) throws -> Data {
        try computeLeaf(userUuidRaw: rawBytes(of: userUuid), ed25519Pub: ed25519Pub, createdAtMs: createdAtMs)
    }

    static func rawBytes(of uuid: UUID) -> Data {
        let u = uuid.uuid
        return Data([u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
                      u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15])
    }
}

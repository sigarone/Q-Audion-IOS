import Foundation

/// ADR-014a §2.1 — canonical preimage for the `self_sig_b64` field carried
/// in a v2 identity bundle (`GET /api/v1/users/{id}/identity-key`).
///
/// Direct port of Android
/// `qaudion-android-new/core/core-data/.../security/IdentityKeyV2Preimage.kt`
/// (that file is the authoritative layout spec). Cross-platform contract:
/// this layout MUST be byte-equal to the server
/// `internal/store/identity_bundles.go::buildBundlePreimage` and Desktop's
/// `IdentityBundleCodec.ts::buildBundleSigPreimage`. Diverging from any of
/// those makes every peer's self-sig verify-fail here (fail-closed to
/// TOFU, per `AppState.attemptGroupCtrlKmsPreBootstrap`'s verify step —
/// never a silent accept of a wrong preimage).
///
/// Layout (v2; fields in order, all big-endian, no length prefixes —
/// sizes are fixed):
/// ```
/// "qaudion-identity-bundle-v1\0"   // 27B domain tag
///  || uuidRaw                      // 16B
///  || ed25519Pub                   // 32B
///  || ikPqPub                      // 1568B (ML-KEM-1024)
///  || vrfPubOrZero32                // 32B (all zeros while VRF deferred)
///  || be64(createdAtMs)             // 8B
///  || be32(version)                 // 4B (== 2)
///  || ikX25519Pub                   // 32B
/// ```
/// Total: 1719 bytes.
public enum IdentityKeyV2Preimage {

    /// "qaudion-identity-bundle-v1" (26 ASCII) + 0x00 = 27 bytes total —
    /// same bytes as the server's `preimageDomain` / Desktop's
    /// `BUNDLE_DOMAIN_TAG`.
    static let domainTag: Data = Data("qaudion-identity-bundle-v1".utf8) + Data([0x00])

    /// 32B all-zero placeholder for the VRF public key (Phase 33 deferred
    /// on every platform — all three agree on the zero-fill).
    public static let vrfPubOrZero32: Data = Data(count: 32)

    static let uuidLen = 16
    static let ed25519PubLen = 32
    static let ikPqPubLen = 1568
    static let vrfPubLen = 32
    static let ikX25519PubLen = 32

    /// Total preimage size: 27 + 16 + 32 + 1568 + 32 + 8 + 4 + 32 = 1719.
    public static let preimageLenV2 = 27 + 16 + 32 + 1568 + 32 + 8 + 4 + 32

    public enum PreimageError: Error {
        case wrongLength(field: String, expected: Int, got: Int)
    }

    /// Build the canonical v2 preimage bytes.
    ///
    /// - Parameters:
    ///   - uuidRaw: 16-byte canonical UUID.
    ///   - ed25519Pub: 32-byte Ed25519 long-term identity public key.
    ///   - ikPqPub: 1568-byte ML-KEM-1024 public key.
    ///   - ikX25519Pub: 32-byte X25519 public key.
    ///   - createdAtMs: server-recorded publish timestamp (ms).
    ///   - vrfPubOrZero32: 32-byte VRF public OR all-zero placeholder.
    public static func buildV2(
        uuidRaw: Data,
        ed25519Pub: Data,
        ikPqPub: Data,
        ikX25519Pub: Data,
        createdAtMs: Int64,
        vrfPubOrZero32: Data = vrfPubOrZero32
    ) throws -> Data {
        guard uuidRaw.count == uuidLen else {
            throw PreimageError.wrongLength(field: "uuidRaw", expected: uuidLen, got: uuidRaw.count)
        }
        guard ed25519Pub.count == ed25519PubLen else {
            throw PreimageError.wrongLength(field: "ed25519Pub", expected: ed25519PubLen, got: ed25519Pub.count)
        }
        guard ikPqPub.count == ikPqPubLen else {
            throw PreimageError.wrongLength(field: "ikPqPub", expected: ikPqPubLen, got: ikPqPub.count)
        }
        guard vrfPubOrZero32.count == vrfPubLen else {
            throw PreimageError.wrongLength(field: "vrfPubOrZero32", expected: vrfPubLen, got: vrfPubOrZero32.count)
        }
        guard ikX25519Pub.count == ikX25519PubLen else {
            throw PreimageError.wrongLength(field: "ikX25519Pub", expected: ikX25519PubLen, got: ikX25519Pub.count)
        }

        var out = Data(capacity: preimageLenV2)
        out.append(domainTag)
        out.append(uuidRaw)
        out.append(ed25519Pub)
        out.append(ikPqPub)
        out.append(vrfPubOrZero32)
        var createdBe = UInt64(bitPattern: createdAtMs).bigEndian
        out.append(withUnsafeBytes(of: &createdBe) { Data($0) })
        var versionBe = UInt32(2).bigEndian
        out.append(withUnsafeBytes(of: &versionBe) { Data($0) })
        out.append(ikX25519Pub)
        precondition(out.count == preimageLenV2, "preimage length drift: \(out.count) != \(preimageLenV2)")
        return out
    }
}

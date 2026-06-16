import Foundation
import CryptoKit

/// KMS-rotation-v2 Phase-1 (C / D3-WIRE) — the FROZEN signed handshake-bundle
/// canonical bytes + Ed25519 sign/verify.
///
/// ## Why a NEW canon (not the Phase-10b `HandshakeTranscript`)
///
/// Phase-10b's `HandshakeTranscript` (`qaudion-handshake-sig-v1` domain) signs a
/// DIFFERENT byte layout. Phase-1's `hs-bundle-v1` is its own frozen contract,
/// pinned by `tools/kat/kms-v2/hs-bundle-v1-kat.json`. The two are NOT
/// interchangeable. This construct exists specifically to make a network MITM
/// unable to silently strip / reorder / flip the `pskFingerprints` (the
/// downgrade attack the additive hw_only mix is otherwise vulnerable to): the
/// fingerprints (OFFER) and the negotiation outcome `selected_fp` (ACCEPT) are
/// SIGNED, so any tamper invalidates the Ed25519 signature → verify-fail →
/// abort before any key derivation.
///
/// ## Canonical byte layout (FROZEN — byte-identical across all surfaces)
///
/// The signature covers a deterministic length/layout-fixed concatenation of
/// the RAW decoded bytes (NOT JSON — avoids serializer ambiguity). Variable
/// fields that need a count carry an explicit count prefix exactly as the KAT
/// freezes; everything else is fixed-width raw.
///
/// ```
/// canon(OFFER)  = ASCII("qa-kms-hs-offer-v1")        # 18B domain tag
///               || hs_version(1)
///               || caller_id_pk(32)                  # Ed25519 identity of caller
///               || caller_x25519_pub(32)
///               || SHA-256(caller_mlkem_ek)(32)      # binds the ML-KEM ek w/o 1568B
///               || cap_bits(4 BE)                     # negotiated capability bitmask
///               || n_fps(1) || fp_0(32) || fp_1(32) ...  # pskFingerprints, ADVERTISED order
///               || offer_nonce(16)
/// offerSig      = Ed25519-Sign(caller_id_sk, canon(OFFER))
///
/// canon(ACCEPT) = ASCII("qa-kms-hs-accept-v1")       # 19B domain tag
///               || hs_version(1)
///               || callee_id_pk(32)
///               || SHA-256(canon(OFFER))(32)         # transcript binding -> ties ACCEPT to THIS offer
///               || selected_fp_or_zero32(32)         # the negotiation outcome, signed
///               || callee_x25519_pub(32)
///               || SHA-256(callee_mlkem_ct)(32)
///               || accept_nonce(16)
/// acceptSig     = Ed25519-Sign(callee_id_sk, canon(ACCEPT))
/// ```
///
/// ## Crypto
///
/// RFC 8032 PURE Ed25519 via CryptoKit `Curve25519.Signing` — byte-compatible
/// with Android BouncyCastle `Ed25519Signer`, Desktop `@noble/curves`, firmware.
/// The device long-term identity key is the same Ed25519 keypair
/// `DeviceKeyManager` provisions (`__device.ed25519.{priv,pub}`).
public enum KmsHsBundleV1 {

    /// 18-byte OFFER domain tag.
    static let offerTag: Data = Data("qa-kms-hs-offer-v1".utf8)
    /// 19-byte ACCEPT domain tag.
    static let acceptTag: Data = Data("qa-kms-hs-accept-v1".utf8)

    // MARK: - Canon builders

    /// Build `canon(OFFER)`. `fps` are the raw 32-byte fingerprints in ADVERTISED
    /// (priority) order — the order is signed, so a MITM reorder breaks the sig.
    public static func canonOffer(
        hsVersion: UInt8,
        callerIdPk: Data,
        callerX25519Pub: Data,
        callerMlkemEkSha256: Data,
        capBits: UInt32,
        fps: [Data],
        offerNonce: Data
    ) -> Data {
        precondition(fps.count <= 0xFF, "n_fps exceeds 1-byte count")
        var out = Data()
        out.append(offerTag)
        out.append(hsVersion)
        out.append(callerIdPk)
        out.append(callerX25519Pub)
        out.append(callerMlkemEkSha256)
        out.append(u32be(capBits))
        out.append(UInt8(fps.count))
        for fp in fps { out.append(fp) }
        out.append(offerNonce)
        return out
    }

    /// Build `canon(ACCEPT)`. `offerTranscriptSha256` MUST equal
    /// `SHA-256(canon(OFFER))` of the OFFER this answers (transcript binding);
    /// `selectedFpOrZero32` is the negotiated 32-byte fingerprint or 32×0x00.
    public static func canonAccept(
        hsVersion: UInt8,
        calleeIdPk: Data,
        offerTranscriptSha256: Data,
        selectedFpOrZero32: Data,
        calleeX25519Pub: Data,
        calleeMlkemCtSha256: Data,
        acceptNonce: Data
    ) -> Data {
        var out = Data()
        out.append(acceptTag)
        out.append(hsVersion)
        out.append(calleeIdPk)
        out.append(offerTranscriptSha256)
        out.append(selectedFpOrZero32)
        out.append(calleeX25519Pub)
        out.append(calleeMlkemCtSha256)
        out.append(acceptNonce)
        return out
    }

    // MARK: - Hash helpers

    /// `SHA-256(canon)` — the transcript binding the ACCEPT folds in, and the
    /// general per-bundle transcript hash (also used for replay binding upstream).
    public static func transcript(_ canon: Data) -> Data {
        return Data(SHA256.hash(data: canon))
    }

    /// Convenience: `SHA-256(ek)` for the OFFER's `caller_mlkem_ek_sha256` field.
    public static func mlkemEkSha256(_ ek: Data) -> Data { Data(SHA256.hash(data: ek)) }
    /// Convenience: `SHA-256(ct)` for the ACCEPT's `callee_mlkem_ct_sha256` field.
    public static func mlkemCtSha256(_ ct: Data) -> Data { Data(SHA256.hash(data: ct)) }

    // MARK: - Sign / Verify

    /// Sign a canon with the 32-byte raw Ed25519 identity seed
    /// (`DeviceKeyManager.currentEd25519Priv`). Returns the 64-byte detached
    /// signature. Throws on a malformed seed.
    public static func sign(canon: Data, idSeed: Data) throws -> Data {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: idSeed)
        return try key.signature(for: canon)
    }

    /// Verify a 64-byte detached Ed25519 signature over `canon` under the
    /// signer's 32-byte raw Ed25519 public identity key. Fail-closed: any
    /// malformed input or bad signature returns false (never throws).
    public static func verify(canon: Data, signature: Data, signerIdPk: Data) -> Bool {
        guard signature.count == 64, signerIdPk.count == 32 else { return false }
        guard let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: signerIdPk) else {
            return false
        }
        return pub.isValidSignature(signature, for: canon)
    }

    // MARK: - private

    private static func u32be(_ v: UInt32) -> Data {
        var be = v.bigEndian
        return withUnsafeBytes(of: &be) { Data($0) }
    }
}

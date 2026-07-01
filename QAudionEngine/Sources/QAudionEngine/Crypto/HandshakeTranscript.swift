import Foundation
import CryptoKit

/// Phase-10b handshake-signing canonical transcript — the byte-exact, cross-platform
/// contract that Ed25519-authenticates the OFFER / ACCEPT bundle.
///
/// **Why this exists.** The OFFER/ACCEPT `AndroidHandshakeBundle` travels as JSON, but a
/// JSON byte string is NOT reproducible across kotlinx-serialization (Android), Swift
/// `Codable` (iOS) and `JSON.stringify` (Desktop) — field order, null-vs-omitted and
/// whitespace diverge. So the signature is computed over an **explicit length-prefixed
/// concatenation of the RAW decoded bytes**, defined here, identical on every platform.
///
/// This is the iOS port of the Android reference
/// `apps/qaudion-android-new/qaudion-engine/src/main/java/com/bcrypto/qaudion/crypto/HandshakeTranscript.kt`.
/// Both ports MUST reproduce `tools/kat/handshake-sig/handshake-sig-kat.json`
/// (`transcript_sha256_hex` + `signature_hex` + `offer_binding_hex`) byte-for-byte.
/// Reference golden (XC-4, CAPS=6 bytes, `hs-sig-offer-0001`): transcript len **1853**,
/// sha256 `01496bb5349a089fe9881406ad52f70c6ab891ee9f403b2b64f3006bd236a50d`.
/// (`hs-sig-accept-0001`): transcript len **1822**,
/// sha256 `5e4ce2f078dc22429706493a1bc96e957304b58b728245bce5a8969a1e708712`.
///
/// **What it binds** (anti-downgrade / anti-MITM / anti-reflection / anti-mix-and-match):
/// the role (OFFER vs ACCEPT), callId, the signer's long-term Ed25519 identity, the signer's
/// per-direction `epochId`, the per-call PQC/X25519 public material, the negotiated
/// capabilities, `ratchetV`/`suiteId`, and the PSK fingerprints. The ACCEPT additionally
/// binds `SHA-256(transcriptOffer)` so a real ACCEPT cannot be paired with a forged OFFER.
///
/// **Crypto.** `SHA256` (CryptoKit) for `offer_binding`. Verify with
/// `Curve25519.Signing.PublicKey.isValidSignature` — RFC 8032 PURE Ed25519 (NOT ph/ctx),
/// byte-compatible with Android BouncyCastle `Ed25519Signer` and Desktop `@noble/curves`.
/// Signing uses `Curve25519.Signing.PrivateKey.signature(for:)` (same primitive
/// `SovereignIdentityManager.signChallenge` uses).
///
/// **IMPORTANT — operate on RAW Data.** Callers MUST base64-decode the bundle fields
/// (`signerIdentityKey`, `pqcPublicKey`, `x25519PublicKey`, the ciphertext members …) to
/// their raw bytes BEFORE passing them here. Passing base64 strings would change every
/// length prefix and break cross-platform parity.
public enum HandshakeTranscript {

    /// UTF-8 "qaudion-handshake-sig-v1" — 24 bytes, fixed prefix (NOT length-prefixed).
    private static let domain: Data = Data("qaudion-handshake-sig-v1".utf8)
    private static let roleOffer: UInt8 = 0x01
    private static let roleAccept: UInt8 = 0x02

    // MARK: - Low-level encoders

    /// `LP(x) = u16_BE(len(x)) || x`. Absent field => `LP(empty) = 0x0000`.
    private static func appendLP(_ out: inout Data, _ bytes: Data?) {
        let b = bytes ?? Data()
        precondition(b.count <= 0xFFFF, "LP field too long: \(b.count)")
        out.append(UInt8((b.count >> 8) & 0xFF))
        out.append(UInt8(b.count & 0xFF))
        out.append(b)
    }

    private static func capByte(_ v: Bool) -> UInt8 { v ? 0x01 : 0x00 }

    /// PSK fingerprints sorted ascending, comma-joined UTF-8; empty when none.
    ///
    /// Sorted with the default `String` `<` (lexicographic over Unicode scalars), which
    /// matches Kotlin's `List<String>.sorted()` (natural String ordering) for the ASCII-hex
    /// fingerprints used in practice.
    private static func pskJoin(_ fps: [String]?) -> Data {
        let joined = (fps ?? []).sorted().joined(separator: ",")
        return Data(joined.utf8)
    }

    // MARK: - Transcript builders

    /// Build the OFFER transcript over RAW (already base64-decoded) bytes.
    ///
    /// - Parameters:
    ///   - signerIdentityKey: 32-byte Ed25519 public key of the signer (the initiator).
    ///   - epochId: 16-byte per-direction epoch_id the signer uses on its outbound frames.
    ///   - pqcPublicKey: raw ML-KEM-1024 public key (1568 B).
    ///   - x25519PublicKey: raw X25519 public key (32 B).
    ///   - strongBoxPublicKey / dualCurvePublicKey: optional; `nil` encodes as `LP(empty)`.
    ///   - ratchetV / suiteId: single bytes (0x04 / 0x01 for the Phase-18 suite).
    public static func offer(
        callId: String,
        signerIdentityKey: Data,
        epochId: Data,
        pqcPublicKey: Data,
        x25519PublicKey: Data,
        strongBoxPublicKey: Data?,
        dualCurvePublicKey: Data?,
        ratchetV3: Bool,
        sframeV1: Bool,
        vkeyV1: Bool,
        sessionKdfV3: Bool,
        ratchetV4: Bool,
        srtpDirKeyV1: Bool,
        ratchetV: UInt8,
        suiteId: UInt8,
        pskFingerprints: [String]?
    ) -> Data {
        var out = Data()
        out.append(domain)
        out.append(roleOffer)
        appendLP(&out, Data(callId.utf8))
        appendLP(&out, signerIdentityKey)
        appendLP(&out, epochId)
        appendLP(&out, pqcPublicKey)
        appendLP(&out, x25519PublicKey)
        appendLP(&out, strongBoxPublicKey)
        appendLP(&out, dualCurvePublicKey)
        out.append(capByte(ratchetV3))
        out.append(capByte(sframeV1))
        out.append(capByte(vkeyV1))
        out.append(capByte(sessionKdfV3)) // XC-3: 4th CAPS byte — sessionKdfV3 now signed
        out.append(capByte(ratchetV4)) // XC-4: 5th CAPS byte — ratchetV4 now signed
        out.append(capByte(srtpDirKeyV1)) // XC-4: 6th CAPS byte — srtpDirKeyV1 now signed
        out.append(ratchetV)
        out.append(suiteId)
        appendLP(&out, pskJoin(pskFingerprints))
        return out
    }

    /// `offer_binding = SHA-256(offerTranscript)` — bound into the ACCEPT transcript.
    public static func offerBinding(_ offerTranscript: Data) -> Data {
        return Data(SHA256.hash(data: offerTranscript))
    }

    /// Build the ACCEPT transcript over RAW (already base64-decoded) bytes.
    ///
    /// - Parameters:
    ///   - ctPqc: raw ML-KEM ciphertext (1568 B).
    ///   - ctX25519: raw X25519 ciphertext / ephemeral pub (32 B).
    ///   - ctStrongBox / ctDualCurve: optional; `nil` encodes as `LP(empty)`.
    ///   - selectedPskFingerprint: `nil` encodes as `LP(utf8(""))`.
    ///   - offerBinding: MUST equal `SHA-256` of the OFFER this ACCEPT answers — the responder
    ///     computes it from the OFFER it received & verified; the initiator recomputes it from
    ///     the OFFER it sent.
    public static func accept(
        callId: String,
        signerIdentityKey: Data,
        epochId: Data,
        ctPqc: Data,
        ctX25519: Data,
        ctStrongBox: Data?,
        ctDualCurve: Data?,
        ratchetV3: Bool,
        sframeV1: Bool,
        vkeyV1: Bool,
        sessionKdfV3: Bool,
        ratchetV4: Bool,
        srtpDirKeyV1: Bool,
        ratchetV: UInt8,
        suiteId: UInt8,
        selectedPskFingerprint: String?,
        offerBinding: Data
    ) -> Data {
        var out = Data()
        out.append(domain)
        out.append(roleAccept)
        appendLP(&out, Data(callId.utf8))
        appendLP(&out, signerIdentityKey)
        appendLP(&out, epochId)
        appendLP(&out, ctPqc)
        appendLP(&out, ctX25519)
        appendLP(&out, ctStrongBox)
        appendLP(&out, ctDualCurve)
        out.append(capByte(ratchetV3))
        out.append(capByte(sframeV1))
        out.append(capByte(vkeyV1))
        out.append(capByte(sessionKdfV3)) // XC-3: 4th CAPS byte — sessionKdfV3 now signed
        out.append(capByte(ratchetV4)) // XC-4: 5th CAPS byte — ratchetV4 now signed
        out.append(capByte(srtpDirKeyV1)) // XC-4: 6th CAPS byte — srtpDirKeyV1 now signed
        out.append(ratchetV)
        out.append(suiteId)
        appendLP(&out, Data((selectedPskFingerprint ?? "").utf8))
        appendLP(&out, offerBinding)
        return out
    }

    // MARK: - Sign / Verify

    /// Sign [transcript] with the signer's long-term Ed25519 private key.
    ///
    /// `signingPrivateKeyRaw` is the 32-byte Ed25519 seed (e.g.
    /// `SovereignIdentity.signingPrivate`). Mirrors the
    /// `SovereignIdentityManager.signChallenge` style: build the
    /// `Curve25519.Signing.PrivateKey` from the raw seed, then `signature(for:)`.
    /// Returns the 64-byte detached signature. Throws if the seed is malformed.
    public static func sign(transcript: Data, signingPrivateKeyRaw: Data) throws -> Data {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: signingPrivateKeyRaw)
        return try key.signature(for: transcript)
    }

    /// Verify a detached Ed25519 signature (64 B) over [transcript] under
    /// [signerIdentityKey] (32 B raw Ed25519 public key). Returns false (never throws)
    /// for any malformed input or a bad signature — fail-closed.
    public static func verify(transcript: Data, signature: Data, signerIdentityKey: Data) -> Bool {
        guard signature.count == 64, signerIdentityKey.count == 32 else { return false }
        guard let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: signerIdentityKey) else {
            return false
        }
        return pub.isValidSignature(signature, for: transcript)
    }
}

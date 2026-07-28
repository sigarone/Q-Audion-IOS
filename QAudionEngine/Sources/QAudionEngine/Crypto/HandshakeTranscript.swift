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

    /// W-TRANSCRIPTV2 (multi-PSK-mixing SYNTHESIS.md ship step 4) — the v1 domain string
    /// with its trailing "v1" changed to "v2", SAME LENGTH (24 bytes — self-verified below).
    /// Used ONLY by `offerV2`/`acceptV2` — `domain`/`offer`/`accept` above are completely
    /// UNTOUCHED by this addition, so every existing signed call keeps verifying byte-for-
    /// byte identically. Mirrors the Android reference
    /// (`HandshakeTranscript.kt` `DOMAIN_V2`, commit d3244418) and Desktop
    /// (`HandshakeTranscript.ts` `DOMAIN_V2`, commit c6bf155) byte-for-byte.
    private static let domainV2: Data = {
        let d = Data("qaudion-handshake-sig-v2".utf8)
        precondition(d.count == domain.count, "domainV2 length \(d.count) != domain length \(domain.count)")
        return d
    }()

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

    /// W-TRANSCRIPTV2 — v2-only replacement for `pskJoin` in the OFFER/ACCEPT PSK-list
    /// binding. `advEnc(list) = u8(m) || CONCAT_{j=1..m}( u8(role_j) || fp32_j )` — length
    /// `1 + 33*m`: RAW 32-byte fingerprints (NOT 64-hex strings) in the order actually
    /// ADVERTISED ON THE WIRE (not sorted), each paired with its 1-byte `roles` entry (0
    /// when the parallel roles array is shorter/absent — same "absent means all-zero/
    /// ordinary" convention `AndroidHandshakeBundle.pskRoles` already documents). Closes a
    /// real, independent defect `pskJoin` left open: the v1 signature binds the SORTED SET
    /// of fingerprints while actual PSK selection is driven by the wire ORDER (the responder
    /// picks the first match in the OFFER's advertised order) — a relay could permute that
    /// order without invalidating the v1 signature and steer which PSK gets selected. Binding
    /// the real order closes it, v2-only. Mirrors Android `HandshakeTranscript.kt advEnc` /
    /// Desktop `HandshakeTranscript.ts advEnc` byte-for-byte.
    ///
    /// Returns `nil` only for a pathological `fingerprintsHex.count > 255` (the `u8(m)` count
    /// prefix cannot represent it). This rebuild runs on EVERY inbound bundle regardless of
    /// whether it is even signed (`QAudionCallIntegration.evaluateVerdict` always calls the
    /// transcript builder), so it must never abort the process on adversarial peer input.
    /// Unlike Android's `require`/Desktop's `throw RangeError` (both caught by the caller's
    /// `runCatching`/`try-catch`), a Swift `precondition` here CANNOT be caught — it traps
    /// the whole process — so this returns `nil` instead, propagated the same way a base64-
    /// decode failure already is elsewhere in this file (the caller degrades to "transcript
    /// unavailable", never a crash).
    ///
    /// A per-entry fingerprint that is not well-formed 64-char hex (reachable pre-auth — this
    /// build's own `pskFingerprints` are always well-formed, but a peer's JSON is parsed
    /// before any signature is checked) decodes to a deterministic 32-zero-byte placeholder
    /// instead of failing the whole encode — mirrors Desktop's `hexFpToRaw32` never-throw
    /// discipline. A malformed peer-controlled fingerprint can therefore only ever make a
    /// genuine peer's `sigV2` fail to verify (non-fatal `sig_invalid`), never crash.
    private static func advEnc(_ fingerprintsHex: [String]?, _ roles: [Int]?) -> Data? {
        let fps = fingerprintsHex ?? []
        guard fps.count <= 0xFF else { return nil }
        var out = Data()
        out.append(UInt8(fps.count))
        for (idx, fpHex) in fps.enumerated() {
            // force-unwraps safe: short-circuit `&&` only evaluates
            // `roles!.count`/`roles![idx]` once `roles != nil` is true.
            // swiftlint:disable:next force_unwrapping
            let role = (roles != nil && idx < roles!.count) ? roles![idx] : 0
            out.append(UInt8(truncatingIfNeeded: role))
            out.append(hexFpToRaw32(fpHex))
        }
        return out
    }

    /// Decode a peer-advertised PSK fingerprint hex string to its RAW 32-byte form for
    /// `advEnc`. Not well-formed (not exactly 64 hex chars, case-insensitive) => a
    /// deterministic 32-zero-byte placeholder — see `advEnc`'s doc for why this never throws.
    private static func hexFpToRaw32(_ hex: String) -> Data {
        let chars = Array(hex.utf8)
        guard chars.count == 64 else { return Data(count: 32) }
        var out = Data(capacity: 32)
        var i = 0
        while i < 64 {
            guard let hi = hexNibble(chars[i]), let lo = hexNibble(chars[i + 1]) else {
                return Data(count: 32)
            }
            out.append(UInt8((hi << 4) | lo))
            i += 2
        }
        return out
    }

    private static func hexNibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30          // '0'-'9'
        case 0x61...0x66: return c - 0x61 + 10     // 'a'-'f'
        case 0x41...0x46: return c - 0x41 + 10     // 'A'-'F'
        default: return nil
        }
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

    /// W-TRANSCRIPTV2 (multi-PSK-mixing SYNTHESIS.md ship step 4) — transcript v2 of the
    /// OFFER: SAME shape as `offer` except `domainV2` instead of `domain`, a 7th SIGNED CAPS
    /// byte (`pskMixV1`) appended after the existing 6, and `advEnc` (raw fp bytes bound in
    /// ADVERTISED ORDER, with a role byte each) instead of `pskJoin` (sorted, comma-joined)
    /// for the PSK-list binding. `offer` above is NOT touched by this addition — a call site
    /// emits/verifies BOTH transcripts side by side (dual-signature rollout; v1 stays exactly
    /// what every already-deployed peer verifies). Mirrors Android
    /// `HandshakeTranscript.kt offerV2` / Desktop `HandshakeTranscript.ts
    /// buildOfferTranscriptV2` byte-for-byte.
    ///
    /// Returns `nil` only when `advEnc` does (a pathological `pskFingerprints.count > 255`
    /// — see its doc).
    public static func offerV2(
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
        pskMixV1: Bool,
        ratchetV: UInt8,
        suiteId: UInt8,
        pskFingerprints: [String]?,
        pskRoles: [Int]?
    ) -> Data? {
        guard let adv = advEnc(pskFingerprints, pskRoles) else { return nil }
        var out = Data()
        out.append(domainV2)
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
        out.append(capByte(sessionKdfV3))
        out.append(capByte(ratchetV4))
        out.append(capByte(srtpDirKeyV1))
        out.append(capByte(pskMixV1))  // W-TRANSCRIPTV2: 7th CAPS byte, v2-only
        out.append(ratchetV)
        out.append(suiteId)
        appendLP(&out, adv)
        return out
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

    /// W-TRANSCRIPTV2 (multi-PSK-mixing SYNTHESIS.md ship step 4) — transcript v2 of the
    /// ACCEPT: SAME shape as `accept` (`domainV2`/the 7-byte CAPS instead of `domain`/6-byte
    /// CAPS; `LP(selectedPskFingerprint)` and `LP(offerBinding)` RETAINED UNCHANGED, same
    /// layout/position as v1) PLUS one v2-only ADDITIONAL field appended last:
    /// `LP(advEnc(responderPskFingerprints, responderPskRoles))` — the RESPONDER's own
    /// advertised PSK list (the ACCEPT-side mirror of `offerV2`'s `advEnc` binding), so both
    /// sides' advertised orders end up signed. `offerBinding` here MUST be `SHA-256` of the
    /// OFFER's **v2** transcript (from `offerV2`/`offerBinding`) — distinct from the v1
    /// `accept`'s `offerBinding` param, which binds the v1 OFFER transcript. `accept` above
    /// is NOT touched by this addition. Mirrors Android `HandshakeTranscript.kt acceptV2` /
    /// Desktop `HandshakeTranscript.ts buildAcceptTranscriptV2` byte-for-byte.
    ///
    /// Returns `nil` only when `advEnc` does.
    public static func acceptV2(
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
        pskMixV1: Bool,
        ratchetV: UInt8,
        suiteId: UInt8,
        selectedPskFingerprint: String?,
        offerBinding: Data,
        responderPskFingerprints: [String]?,
        responderPskRoles: [Int]?
    ) -> Data? {
        guard let adv = advEnc(responderPskFingerprints, responderPskRoles) else { return nil }
        var out = Data()
        out.append(domainV2)
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
        out.append(capByte(sessionKdfV3))
        out.append(capByte(ratchetV4))
        out.append(capByte(srtpDirKeyV1))
        out.append(capByte(pskMixV1))
        out.append(ratchetV)
        out.append(suiteId)
        appendLP(&out, Data((selectedPskFingerprint ?? "").utf8))
        appendLP(&out, offerBinding)
        appendLP(&out, adv)
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

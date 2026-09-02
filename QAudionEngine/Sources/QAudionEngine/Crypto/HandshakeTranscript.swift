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

    /// CALL-3/CALL-4 (HSID-002 remainder, 2026-09-02 protocol audit) — the v1
    /// domain string with its trailing "v2" changed to "v3", SAME LENGTH (24
    /// bytes — self-verified below). Used ONLY by `offerV3`/`acceptV3` — NONE
    /// of `offer`/`accept` (v1) NOR `offerV2`/`acceptV2` are touched by this
    /// addition, exactly mirroring how `domainV2` was introduced for
    /// W-TRANSCRIPTV2 above: a peer that has shipped through v2 (`pskMixV1`)
    /// but not this fix keeps verifying v1/v2 byte-for-byte as before; v3 is
    /// a THIRD, purely ADDITIONAL signature, computed/verified only when both
    /// peers ALSO negotiate the new `transcriptBindV1` capability (checked at
    /// the call site, not inside this file). See `offerV3`'s doc for what it
    /// adds over `offerV2`.
    private static let domainV3: Data = {
        let d = Data("qaudion-handshake-sig-v3".utf8)
        precondition(d.count == domain.count, "domainV3 length \(d.count) != domain length \(domain.count)")
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

    /// CALL-3 — big-endian 4-byte unsigned integer, appended UNCONDITIONALLY
    /// (not length-prefixed: its width is fixed at exactly 4 bytes by
    /// construction, known to both sides, so no `LP` framing is needed — same
    /// convention as `ratchetV`/`suiteId`/the CAPS bytes above, which are also
    /// fixed-width and unprefixed). Used only by `offerV3`/`acceptV3`'s
    /// `rekeyRound` field.
    private static func appendU32BE(_ out: inout Data, _ v: UInt32) {
        out.append(UInt8((v >> 24) & 0xFF))
        out.append(UInt8((v >> 16) & 0xFF))
        out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8(v & 0xFF))
    }

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

    /// CALL-3/CALL-4 (HSID-002 remainder, 2026-09-02 protocol audit) — v3
    /// sibling of `offerV2`. SAME shape as `offerV2` (`domainV3` instead of
    /// `domainV2`) PLUS an 8th SIGNED CAPS byte (`transcriptBindV1`) appended
    /// after the existing 7, PLUS two new fields appended LAST:
    ///
    ///   `rekeyNonce` (8 RAW bytes, NOT length-prefixed) — the call's own
    ///     random 64-bit freshness nonce, generated once at call start and
    ///     resent IDENTICALLY on every round of the call, including every
    ///     re-key round (round > 1) — never regenerated mid-call.
    ///   `u32_BE(rekeyRound)` — this OFFER's 1-based round ordinal (1 = the
    ///     call's first handshake, 2.. = re-key rounds), UNCONDITIONALLY
    ///     signed on every round.
    ///
    /// ITEM 2/3 FOLLOW-UP (2026-09-02) — `rekeyNonce` is now REQUIRED and
    /// FIXED-WIDTH (not length-prefixed), matching Android's
    /// `HandshakeTranscript.kt offerV3` byte-for-byte
    /// (`require(rekeyNonce.size == 8)`, appended raw). The prior shape
    /// here — `Data?`, `LP`-framed, resent on round 1 only and omitted
    /// (`LP(empty)`) on every re-key round — was a real, small bandwidth
    /// optimization, but it broke byte-for-byte cross-platform transcript
    /// equality: since `transcriptHash` (this transcript's own SHA-256) is
    /// what CALL-4's session-key/SAS KDFs derive everything else from, ANY
    /// platform-specific difference in this transcript's bytes makes the two
    /// peers derive different keys even when every other field agrees.
    ///
    /// CALL-3 fix: today's re-key transcript carries no round/nonce at all —
    /// a validly-signed round-1 bundle stays validly signed if replayed at
    /// round N. Binding a SIGNED, monotone `rekeyRound` (scoped to the call's
    /// own random `rekeyNonce`, never a bare cross-call-persistent value)
    /// lets a receiver's own in-memory `(callId) -> lastAcceptedRound` ratchet
    /// reject any round <= the last one it accepted for that call — closing
    /// the gap without needing fragile persisted state (a process restart
    /// mid-call safely starts a fresh nonce+counter, exactly like a fresh
    /// `callId` would).
    ///
    /// `offer`/`offerV2` above are NOT touched — this is a THIRD, additional,
    /// purely-additive signature computed/verified ONLY when both peers
    /// negotiate the new `transcriptBindV1` capability.
    ///
    /// Returns `nil` only when `advEnc` does (a pathological
    /// `pskFingerprints.count > 255` — see its doc).
    public static func offerV3(
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
        transcriptBindV1: Bool,
        ratchetV: UInt8,
        suiteId: UInt8,
        pskFingerprints: [String]?,
        pskRoles: [Int]?,
        rekeyNonce: Data,
        rekeyRound: UInt32
    ) -> Data? {
        guard let adv = advEnc(pskFingerprints, pskRoles) else { return nil }
        precondition(rekeyNonce.count == 8, "rekeyNonce must be exactly 8 bytes, got \(rekeyNonce.count)")
        var out = Data()
        out.append(domainV3)
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
        out.append(capByte(pskMixV1))
        out.append(capByte(transcriptBindV1))  // CALL-3/CALL-4: 8th CAPS byte, v3-only
        out.append(ratchetV)
        out.append(suiteId)
        appendLP(&out, adv)
        out.append(rekeyNonce)  // CALL-3: 8 RAW bytes, NOT length-prefixed — see doc above
        appendU32BE(&out, rekeyRound)
        return out
    }

    /// CALL-3/CALL-4 (HSID-002 remainder, 2026-09-02 protocol audit) — v3
    /// sibling of `acceptV2`. SAME shape as `acceptV2` (`domainV3`/the 8-byte
    /// CAPS instead of `domainV2`/7-byte CAPS; `LP(selectedPskFingerprint)`,
    /// `LP(offerBinding)` and the responder's `LP(adv)` RETAINED UNCHANGED,
    /// same layout/position as v2) PLUS TWO fields appended LAST: `rekeyNonce`
    /// (8 RAW bytes, NOT length-prefixed) and `u32_BE(rekeyRound)` — the
    /// RESPONDER'S ECHO of the exact `(rekeyNonce, rekeyRound)` pair carried
    /// by the OFFER this ACCEPT answers (verified equal to it by the caller
    /// before this is invoked). A tampered/replayed round OR nonce on the
    /// ACCEPT side also invalidates this signature.
    ///
    /// ITEM 2/3 FOLLOW-UP (2026-09-02) — `rekeyNonce` is a NEW parameter here,
    /// matching Android's `HandshakeTranscript.kt acceptV3` byte-for-byte
    /// (`require(rekeyNonce.size == 8)`, appended raw immediately before
    /// `rekeyRound`). This platform's ACCEPT transcript previously carried NO
    /// nonce field at all — only the OFFER did, and only on round 1 — on the
    /// theory that "both sides already hold it from round 1, no need to echo
    /// it back". That is true for the KEY MATERIAL, but it made this
    /// platform's v3 ACCEPT transcript a different SHAPE (one fewer raw
    /// field) than Android's, which breaks byte-for-byte transcript equality
    /// — see `offerV3`'s doc for why that specifically matters here (the
    /// transcript hash is what CALL-4's KDFs derive everything else from).
    ///
    /// `offerBinding` here MUST be `SHA-256` of the OFFER's **v3** transcript
    /// (from `offerV3`/`offerBinding`) — distinct from both the v1 `accept`'s
    /// and the v2 `acceptV2`'s `offerBinding` params, which bind the v1/v2
    /// OFFER transcripts respectively. `accept`/`acceptV2` above are NOT
    /// touched by this addition.
    ///
    /// Returns `nil` only when `advEnc` does.
    public static func acceptV3(
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
        transcriptBindV1: Bool,
        ratchetV: UInt8,
        suiteId: UInt8,
        selectedPskFingerprint: String?,
        offerBinding: Data,
        responderPskFingerprints: [String]?,
        responderPskRoles: [Int]?,
        rekeyNonce: Data,
        rekeyRound: UInt32
    ) -> Data? {
        guard let adv = advEnc(responderPskFingerprints, responderPskRoles) else { return nil }
        precondition(rekeyNonce.count == 8, "rekeyNonce must be exactly 8 bytes, got \(rekeyNonce.count)")
        var out = Data()
        out.append(domainV3)
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
        out.append(capByte(transcriptBindV1))
        out.append(ratchetV)
        out.append(suiteId)
        appendLP(&out, Data((selectedPskFingerprint ?? "").utf8))
        appendLP(&out, offerBinding)
        appendLP(&out, adv)
        out.append(rekeyNonce)  // CALL-3: 8 RAW bytes, NOT length-prefixed — see doc above
        appendU32BE(&out, rekeyRound)
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

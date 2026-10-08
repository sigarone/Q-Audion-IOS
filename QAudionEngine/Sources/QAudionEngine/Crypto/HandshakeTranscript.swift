import Foundation
import CryptoKit

/// Handshake-signing canonical transcript, version 6 -- the ONLY version.
///
/// The OFFER / ACCEPT bundle of a 1:1 call travels as JSON, but a JSON byte string is NOT
/// reproducible across kotlinx-serialization (Android), Swift `Codable` (iOS) and
/// `JSON.stringify` (Desktop): field order, null-vs-omitted and whitespace diverge. So the
/// Ed25519 signature is computed over an **explicit length-prefixed concatenation of the RAW
/// decoded bytes**, defined here and identical on every platform (WIRE_SPEC §3.7).
///
/// Transcript v6 replaces v5 (no backward compatibility, WIRE_SPEC §6): same byte layout as
/// v5, plus two changes:
///   1. the domain is `qaudion-handshake-sig-v6`;
///   2. one new LAST OFFER field `LP(sasCommit)`: the caller's SAS hash commitment (32 bytes in
///      round 1, empty in every rekey round). The ACCEPT has no new field: it binds the
///      commitment through `offerBinding = SHA-256(OFFER_v6)`.
///
/// ```
/// OFFER_v6  = "qaudion-handshake-sig-v6" || 0x01 || LP(callId) || LP(signerIK32) || LP(epochId16)
///             || LP(pqcPub) || LP(x25519Pub) || LP(strongBox|empty) || LP(dualCurve|empty)
///             || CAPS9 || ratchetV || suiteId || LP(advEnc(offer adverts))
///             || rekeyNonce[8] || u32(round) || DTLSFP_offerer[33] || LP(sasCommit|empty)
/// ACCEPT_v6 = "qaudion-handshake-sig-v6" || 0x02 || LP(callId) || LP(signerIK32) || LP(epochId16)
///             || LP(ctPqc) || LP(ctX25519) || LP(ctStrongBox|empty) || LP(ctDualCurve|empty)
///             || CAPS9 || ratchetV || suiteId || LP(selectedPskFp) || LP(SHA-256(OFFER_v6))
///             || LP(advEnc(responder adverts)) || rekeyNonce[8] || u32(round) || DTLSFP_acceptor[33]
/// sigV6     = Ed25519(deviceIdentityKey, OFFER_v6 | ACCEPT_v6)        (pure RFC 8032)
/// ```
///
/// **Crypto.** `SHA256` (CryptoKit) for `offer_binding`. Verify with
/// `Curve25519.Signing.PublicKey.isValidSignature` — RFC 8032 PURE Ed25519 (NOT ph/ctx),
/// byte-compatible with Android BouncyCastle `Ed25519Signer` and Desktop `@noble/curves`.
///
/// **IMPORTANT — operate on RAW Data.** Callers MUST base64-decode the bundle fields
/// (`signerIdentityKey`, `pqcPublicKey`, `x25519PublicKey`, the ciphertext members ...) to their
/// raw bytes BEFORE passing them here. Every builder returns `nil` (never traps) for an input
/// whose shape is wrong, because the inputs are peer-controlled.
public enum HandshakeTranscript {

    /// UTF-8 "qaudion-handshake-sig-v6" — 24 bytes, fixed prefix (NOT length-prefixed).
    static let domain: Data = Data("qaudion-handshake-sig-v6".utf8)
    private static let roleOffer: UInt8 = 0x01
    private static let roleAccept: UInt8 = 0x02

    /// The nine signed capability bits (CAPS9), in wire order. Absent/null capabilities decode to
    /// `false` (spec: a verifier reconstructs CAPS from the RECEIVED bundle).
    public struct Caps9: Equatable {
        public let ratchetV3: Bool
        public let sframeV1: Bool
        public let vkeyV1: Bool
        public let sessionKdfV3: Bool
        public let ratchetV4: Bool
        public let srtpDirKeyV1: Bool
        public let pskMixV1: Bool
        public let hsTranscriptBindV1: Bool
        public let ratchetV5: Bool

        public init(
            ratchetV3: Bool, sframeV1: Bool, vkeyV1: Bool, sessionKdfV3: Bool, ratchetV4: Bool,
            srtpDirKeyV1: Bool, pskMixV1: Bool, hsTranscriptBindV1: Bool, ratchetV5: Bool
        ) {
            self.ratchetV3 = ratchetV3
            self.sframeV1 = sframeV1
            self.vkeyV1 = vkeyV1
            self.sessionKdfV3 = sessionKdfV3
            self.ratchetV4 = ratchetV4
            self.srtpDirKeyV1 = srtpDirKeyV1
            self.pskMixV1 = pskMixV1
            self.hsTranscriptBindV1 = hsTranscriptBindV1
            self.ratchetV5 = ratchetV5
        }

        var bytes: [UInt8] {
            let flags: [Bool] = [
                ratchetV3, sframeV1, vkeyV1, sessionKdfV3, ratchetV4,
                srtpDirKeyV1, pskMixV1, hsTranscriptBindV1, ratchetV5,
            ]
            return flags.map { $0 ? 0x01 : 0x00 }
        }
    }

    /// Length of `sasCommit` (a SHA-256 digest).
    public static let sasCommitLength = 32

    // MARK: - Low-level encoders

    /// `LP(x) = u16_BE(len(x)) || x`. Absent field => `LP(empty) = 0x0000`. Returns false when the
    /// field is too long to be length-prefixed (never traps on peer-controlled input).
    private static func appendLP(_ out: inout Data, _ bytes: Data?) -> Bool {
        let b = bytes ?? Data()
        guard b.count <= 0xFFFF else { return false }
        out.append(UInt8((b.count >> 8) & 0xFF))
        out.append(UInt8(b.count & 0xFF))
        out.append(b)
        return true
    }

    private static func appendU32BE(_ out: inout Data, _ v: UInt32) {
        out.append(UInt8((v >> 24) & 0xFF))
        out.append(UInt8((v >> 16) & 0xFF))
        out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8(v & 0xFF))
    }

    /// `advEnc(list) = u8(m) || CONCAT_{j=1..m}( u8(role_j) || fp32_j )` — length `1 + 33*m`: RAW
    /// 32-byte fingerprints in the order actually ADVERTISED ON THE WIRE (not sorted), each paired
    /// with its 1-byte role (0 when the parallel roles array is shorter/absent).
    ///
    /// Returns `nil` only for a pathological `fingerprintsHex.count > 255`. A per-entry fingerprint
    /// that is not well-formed 64-char hex decodes to a deterministic 32-zero-byte placeholder
    /// instead of failing the whole encode (a malformed peer-controlled fingerprint can therefore
    /// only make a genuine peer's signature fail to verify, never crash).
    private static func advEnc(_ fingerprintsHex: [String]?, _ roles: [Int]?) -> Data? {
        let fps = fingerprintsHex ?? []
        guard fps.count <= 0xFF else { return nil }
        var out = Data()
        out.append(UInt8(fps.count))
        for (idx, fpHex) in fps.enumerated() {
            var role = 0
            if let roles = roles, idx < roles.count {
                role = roles[idx]
            }
            out.append(UInt8(truncatingIfNeeded: role))
            out.append(hexFpToRaw32(fpHex))
        }
        return out
    }

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

    /// Build `OFFER_v6` over RAW (already base64-decoded) bytes.
    ///
    /// - Parameters:
    ///   - signerIdentityKey: 32-byte Ed25519 public key of the signer (the offerer).
    ///   - epochId: 16-byte epoch id (all zero today, `HandshakeSigningPolicy.placeholderEpochId`).
    ///   - rekeyNonce: exactly 8 bytes, the call's own random freshness nonce (resent unchanged on
    ///     every round).
    ///   - rekeyRound: 1-based round ordinal (1 = the call's first handshake, 2.. = re-key rounds).
    ///   - dtlsFingerprint: the OFFERER's own DTLS certificate fingerprint, 33 bytes
    ///     (`DtlsFingerprint.binaryLength`).
    ///   - sasCommit: the caller's SAS commitment: exactly 32 bytes when `rekeyRound == 1`, `nil`
    ///     (or empty) when `rekeyRound >= 2`. Any other combination returns `nil`.
    /// - Returns: `nil` when an input has the wrong shape (never traps).
    public static func offer(
        callId: String,
        signerIdentityKey: Data,
        epochId: Data,
        pqcPublicKey: Data,
        x25519PublicKey: Data,
        strongBoxPublicKey: Data?,
        dualCurvePublicKey: Data?,
        caps: Caps9,
        ratchetV: UInt8,
        suiteId: UInt8,
        pskFingerprints: [String]?,
        pskRoles: [Int]?,
        rekeyNonce: Data,
        rekeyRound: UInt32,
        dtlsFingerprint: Data,
        sasCommit: Data?
    ) -> Data? {
        guard rekeyNonce.count == 8, DtlsFingerprint.isWellFormedBinary(dtlsFingerprint) else { return nil }
        // R-COMMIT-FIELD: round 1 carries exactly 32 bytes, every other round carries none.
        let commit = sasCommit ?? Data()
        if rekeyRound == 1 {
            guard commit.count == sasCommitLength else { return nil }
        } else {
            guard commit.isEmpty else { return nil }
        }
        guard let adv = advEnc(pskFingerprints, pskRoles) else { return nil }
        var out = Data()
        out.append(domain)
        out.append(roleOffer)
        var ok = true
        ok = appendLP(&out, Data(callId.utf8)) && ok
        ok = appendLP(&out, signerIdentityKey) && ok
        ok = appendLP(&out, epochId) && ok
        ok = appendLP(&out, pqcPublicKey) && ok
        ok = appendLP(&out, x25519PublicKey) && ok
        ok = appendLP(&out, strongBoxPublicKey) && ok
        ok = appendLP(&out, dualCurvePublicKey) && ok
        out.append(contentsOf: caps.bytes)
        out.append(ratchetV)
        out.append(suiteId)
        ok = appendLP(&out, adv) && ok
        out.append(rekeyNonce)
        appendU32BE(&out, rekeyRound)
        out.append(dtlsFingerprint)
        ok = appendLP(&out, commit) && ok
        return ok ? out : nil
    }

    /// `offer_binding = SHA-256(OFFER_v6)` — bound into the ACCEPT transcript.
    public static func offerBinding(_ offerTranscript: Data) -> Data {
        return Data(SHA256.hash(data: offerTranscript))
    }

    /// Build `ACCEPT_v6` over RAW (already base64-decoded) bytes.
    ///
    /// - Parameters:
    ///   - ctPqc: raw ML-KEM ciphertext (1568 B).
    ///   - ctX25519: raw X25519 ciphertext / ephemeral pub (32 B).
    ///   - selectedPskFingerprint: `nil` encodes as `LP(utf8(""))`.
    ///   - offerBinding: MUST be `SHA-256(OFFER_v6)` of the OFFER this ACCEPT answers (exactly 32
    ///     bytes, never empty): the acceptor computes it from the OFFER it received, the offerer
    ///     from the OFFER it sent.
    ///   - responderPskFingerprints / responderPskRoles: the ACCEPT's own advertised PSK list.
    ///   - dtlsFingerprint: the ACCEPTOR's own DTLS certificate fingerprint, 33 bytes.
    /// - Returns: `nil` when an input has the wrong shape (never traps).
    public static func accept(
        callId: String,
        signerIdentityKey: Data,
        epochId: Data,
        ctPqc: Data,
        ctX25519: Data,
        ctStrongBox: Data?,
        ctDualCurve: Data?,
        caps: Caps9,
        ratchetV: UInt8,
        suiteId: UInt8,
        selectedPskFingerprint: String?,
        offerBinding: Data,
        responderPskFingerprints: [String]?,
        responderPskRoles: [Int]?,
        rekeyNonce: Data,
        rekeyRound: UInt32,
        dtlsFingerprint: Data
    ) -> Data? {
        guard rekeyNonce.count == 8, offerBinding.count == 32,
              DtlsFingerprint.isWellFormedBinary(dtlsFingerprint) else { return nil }
        guard let adv = advEnc(responderPskFingerprints, responderPskRoles) else { return nil }
        var out = Data()
        out.append(domain)
        out.append(roleAccept)
        var ok = true
        ok = appendLP(&out, Data(callId.utf8)) && ok
        ok = appendLP(&out, signerIdentityKey) && ok
        ok = appendLP(&out, epochId) && ok
        ok = appendLP(&out, ctPqc) && ok
        ok = appendLP(&out, ctX25519) && ok
        ok = appendLP(&out, ctStrongBox) && ok
        ok = appendLP(&out, ctDualCurve) && ok
        out.append(contentsOf: caps.bytes)
        out.append(ratchetV)
        out.append(suiteId)
        ok = appendLP(&out, Data((selectedPskFingerprint ?? "").utf8)) && ok
        ok = appendLP(&out, offerBinding) && ok
        ok = appendLP(&out, adv) && ok
        out.append(rekeyNonce)
        appendU32BE(&out, rekeyRound)
        out.append(dtlsFingerprint)
        return ok ? out : nil
    }

    // MARK: - Sign / Verify

    /// Sign [transcript] with the signer's long-term Ed25519 private key.
    ///
    /// `signingPrivateKeyRaw` is the 32-byte Ed25519 seed (e.g. `SovereignIdentity.signingPrivate`).
    /// Returns the 64-byte detached signature. Throws if the seed is malformed. CryptoKit signs
    /// non-deterministically: tests verify a golden signature instead of comparing signature bytes.
    public static func sign(transcript: Data, signingPrivateKeyRaw: Data) throws -> Data {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: signingPrivateKeyRaw)
        return try key.signature(for: transcript)
    }

    /// Verify a detached Ed25519 signature (64 B) over [transcript] under
    /// [signerIdentityKey] (32 B raw Ed25519 public key). Returns false (never throws)
    /// for any malformed input or a bad signature — fail-closed.
    ///
    /// A small-order or non-canonically encoded key is refused here, before CryptoKit sees it: with a
    /// permissive verifier the signature `01 || 0^63` under the neutral element is valid for every
    /// message, so it would prove possession of nothing (`Ed25519IdentityKeyPolicy`). Same verdict as
    /// a malformed key, nothing on the wire changes.
    public static func verify(transcript: Data, signature: Data, signerIdentityKey: Data) -> Bool {
        guard signature.count == 64, signerIdentityKey.count == 32 else { return false }
        guard Ed25519IdentityKeyPolicy.isAcceptable(signerIdentityKey) else { return false }
        guard let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: signerIdentityKey) else {
            return false
        }
        return pub.isValidSignature(signature, for: transcript)
    }
}

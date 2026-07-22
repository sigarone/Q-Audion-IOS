import Foundation
import CryptoKit

/// W-KCMAC (multi-PSK-mixing SYNTHESIS.md ship step 5) — key-confirmation MAC.
///
/// **Purpose.** After session-key derivation, both peers independently recompute a
/// transcript that binds the OFFER/ACCEPT bindings, the *wire-order* PSK adverts each
/// side actually sent, the (currently ≤1) mixed-secret fingerprints, and both parties'
/// long-term Ed25519 identity keys — then exchange an HMAC over it. A verified MAC is
/// cryptographic proof both sides agree on every input that fed the session key,
/// including the order the PSK list was advertised in (closing the same
/// permute/reorder gap `HandshakeTranscript.advEnc` closed for the v2 signature —
/// this is the same idea one layer up, over the DERIVED session key rather than a
/// long-term identity signature).
///
/// **This step (W-KCMAC) is PURE OBSERVATION.** `N` stays capped at ≤1 everywhere;
/// nothing here reads or writes `PskMix` mixing state, and a wrong/absent `kc_mac`
/// never drops a call (W-NOBRICK) — the verdict is only ever surfaced as telemetry/UI
/// signal via `AssuranceState`.
///
/// This is the iOS port of the Android reference
/// `apps/qaudion-android-new/qaudion-engine/src/main/java/com/bcrypto/qaudion/crypto/KeyConfirmation.kt`
/// and Desktop's `src/main/calling/KeyConfirmation.ts` — all three MUST reproduce the
/// shared cross-platform KAT vectors byte-for-byte (`KeyConfirmationKatTests.swift`).
///
/// **Deliberately self-contained.** `advEnc`/`lp` are re-implemented here rather than
/// widening `HandshakeTranscript`'s private helpers to `internal` — mirrors this
/// codebase's existing convention (see `HandshakeTranscriptV2Tests` re-deriving the
/// same byte layout independently) of keeping each pure crypto file's byte-layout
/// self-verifying rather than sharing private implementation across files.
///
/// **IMPORTANT — operate on RAW Data / raw 32-byte fingerprints.** Every fixed-size
/// field below (`offerBinding`, `acceptBinding`, mix fingerprints, `ikInit`/`ikResp`)
/// is the raw decoded byte form — callers base64/hex-decode before calling in, exactly
/// as `HandshakeTranscript` requires for its own fields.
public enum KeyConfirmation {

    /// One entry of a PSK advertisement list, in the exact order it was received on
    /// the wire. `role` mirrors `AndroidHandshakeBundle.pskRoles`/`HandshakeTranscript`'s
    /// per-fingerprint role byte (0 = ordinary; other values reserved) — NOT the
    /// initiator/responder role byte used by `mac`/`verify` below, which is a
    /// completely separate concept (the KC_MAC message envelope's signer role).
    public struct PskAdvertEntry: Equatable {
        public let role: Int
        /// 64-char lowercase-hex canonical fingerprint (`PskAdvertising.canonicalFingerprint`).
        public let fingerprintHex: String

        public init(role: Int, fingerprintHex: String) {
            self.role = role
            self.fingerprintHex = fingerprintHex
        }
    }

    /// Key-confirmation verification outcome for `AssuranceState.decide`'s `kcStatus` input.
    public enum Status: Equatable {
        /// Peer's `kc_mac` arrived and verified against our own recomputation.
        case verified
        /// No `kc_mac` arrived from the peer before the 5000ms deadline (or the peer
        /// never advertised `pskMixV1`, so emission was never expected).
        case absent
        /// A `kc_mac` arrived but did NOT verify — active-attack signature (permuted
        /// advert list, shrunk advert list, reflected MAC, swapped identity keys, …).
        case wrong
    }

    private static let roleInitiator: UInt8 = 0x01
    private static let roleResponder: UInt8 = 0x02

    /// UTF-8 "qa-kc-transcript-v1" — 19 bytes, fixed prefix (NOT length-prefixed).
    private static let transcriptLabel = Data("qa-kc-transcript-v1".utf8)

    /// HKDF-Expand `info` for `K_kc` derivation — 12 bytes.
    private static let kcKeyInfo = Data("qa-kc-key-v1".utf8)

    // MARK: - Low-level encoders (self-contained; see type doc for why not shared)

    /// `LP(x) = u16_BE(len(x)) || x`. `LP(empty) = 0x0000`.
    private static func appendLP(_ out: inout Data, _ bytes: Data) {
        precondition(bytes.count <= 0xFFFF, "LP field too long: \(bytes.count)")
        out.append(UInt8((bytes.count >> 8) & 0xFF))
        out.append(UInt8(bytes.count & 0xFF))
        out.append(bytes)
    }

    /// `advEnc(list) = u8(m) || CONCAT_{j=1..m}( u8(role_j) || fp32_j )` — raw 32-byte
    /// fingerprints in the order actually ADVERTISED ON THE WIRE (never sorted), each
    /// paired with its 1-byte role. Length `1 + 33*m`.
    ///
    /// Returns `nil` only for a pathological `entries.count > 255` (the `u8(m)` count
    /// prefix cannot represent it) — never traps, mirrors `HandshakeTranscript.advEnc`'s
    /// never-crash-on-adversarial-input discipline (this rebuild can run on a
    /// peer-supplied advert list before any signature/MAC is checked).
    public static func advEnc(_ entries: [PskAdvertEntry]) -> Data? {
        guard entries.count <= 0xFF else { return nil }
        var out = Data()
        out.append(UInt8(entries.count))
        for entry in entries {
            out.append(UInt8(truncatingIfNeeded: entry.role))
            out.append(hexFpToRaw32(entry.fingerprintHex))
        }
        return out
    }

    /// Decode a 64-char lowercase/uppercase hex fingerprint to its raw 32-byte form.
    /// Not well-formed (wrong length or a non-hex char) => a deterministic 32-zero-byte
    /// placeholder — never throws, same discipline as `HandshakeTranscript.hexFpToRaw32`.
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
        case 0x30...0x39: return c - 0x30
        case 0x61...0x66: return c - 0x61 + 10
        case 0x41...0x46: return c - 0x41 + 10
        default: return nil
        }
    }

    // MARK: - K_kc derivation

    /// `K_kc = HKDF-Expand(PRK=session_key, info="qa-kc-key-v1", L=32)`.
    ///
    /// Expand-only (RFC 5869) — `sessionKey` is used directly as the PRK, there is no
    /// separate Extract stage (the session key is already the output of the handshake's
    /// own HKDF chain). Mirrors `KmsPreBootstrap.hkdfExpand`'s `HKDF<SHA256>.expand`
    /// idiom already established in this codebase.
    public static func deriveKcKey(sessionKey: Data) -> Data {
        let prk = SymmetricKey(data: sessionKey)
        let key = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: kcKeyInfo, outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    // MARK: - kc_transcript

    /// Build `kc_transcript`:
    /// ```
    /// SHA-256(
    ///     "qa-kc-transcript-v1"(19)
    ///  || offerBinding(32) || acceptBinding(32)
    ///  || LP(advEnc(initAdvert)) || LP(advEnc(respAdvert))
    ///  || u8(N) || fp_1 || ... || fp_N
    ///  || LP(mixId)                    // LP(empty) = 0x0000 when N<=1
    ///  || ikInit(32) || ikResp(32)
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - offerBinding / acceptBinding: `SHA-256` of the RECONSTRUCTED transcript-v2
    ///     objects transcript-v2 signing already builds
    ///     (`HandshakeTranscript.offerBinding(offerTranscriptV2)` / the ACCEPT-v2
    ///     equivalent) — NEVER raw JSON bytes.
    ///   - initAdvert / respAdvert: the initiator's / responder's PSK advert list, in
    ///     the exact order RECEIVED on the wire (never re-sorted) — this is what makes
    ///     a kc_permute/kc_shrink attack on the advertised list detectable.
    ///   - mixFingerprints: `s_1..s_N`, raw 32-byte fingerprints, `N` currently ≤1.
    ///   - mixId: empty `Data` when `N<=1` (encodes as `LP(empty)` = `0x0000`).
    ///   - ikInit / ikResp: raw 32-byte Ed25519 identity public keys.
    ///
    /// Returns `nil` only when `advEnc` does (a pathological >255-entry advert list on
    /// either side) or when `mixFingerprints.count > 255` — never traps.
    public static func transcript(
        offerBinding: Data,
        acceptBinding: Data,
        initAdvert: [PskAdvertEntry],
        respAdvert: [PskAdvertEntry],
        mixFingerprints: [Data],
        mixId: Data,
        ikInit: Data,
        ikResp: Data
    ) -> Data? {
        guard mixFingerprints.count <= 0xFF else { return nil }
        guard let initAdv = advEnc(initAdvert), let respAdv = advEnc(respAdvert) else { return nil }

        var out = Data()
        out.append(transcriptLabel)
        out.append(offerBinding)
        out.append(acceptBinding)
        appendLP(&out, initAdv)
        appendLP(&out, respAdv)
        out.append(UInt8(mixFingerprints.count))
        for fp in mixFingerprints {
            out.append(fp)
        }
        appendLP(&out, mixId)
        out.append(ikInit)
        out.append(ikResp)

        return Data(SHA256.hash(data: out))
    }

    // MARK: - MAC / verify

    /// `kc_mac_init = HMAC-SHA256(K_kc, 0x01 || kc_transcript)`,
    /// `kc_mac_resp = HMAC-SHA256(K_kc, 0x02 || kc_transcript)`.
    private static func mac(kcKey: Data, roleByte: UInt8, transcript: Data) -> Data {
        let key = SymmetricKey(data: kcKey)
        var msg = Data()
        msg.append(roleByte)
        msg.append(transcript)
        return Data(HMAC<SHA256>.authenticationCode(for: msg, using: key))
    }

    public static func macInit(kcKey: Data, transcript: Data) -> Data {
        mac(kcKey: kcKey, roleByte: roleInitiator, transcript: transcript)
    }

    public static func macResp(kcKey: Data, transcript: Data) -> Data {
        mac(kcKey: kcKey, roleByte: roleResponder, transcript: transcript)
    }

    /// Verify a peer-supplied `kc_mac` in CONSTANT TIME. Never compares secret bytes
    /// with `==`/`Array.==` directly — reuses `CryptoConstants.constantTimeEquals`,
    /// this codebase's existing constant-time-compare primitive (already used by
    /// `ZeroKnowledgeAuth`/`AttachmentEncryption` for the same class of secret-bytes
    /// comparison).
    ///
    /// - Parameter asInitiator: `true` to verify the PEER's `kc_mac_init` (i.e. this
    ///   side is the responder verifying the initiator's MAC), `false` to verify the
    ///   peer's `kc_mac_resp`.
    public static func verify(
        received: Data,
        kcKey: Data,
        asInitiator: Bool,
        transcript: Data
    ) -> Bool {
        let expected = asInitiator
            ? macInit(kcKey: kcKey, transcript: transcript)
            : macResp(kcKey: kcKey, transcript: transcript)
        return CryptoConstants.constantTimeEquals(received, expected)
    }
}

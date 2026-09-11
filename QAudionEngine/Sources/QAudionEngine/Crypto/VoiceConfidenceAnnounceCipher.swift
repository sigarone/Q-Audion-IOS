import Foundation
import CryptoKit

/// W-VOICECONFSYNC (2026-09-11) — E2E-sealed wire format for a call
/// responder's periodic "the caller's voice looks suspicious" advisory to
/// the caller, so the caller's `ReKeyScheduler` can react (only the
/// caller's own confidence has ever had a real effect on when a re-key
/// actually fires — the responder's own trigger is an intentional no-op,
/// see `QAudionCallIntegration.performPqcReKey`'s `isCaller` guard).
/// Port of Android's `com.bcrypto.qaudion.crypto.VoiceConfidenceAnnounceCipher`
/// — same wire shape, same domain-separation label, so either platform can
/// decrypt the other's announce.
///
/// Rides on the SAME `opaque_message`-piggy-back channel as the existing
/// PLP/OWNER_CONT/etc. reports (`CallPiggyBack`) — but UNLIKE those, this
/// payload is genuinely E2E encrypted rather than sent in cleartext to the
/// relay. Verified on Android by reading `WsCallSignaller.sendOpaque`: it
/// wraps a payload as `"$callId|$payload"` with no cipher applied at all —
/// an accepted tradeoff for network telemetry like packet-loss percentage,
/// but wrong for a signal that reveals "a deepfake-suspicion event
/// happened on this call, with this score, at this time" to the relay
/// operator.
///
/// Keyed off the call's own PQC session key, domain-separated via HKDF
/// under a label distinct from every other key derived from that same
/// secret (audio content, M-15 outer sealer, video sealer) — same
/// defense-in-depth principle already used throughout this codebase.
///
/// Purely advisory: a lost, corrupted, or replayed announce can only ever
/// make the caller's re-key timing wrong in a bounded, fail-safe direction
/// (see `AppState`'s call site for the peer-floor/throttle/hard-cap guards
/// against a malicious or buggy peer) — it can never itself change key
/// material or trigger a state transition. Reviewed via `nim.ps1 -Mode
/// security` and an independent Gemini pass before implementation
/// (Android original); this port carries the same design forward
/// unchanged.
public enum VoiceConfidenceAnnounceCipher {

    /// Domain-separation label — must never collide with any other HKDF
    /// `info` derived from the same session key. Byte-identical to
    /// Android's `KEY_LABEL_PREFIX` so both platforms derive the same key.
    private static let keyLabelPrefix = "voice-confidence-announce-v1|"
    private static let nonceSize = 12
    private static let tagSize = 16
    /// 4-byte seq (BE) + 4-byte confidence (BE float bits) + 8-byte epoch-ms timestamp (BE).
    private static let plaintextSize = 16

    public struct Announce: Equatable {
        public let seq: Int32
        public let confidence: Float
        public let atEpochMs: Int64
        public init(seq: Int32, confidence: Float, atEpochMs: Int64) {
            self.seq = seq
            self.confidence = confidence
            self.atEpochMs = atEpochMs
        }
    }

    private static func deriveKey(sessionKey: Data, callId: String) -> SymmetricKey {
        let info = Data((keyLabelPrefix + callId.lowercased()).utf8)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sessionKey),
            salt: Data(),
            info: info,
            outputByteCount: 32
        )
    }

    /// Encrypts `announce` under a key derived from `sessionKey` + `callId`.
    /// Returns `nil` on any failure (never throws) — the caller treats a
    /// failed seal as "skip sending this round," matching every other
    /// best-effort control-channel report in this codebase (PLP/BWCAP).
    public static func seal(sessionKey: Data, callId: String, announce: Announce) -> String? {
        var plaintext = Data(capacity: plaintextSize)
        withUnsafeBytes(of: announce.seq.bigEndian) { plaintext.append(contentsOf: $0) }
        withUnsafeBytes(of: announce.confidence.bitPattern.bigEndian) { plaintext.append(contentsOf: $0) }
        withUnsafeBytes(of: announce.atEpochMs.bigEndian) { plaintext.append(contentsOf: $0) }
        guard plaintext.count == plaintextSize else { return nil }

        let key = deriveKey(sessionKey: sessionKey, callId: callId)
        do {
            let nonce = AES.GCM.Nonce()
            let sealedBox = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
            var out = Data(sealedBox.nonce)
            out.append(sealedBox.ciphertext)
            out.append(sealedBox.tag)
            return out.base64EncodedString()
        } catch {
            return nil
        }
    }

    /// Decrypts a `seal`-produced payload. Returns `nil` on any failure —
    /// bad base64, wrong length, AEAD tag mismatch (tampered or wrong
    /// key), or a confidence value that decodes outside `[0, 1]`
    /// (defensive — AES-GCM already guarantees integrity, but never trust
    /// a decoded float range from the wire). The caller drops a `nil`
    /// result exactly like a lost PLP report: a missing round just means
    /// one fewer signal this tick, never an error.
    public static func open(sessionKey: Data, callId: String, payload: String) -> Announce? {
        guard let raw = Data(base64Encoded: payload),
              raw.count == nonceSize + plaintextSize + tagSize
        else { return nil }
        let nonceBytes = raw.prefix(nonceSize)
        let ciphertext = raw.subdata(in: nonceSize ..< (raw.count - tagSize))
        let tag = raw.suffix(tagSize)

        let key = deriveKey(sessionKey: sessionKey, callId: callId)
        do {
            let nonce = try AES.GCM.Nonce(data: nonceBytes)
            let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            let plaintext = try AES.GCM.open(sealedBox, using: key)
            guard plaintext.count == plaintextSize else { return nil }
            let seq = plaintext.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: Int32.self).bigEndian }
            let confBits = plaintext.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            let confidence = Float(bitPattern: confBits)
            let atEpochMs = plaintext.subdata(in: 8..<16).withUnsafeBytes { $0.load(as: Int64.self).bigEndian }
            guard confidence >= 0, confidence <= 1 else { return nil }
            return Announce(seq: seq, confidence: confidence, atEpochMs: atEpochMs)
        } catch {
            return nil
        }
    }
}

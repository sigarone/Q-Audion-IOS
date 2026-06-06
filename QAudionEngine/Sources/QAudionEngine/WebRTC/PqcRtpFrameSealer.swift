import Foundation
import CryptoKit
#if canImport(WebRTC)
import WebRTC

/// W376 — PQC-augmented RTP frame sealing layer.
///
/// **Design (Phase 22):** WebRTC's stock SRTP rides DTLS-SRTP which
/// uses x25519 + AES-CTR. Q-Audion's threat model wants ML-KEM-1024
/// post-quantum protection on top, so we wrap each outgoing audio
/// frame in our own AEAD layer keyed off the call's PQC session
/// key (W375 surfacing).
///
/// **Wire layout per frame** (replaces the standard SRTP encrypted
/// payload — DTLS-SRTP still wraps the whole RTP packet, so the
/// PQC layer is the inner of two AEAD layers):
/// ```
///   nonce(12) || ciphertext || tag(16)
/// ```
///
/// **Key derivation:** at call start (or rekey), derive a 32-byte
/// SRTP master key from the call's ML-KEM-derived shared secret:
/// ```
///   srtp_master = HKDF-SHA256(
///       IKM = pqc_session_key,
///       salt = "qaudion-srtp-salt-v1",
///       info = "q-audion-srtp-master-v1",
///       L = 32
///   )
/// ```
///
/// Per-frame derivation: AES-GCM with a counter-based nonce so the
/// (key, nonce) pair never repeats. The 12-byte nonce starts at
/// `0x00…0` and increments per packet.
///
/// **Cross-platform contract:** mirrors Android's planned
/// `PqcSrtpSealer.kt` once that ships. iOS lands the engine layer
/// first so the API is stable when the Android side comes online.
///
/// **Integration point:** WebRTC iOS exposes
/// `RTCFrameEncryptor` / `RTCFrameDecryptor` protocols on
/// `RTCRtpSender` / `RTCRtpReceiver`. Future commit will plug
/// `PqcRtpFrameSealer` into those slots; this commit ships the
/// engine surface so the wiring change can stay surgical.
/// ⚠️ SECURITY (M-13) — COUNTER STATE IS PER-INSTANCE AND DIRECTIONAL.
///
/// A single `PqcRtpFrameSealer` owns ONE monotonic `counter` that is
/// advanced by `seal(_:)` (the open path reflects the peer's counter
/// off the wire and never touches ours). Therefore **one instance
/// must be used seal-only OR open-only, never both** — sharing an
/// instance for inbound and outbound mixes two independent counter
/// spaces and risks (key, nonce) reuse, which is catastrophic for
/// AES-GCM confidentiality.
///
/// To protect both directions of a call build two independent
/// instances that share the same derived master key but keep
/// separate counters: construct the send sealer with
/// `init(pqcSessionKey:)` and the recv sealer with
/// ``makeSibling()`` (see `QAudionPeerConnection.installPqcSealer`).
public final class PqcRtpFrameSealer: @unchecked Sendable {

    public static let nonceSize = 12
    public static let tagSize = 16
    public static let masterKeySize = 32

    private static let salt = Data("qaudion-srtp-salt-v1".utf8)

    // M-15: info string bound to the call session (callId). When callId is
    // non-empty the derived key is unique per call even if (theoretically)
    // the same ML-KEM session key were reused across two calls.
    // Format: "q-audion-srtp-master-v1:<callId>" when callId is provided,
    //         "q-audion-srtp-master-v1" when empty (backward-compat / tests).
    // ⚠️ CROSS-PLATFORM: Android + Desktop must use the SAME format before
    // this feature is wire-deployed. Track in the coordinated change ticket.
    private let info: Data

    private let masterKey: SymmetricKey
    private let nonceLock = NSLock()
    private var counter: UInt64 = 0

    // MARK: - Replay protection (open path only — M-14)
    //
    // AES-GCM authentication guarantees integrity: a modified or fabricated
    // frame will fail tag verification. BUT it cannot prevent a recorded
    // valid frame from being replayed — the (nonce, ciphertext, tag) tuple
    // is still correct. Adding a 64-frame sliding window on the open()
    // path blocks replay attacks at negligible cost: one NSLock + two UInt64s.
    //
    // The counter is encoded in the on-wire nonce at bytes [4..11] BE, so we
    // extract it without a separate field. Window size 64 follows RFC 3711
    // §3.3.2 (SRTP anti-replay), adequate for VoIP where reorder is < 1 s.
    //
    // This is a receiver-only change: the sender's seal() path is unchanged,
    // no wire format differs, and Android/desktop don't need updating.
    private let replayLock = NSLock()
    private var replayInitialized = false
    private var replayHighest: UInt64 = 0   // highest accepted counter
    private var replayWindow:  UInt64 = 0   // bitmask: bit i → (replayHighest−i) seen
    private static let replayWindowSize: UInt64 = 64

    public enum SealerError: Error, Equatable {
        case wrongKeyLength(Int)
        case sealFailed
        case openFailed
        case truncated
    }

    /// Create a new sealer.
    ///
    /// - Parameters:
    ///   - pqcSessionKey: 32-byte ML-KEM-derived shared secret.
    ///   - callId: Unique identifier for the call session (e.g. the
    ///     CallKit UUID string). When non-empty the HKDF info string
    ///     becomes `"q-audion-srtp-master-v1:<callId>"`, binding the
    ///     derived key to this specific call session (M-15). Pass `""`
    ///     for backward-compat / tests where the callId is unknown.
    ///     ⚠️ Both parties MUST supply the SAME callId; mismatched
    ///     callIds produce different master keys and interop fails.
    public init(pqcSessionKey: Data, callId: String = "") throws {
        guard pqcSessionKey.count == 32 else {
            throw SealerError.wrongKeyLength(pqcSessionKey.count)
        }
        let infoString = callId.isEmpty
            ? "q-audion-srtp-master-v1"
            : "q-audion-srtp-master-v1:\(callId)"
        let info = Data(infoString.utf8)
        self.info = info
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: pqcSessionKey),
            salt: Self.salt,
            info: info,
            outputByteCount: Self.masterKeySize
        )
        self.masterKey = derived
    }

    /// Private designated init reusing an already-derived master key —
    /// used by ``makeSibling()`` so the recv direction shares the key
    /// material AND the call-bound info string (M-13, M-15).
    private init(reusingMasterKey key: SymmetricKey, info: Data) {
        self.masterKey = key
        self.info = info
    }

    /// M-13 — produce an independent sealer that shares this sealer's
    /// derived master key and call-bound info string but has its own
    /// fresh counter (starts at 0). Use the original for one direction
    /// (seal) and the sibling for the other (open) so the two counter
    /// spaces never collide.
    public func makeSibling() -> PqcRtpFrameSealer {
        return PqcRtpFrameSealer(reusingMasterKey: masterKey, info: info)
    }

    /// Seal one RTP payload. Counter-based nonce so calling repeatedly
    /// without rekeying never reuses (key, nonce) — safe up to 2^64
    /// frames per call (effectively forever for any realistic call).
    public func seal(_ plaintext: Data) throws -> Data {
        let nonceBytes = nextNonce()
        do {
            let nonce = try AES.GCM.Nonce(data: nonceBytes)
            let sealed = try AES.GCM.seal(plaintext,
                                            using: masterKey,
                                            nonce: nonce)
            var out = Data(capacity: Self.nonceSize + sealed.ciphertext.count + Self.tagSize)
            out.append(nonceBytes)
            out.append(sealed.ciphertext)
            out.append(sealed.tag)
            return out
        } catch {
            throw SealerError.sealFailed
        }
    }

    /// Open one sealed frame. The peer's counter is reflected in the
    /// nonce we read off the wire. Out-of-order delivery within the 64-frame
    /// sliding window is accepted; replayed or excessively late frames are
    /// rejected (M-14 anti-replay — receiver side only, no wire change).
    public func open(_ sealed: Data) throws -> Data {
        guard sealed.count >= Self.nonceSize + Self.tagSize else {
            throw SealerError.truncated
        }
        let base = sealed.startIndex
        let nonceBytes = sealed.subdata(in: base..<(base + Self.nonceSize))
        // Extract the 8-byte BE counter from nonce bytes [4..11].
        let wireCounter: UInt64 = {
            var v: UInt64 = 0
            for i in 0..<8 {
                v = (v << 8) | UInt64(nonceBytes[nonceBytes.startIndex + 4 + i])
            }
            return v
        }()
        // M-14: reject replays before attempting AEAD open (saves crypto cost
        // and closes the replay window before the authentication check).
        guard checkAndUpdateReplay(counter: wireCounter) else {
            throw SealerError.openFailed
        }
        let tag = sealed.suffix(Self.tagSize)
        let ct = sealed.subdata(in: (base + Self.nonceSize)..<(sealed.endIndex - Self.tagSize))
        do {
            let nonce = try AES.GCM.Nonce(data: nonceBytes)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
            return try AES.GCM.open(box, using: masterKey)
        } catch {
            throw SealerError.openFailed
        }
    }

    /// M-14 — sliding-window anti-replay check. Returns true if the counter
    /// is fresh and should be accepted; false if it is a replay or falls
    /// outside the window (too old). Updates the window on acceptance.
    private func checkAndUpdateReplay(counter: UInt64) -> Bool {
        replayLock.lock()
        defer { replayLock.unlock() }
        if !replayInitialized {
            replayInitialized = true
            replayHighest = counter
            replayWindow = 1   // bit 0 = highest = seen
            return true
        }
        if counter > replayHighest {
            let shift = counter - replayHighest
            replayWindow = shift >= Self.replayWindowSize
                ? 1
                : (replayWindow >> shift) | 1
            replayHighest = counter
            return true
        }
        let gap = replayHighest - counter
        guard gap < Self.replayWindowSize else { return false }   // too old
        let bit: UInt64 = 1 << gap
        if (replayWindow & bit) != 0 { return false }   // already seen
        replayWindow |= bit
        return true
    }

    private func nextNonce() -> Data {
        nonceLock.lock()
        let v = counter
        counter &+= 1
        nonceLock.unlock()
        var bytes = Data(count: Self.nonceSize)
        // Big-endian 8-byte counter at the END of the 12-byte nonce
        // (first 4 bytes = 0). Same layout SRTP uses for AES-GCM.
        for i in 0..<8 {
            bytes[bytes.startIndex + 4 + i] = UInt8((v >> ((7 - i) * 8)) & 0xFF)
        }
        return bytes
    }
}
#endif

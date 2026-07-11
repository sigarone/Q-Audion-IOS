import Foundation
import CryptoKit

// W574e — sealer ungated from `#if canImport(WebRTC)`. Its crypto is pure
// CryptoKit (the former `import WebRTC` was unused — only referenced in
// doc comments). Ungating lets the BcryptoWsRelay audio path in
// CallService apply the same M-15 seal that Android's
// BcryptoWsFrameRelayTransport applies, which is REQUIRED for
// Android↔iOS relay audio interop (Android seals unconditionally). The
// WebRTC-SRTP adapter (PqcFrameEncryptorAdapter) stays WebRTC-gated and
// still references this class unchanged.

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
    // is still correct. Adding a sliding window on the open() path blocks
    // replay attacks at negligible cost: one NSLock + a small bitmask.
    //
    // The counter is encoded in the on-wire nonce at bytes [4..11] BE, so we
    // extract it without a separate field.
    //
    // WINDOW SIZE (2026-07-11, W-DCCHURN): originally 64 frames (1.28s @
    // 20ms/frame), following RFC 3711 §3.3.2 (SRTP anti-replay, reorder < 1s).
    // Desktop's sealed-audio DataChannel churns (closes/reopens) every
    // ~10-15s for the whole call when flaky — a native SCTP-layer issue
    // below both apps' source (see graphify-investigated
    // audio-dc-churn-investigation, 2026-07-11), mitigated but not
    // root-caused by Desktop's swapToWsRelay() in-place transport swap
    // (d858eea). Each swap can strand already-sealed frames behind newer
    // ones, and a 64-frame window rejected them as false-positive replays
    // (iOS measured 27/16125 ≈0.17% RX decrypt errors on one such call).
    // Widened to 512 frames (~10.24s @ 20ms/frame) to cover a full churn
    // cycle. Receiver-only, non-wire-breaking (Android/Desktop unaffected).
    private let replayLock = NSLock()
    private var replayInitialized = false
    private var replayHighest: UInt64 = 0   // highest accepted counter
    private static let replayWindowSize: UInt64 = 512
    private static let replayWindowWordCount = Int(replayWindowSize / 64)
    // Bitmask split across 64-bit words: bit i of the logical window lives
    // in word i/64, offset i%64. word[0] holds bits 0..63 (most recent).
    private var replayWindow: [UInt64] =
        [UInt64](repeating: 0, count: PqcRtpFrameSealer.replayWindowWordCount)

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

    /// SECURITY (W574x) — directional per-direction keys.
    ///
    /// The legacy `init` + ``makeSibling()`` pair derives ONE master key shared
    /// by both call legs, so caller frame N and callee frame N reuse the same
    /// (key, nonce = 4 zero bytes || counter-from-0) — catastrophic for AES-GCM
    /// (plaintext-XOR leak + GHASH H recovery → forgery) and visible to the
    /// untrusted relay. This factory derives TWO independent keys via distinct
    /// HKDF info labels and assigns one per direction:
    ///
    ///   A→B key = HKDF(sessionKey, salt, "q-audion-srtp-master-v1:<callId>:a2b")
    ///   B→A key = HKDF(sessionKey, salt, "q-audion-srtp-master-v1:<callId>:b2a")
    ///
    /// Role "A" = peer with the lexicographically-smaller userId (see
    /// ``selfIsRoleA(_:_:)``). Returns (send, recv); A.send key == B.recv key.
    /// Byte-identical KAT with Android/Desktop `createDirectional`.
    public static func createDirectional(
        pqcSessionKey: Data,
        callId: String,
        selfIsRoleA: Bool
    ) throws -> (send: PqcRtpFrameSealer, recv: PqcRtpFrameSealer) {
        guard pqcSessionKey.count == 32 else {
            throw SealerError.wrongKeyLength(pqcSessionKey.count)
        }
        let base = callId.isEmpty
            ? "q-audion-srtp-master-v1"
            : "q-audion-srtp-master-v1:\(callId)"
        let infoA2B = Data("\(base):a2b".utf8)
        let infoB2A = Data("\(base):b2a".utf8)
        let ikm = SymmetricKey(data: pqcSessionKey)
        let keyA2B = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: Self.salt, info: infoA2B,
            outputByteCount: Self.masterKeySize
        )
        let keyB2A = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: Self.salt, info: infoB2A,
            outputByteCount: Self.masterKeySize
        )
        let send = selfIsRoleA
            ? PqcRtpFrameSealer(reusingMasterKey: keyA2B, info: infoA2B)
            : PqcRtpFrameSealer(reusingMasterKey: keyB2A, info: infoB2A)
        let recv = selfIsRoleA
            ? PqcRtpFrameSealer(reusingMasterKey: keyB2A, info: infoB2A)
            : PqcRtpFrameSealer(reusingMasterKey: keyA2B, info: infoA2B)
        return (send, recv)
    }

    /// Deterministic direction-role assignment shared by all platforms. Role "A"
    /// = the peer whose userId is lexicographically smaller compared unsigned,
    /// byte-wise, over the lowercase UTF-8 bytes. Identical on iOS/Android/Desktop.
    public static func selfIsRoleA(_ selfUserId: String, _ peerUserId: String) -> Bool {
        let a = Array(selfUserId.lowercased().utf8)
        let b = Array(peerUserId.lowercased().utf8)
        let n = min(a.count, b.count)
        var i = 0
        while i < n {
            if a[i] != b[i] { return a[i] < b[i] }
            i += 1
        }
        return a.count <= b.count
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
            for i in replayWindow.indices { replayWindow[i] = 0 }
            replayWindow[0] = 1   // bit 0 = highest = seen
            return true
        }
        if counter > replayHighest {
            let shift = counter - replayHighest
            if shift >= Self.replayWindowSize {
                for i in replayWindow.indices { replayWindow[i] = 0 }
            } else {
                shiftWindowRight(by: Int(shift))
            }
            setWindowBit(0)
            replayHighest = counter
            return true
        }
        let gap = replayHighest - counter
        guard gap < Self.replayWindowSize else { return false }   // too old
        if testWindowBit(Int(gap)) { return false }   // already seen
        setWindowBit(Int(gap))
        return true
    }

    private func setWindowBit(_ index: Int) {
        replayWindow[index / 64] |= (1 << UInt64(index % 64))
    }

    private func testWindowBit(_ index: Int) -> Bool {
        (replayWindow[index / 64] & (1 << UInt64(index % 64))) != 0
    }

    /// Right-shifts the whole multi-word bitmask by `n` bits (n < window
    /// size, guaranteed by the caller). word[0] holds the least-significant
    /// (most recent) bits, so shifting right moves bits toward higher words
    /// — same direction as the original single-UInt64 `>> shift`.
    private func shiftWindowRight(by n: Int) {
        guard n > 0 else { return }
        let wordShift = n / 64
        let bitShift = n % 64
        let count = replayWindow.count
        if bitShift == 0 {
            for i in 0..<count {
                replayWindow[i] = (i + wordShift < count) ? replayWindow[i + wordShift] : 0
            }
            return
        }
        for i in 0..<count {
            let lo = (i + wordShift < count) ? (replayWindow[i + wordShift] >> UInt64(bitShift)) : 0
            let hiIdx = i + wordShift + 1
            let hi = (hiIdx < count) ? (replayWindow[hiIdx] << UInt64(64 - bitShift)) : 0
            replayWindow[i] = lo | hi
        }
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

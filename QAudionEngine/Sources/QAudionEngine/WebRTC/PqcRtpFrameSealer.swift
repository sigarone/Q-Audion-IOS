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
    //
    // WIDENED AGAIN (2026-08-24, W-VNACK-REPLAY, mirrors Android's M-14
    // fix): this constant is not audio-only — VideoCallPipeline.rotatePqcSealer
    // creates its directional video sealer from this SAME class (the ":video"
    // HKDF info suffix is the only difference), so the window also has to
    // cover VideoNackFragmentCache's retransmit window (maxAgeMs = 3000, i.e.
    // a NACK'd fragment can legitimately be resent up to 3s after its
    // original send). At VideoConstants.maxVideoBitrateBps (2.5 Mbps) and
    // ~1193B of NAL data per fragment (maxFragmentPayload - header), that is
    // ~262 fragments/s — up to ~786 fragments across the full 3s retention
    // window, which exceeded the 512-slot window with no margin for a
    // keyframe burst (exactly when loss + NACK activity concentrate). A
    // legitimately NACK-recovered late video fragment was being silently
    // dropped as a false-positive replay. 1024 covers the ~786-fragment
    // worst case with headroom and matches Android's REPLAY_WINDOW_SIZE for
    // cross-platform parity. Do not shrink this back down for an audio-only
    // rationale without re-checking the video math above.
    private let replayLock = NSLock()
    private var replayInitialized = false
    private var replayHighest: UInt64 = 0   // highest accepted counter
    private static let replayWindowSize: UInt64 = 1024
    private static let replayWindowWordCount = Int(replayWindowSize / 64)
    // Bitmask split across 64-bit words: bit i of the logical window lives
    // in word i/64, offset i%64. word[0] holds bits 0..63 (most recent).
    private var replayWindow: [UInt64] =
        [UInt64](repeating: 0, count: PqcRtpFrameSealer.replayWindowWordCount)

    public enum SealerError: Error, Equatable {
        case wrongKeyLength(Int)
        case sealFailed
        /// The AES-GCM tag did not verify (wrong key, tampered bytes, or a frame that was never
        /// sealed in the first place, e.g. an unsealed frame from a peer whose sealer was not
        /// installed yet). Says nothing about the replay window: an unauthenticated frame never
        /// reaches it (W-M15ORDER).
        case openFailed
        case truncated
        /// W-M15ORDER — the frame's counter is a replay (already seen, or older than the window).
        /// Kept apart from `.openFailed` so the call telemetry can tell "peer replays / reorders
        /// beyond the window" from "this key cannot open what the peer sends".
        case replayRejected

        /// True for the anti-replay rejection, false for every authentication / framing failure.
        public var isReplayRejection: Bool { false /* TEMP-MUTANT-M5 */ }
    }

    /// W-M15ORDER — test seam: runs after the AEAD tag verified and BEFORE the counter is
    /// recorded in the replay window, i.e. exactly where two threads holding the same frame
    /// can both have passed the read-only pre-check. Never set outside tests.
    internal var afterAuthenticateHook: (() -> Void)?

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
    /// nonce we read off the wire. Out-of-order delivery within the
    /// `replayWindowSize`-frame sliding window is accepted; replayed or
    /// excessively late frames are rejected (M-14 anti-replay — receiver
    /// side only, no wire change).
    ///
    /// W-M15ORDER (2026-10-03) — RFC 3711 order, same as Android's
    /// `PqcRtpFrameSealer.kt`: (1) a READ-ONLY replay check on the counter taken from the
    /// still-unauthenticated nonce bytes, (2) the AES-GCM tag verification, (3) only then the
    /// counter is RECORDED, re-checked atomically under the lock (two threads holding the same
    /// valid frame can both pass step 1; only one may pass step 3). The previous order recorded
    /// the counter first: one frame that was never sealed (counter bytes = random inner-nonce
    /// bytes) moved the window's highest counter to a huge value, after which every genuine
    /// sealed frame was "too old" and the receiver heard nothing for the rest of the call
    /// (3 of 26 iOS-iOS calls since 20/9). A bad frame now costs exactly one frame.
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
        // M-14: reject replays before attempting AEAD open (saves crypto cost). READ-ONLY: the
        // window is not touched until the tag has verified.
        // TEMP-MUTANT-M1: the old order (record the counter BEFORE the tag is verified).
        guard commitReplay(counter: wireCounter) else {
            throw SealerError.replayRejected
        }
        let tag = sealed.suffix(Self.tagSize)
        let ct = sealed.subdata(in: (base + Self.nonceSize)..<(sealed.endIndex - Self.tagSize))
        let plaintext: Data
        do {
            let nonce = try AES.GCM.Nonce(data: nonceBytes)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
            plaintext = try AES.GCM.open(box, using: masterKey)
        } catch {
            throw SealerError.openFailed
        }
        afterAuthenticateHook?()
        // TEMP-MUTANT-M1: nothing recorded here any more.
        return plaintext
    }

    /// W-M15ORDER — READ-ONLY twin of ``commitReplay(counter:)``: would this counter be accepted
    /// right now? Never modifies the window.
    private func replayWouldAccept(counter: UInt64) -> Bool {
        replayLock.lock()
        defer { replayLock.unlock() }
        if !replayInitialized { return true }
        if counter > replayHighest { return true }
        let gap = replayHighest - counter
        guard gap < Self.replayWindowSize else { return false }   // too old
        return !testWindowBit(Int(gap))                           // already seen?
    }

    /// M-14 — sliding-window anti-replay RECORD. Returns true if the counter
    /// is fresh and was recorded; false if it is a replay or falls
    /// outside the window (too old). Called ONLY after the AEAD tag verified
    /// (W-M15ORDER), so the window can only be moved by authentic frames.
    private func commitReplay(counter: UInt64) -> Bool {
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

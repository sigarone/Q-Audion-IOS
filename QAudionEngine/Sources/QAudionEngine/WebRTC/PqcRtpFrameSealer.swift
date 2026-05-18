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
    private static let info = Data("q-audion-srtp-master-v1".utf8)

    private let masterKey: SymmetricKey
    private let nonceLock = NSLock()
    private var counter: UInt64 = 0

    public enum SealerError: Error, Equatable {
        case wrongKeyLength(Int)
        case sealFailed
        case openFailed
        case truncated
    }

    public init(pqcSessionKey: Data) throws {
        guard pqcSessionKey.count == 32 else {
            throw SealerError.wrongKeyLength(pqcSessionKey.count)
        }
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: pqcSessionKey),
            salt: Self.salt,
            info: Self.info,
            outputByteCount: Self.masterKeySize
        )
        self.masterKey = derived
    }

    /// Private designated init reusing an already-derived master key —
    /// used by ``makeSibling()`` so the recv direction shares the key
    /// material but keeps an independent `counter` (M-13).
    private init(reusingMasterKey key: SymmetricKey) {
        self.masterKey = key
    }

    /// M-13 — produce an independent sealer that shares this sealer's
    /// derived master key but has its own fresh counter (starts at 0).
    /// Use the original for one direction (seal) and the sibling for
    /// the other (open) so the two counter spaces never collide.
    public func makeSibling() -> PqcRtpFrameSealer {
        return PqcRtpFrameSealer(reusingMasterKey: masterKey)
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
    /// nonce we read off the wire, so out-of-order delivery doesn't
    /// require a window — each frame is self-contained.
    public func open(_ sealed: Data) throws -> Data {
        guard sealed.count >= Self.nonceSize + Self.tagSize else {
            throw SealerError.truncated
        }
        let base = sealed.startIndex
        let nonceBytes = sealed.subdata(in: base..<(base + Self.nonceSize))
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

import Foundation
#if canImport(WebRTC)
import WebRTC

/// W382 — RTCFrameEncryptor / RTCFrameDecryptor adapter on top of
/// PqcRtpFrameSealer (W376).
///
/// Plugs into RTCRtpSender / RTCRtpReceiver via:
///   sender.frameEncryptor = PqcFrameEncryptor(sealer: sealer)
///   receiver.frameDecryptor = PqcFrameDecryptor(sealer: sealer)
///
/// On the wire, every audio/video RTP packet payload is wrapped by
/// the sealer's `nonce(12) || ciphertext || tag(16)` envelope BEFORE
/// the standard SRTP layer wraps it. This means the PQC layer is
/// orthogonal to DTLS-SRTP — even if SRTP's classical key exchange
/// is compromised post-quantum, the inner ML-KEM-derived layer
/// stays sealed.
///
/// **Important:** RTCFrameEncryptor / RTCFrameDecryptor are part of
/// the WebRTC M86+ insertable-streams API. Some WebRTC iOS binary
/// builds expose these protocols as `@objc` only. The stasel/WebRTC
/// 131.x build (W347 dep) ships them publicly.
///
/// **Note:** the protocols expect the encrypt path to fit the
/// output into a Data buffer of exactly the right size. Our sealer
/// adds 28 bytes (12 nonce + 16 tag) per frame; this adapter
/// pre-computes the size via `getMaxCiphertextByteSize` so WebRTC
/// allocates the right buffer.
public final class PqcFrameEncryptor: NSObject, RTCFrameEncryptor {
    private let sealer: PqcRtpFrameSealer

    public init(sealer: PqcRtpFrameSealer) {
        self.sealer = sealer
        super.init()
    }

    public func encrypt(
        _ mediaType: RTCRtpMediaType,
        ssrc: UInt32,
        frameType: UnsafeMutablePointer<UInt8>?,
        frame: Data
    ) -> Data {
        do {
            return try sealer.seal(frame)
        } catch {
            print("[PqcFrameEncryptor] seal failed: \(error)")
            // Fail closed — return an empty Data so SRTP rejects rather
            // than letting an unsealed frame slip through.
            return Data()
        }
    }

    public func getMaxCiphertextByteSize(
        _ mediaType: RTCRtpMediaType, plaintextSize: Int
    ) -> Int {
        // nonce(12) + ciphertext(plaintextSize) + tag(16)
        return plaintextSize + PqcRtpFrameSealer.nonceSize + PqcRtpFrameSealer.tagSize
    }
}

/// Inverse of [PqcFrameEncryptor].
public final class PqcFrameDecryptor: NSObject, RTCFrameDecryptor {
    private let sealer: PqcRtpFrameSealer

    public init(sealer: PqcRtpFrameSealer) {
        self.sealer = sealer
        super.init()
    }

    public func decrypt(
        _ mediaType: RTCRtpMediaType,
        ssrc: UInt32,
        frameType: UnsafeMutablePointer<UInt8>?,
        frame: Data
    ) -> Data {
        do {
            return try sealer.open(frame)
        } catch {
            print("[PqcFrameDecryptor] open failed: \(error)")
            return Data()
        }
    }

    public func getMaxPlaintextByteSize(
        _ mediaType: RTCRtpMediaType, ciphertextSize: Int
    ) -> Int {
        // ciphertext is plaintext + 28 bytes overhead.
        return max(0, ciphertextSize - PqcRtpFrameSealer.nonceSize - PqcRtpFrameSealer.tagSize)
    }
}
#endif

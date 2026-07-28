import Foundation
#if canImport(WebRTC)
import WebRTC

/// W386 — engine-side adapters around PqcRtpFrameSealer (W376).
///
/// **Status note:** the stasel/WebRTC 131.0.0 binary build (W347 SPM
/// dep) does NOT expose the `RTCFrameEncryptor` / `RTCFrameDecryptor`
/// protocols nor the `frameEncryptor` / `frameDecryptor` properties
/// on `RTCRtpSender` / `RTCRtpReceiver`. Those are part of WebRTC's
/// M86+ insertable-streams API but get stripped from many community
/// binary distributions to reduce binary size.
///
/// This file ships the engine-side seal/open adapters as plain
/// NSObject classes (no protocol conformance) so callers OUTSIDE the
/// SRTP path (e.g. the BcryptoWsRelay sealed-frame transport) can
/// still invoke them directly.
///
/// **Migration path:** when a future WebRTC iOS binary exposes the
/// insertable-streams protocols, add the `RTCFrameEncryptor` /
/// `RTCFrameDecryptor` conformance + the platform-specific
/// `encrypt(_:ssrc:frameType:frame:)` / `decrypt(...)` methods. The
/// inner sealer logic stays unchanged.
public final class PqcFrameEncryptor: NSObject {
    private let sealer: PqcRtpFrameSealer

    public init(sealer: PqcRtpFrameSealer) {
        self.sealer = sealer
        super.init()
    }

    /// M-31 — Engine-side seal. Returns `nonce(12) || ciphertext ||
    /// tag(16)` on success, or `nil` on seal failure so callers can
    /// distinguish a genuine empty frame from a crypto failure (and
    /// MUST drop the frame rather than transmit plaintext).
    public func sealFrame(_ frame: Data) -> Data? {
        do { return try sealer.seal(frame) } catch {
            let edesc: String = error.localizedDescription
            let line: String = "[PqcFrameEncryptor] seal failed: " + edesc
            print(line)
            return nil
        }
    }

    /// M-31 compat shim — preserves the original non-optional API for
    /// callers outside the owned set (e.g. VideoCallPipeline). Maps a
    /// seal failure to empty `Data` AND logs. New code should call
    /// ``sealFrame(_:)`` and treat `nil` as "drop the frame".
    public func encryptPlaintext(_ frame: Data) -> Data {
        guard let sealed = sealFrame(frame) else {
            let line: String = "[PqcFrameEncryptor] encryptPlaintext: seal failure mapped to empty Data (legacy compat) — frame must be dropped, NOT sent as plaintext"
            print(line)
            return Data()
        }
        return sealed
    }

    /// Pre-compute output size: plaintext + nonce(12) + tag(16).
    public func maxCiphertextSize(plaintextSize: Int) -> Int {
        return plaintextSize + PqcRtpFrameSealer.nonceSize + PqcRtpFrameSealer.tagSize
    }
}

/// Inverse of [PqcFrameEncryptor].
public final class PqcFrameDecryptor: NSObject {
    private let sealer: PqcRtpFrameSealer

    public init(sealer: PqcRtpFrameSealer) {
        self.sealer = sealer
        super.init()
    }

    /// Engine-side open — direct entry point for non-WebRTC transports.
    public func decryptCiphertext(_ frame: Data) -> Data {
        do { return try sealer.open(frame) } catch {
            print("[PqcFrameDecryptor] open failed: \(error)")
            return Data()
        }
    }

    public func maxPlaintextSize(ciphertextSize: Int) -> Int {
        return max(0, ciphertextSize - PqcRtpFrameSealer.nonceSize - PqcRtpFrameSealer.tagSize)
    }
}
#endif

import Foundation
#if canImport(WebRTC)
import WebRTC

/// Native libwebrtc FrameCryptor (insertable streams) attached to the RTP video
/// sender/receiver. Byte-identical to the Android native FrameCryptor in
/// `PeerConnectionHolder.kt` (createFrameCryptorKeyProvider :354-371 +
/// createFrameCryptorForRtpSender/Receiver :471-514).
///
/// WHY native (not the old codec-layer `SFrameVideoEncoderDecorator`): the
/// codec-layer cryptor seals the encoded frame BEFORE RTP packetization, and the
/// H265 packetizer then reshapes the NALUs so the bytes reaching the peer's
/// decoder no longer match what was sealed → AES-GCM unseal fails
/// (`[LiveKitVideoCryptor] decoder open failed`). The native FrameCryptor
/// encrypts AFTER packetization (codec-agnostic), so H265 works, and it is
/// wire-compatible with Android which uses the same native cryptor.
///
/// Config (ALL must match Android for cross-platform decrypt):
///   algorithm = AES-GCM (32-byte key ⇒ AES-256-GCM), key index 0, shared-key
///   mode, ratchetSalt EMPTY, ratchetWindowSize 0, no magic bytes,
///   failureTolerance -1, keyRingSize 16, discardFrameWhenCryptorNotReady true,
///   key-derivation HKDF. The key is the RAW 32-byte K_video — the native binary
///   runs its own Stage-2 HKDF (salt=∅, info=128×0x00, L=32) on top, identical
///   across iOS/Android/Desktop.
///
/// CLAUDE.md §16: this is a new file but takes ONLY RTC* + Data/String params —
/// never `AppState` — so it does not trip the Sendable-inference build break.
public final class NativeVideoFrameCryptor: @unchecked Sendable {
    public let keyProvider: RTCFrameCryptorKeyProvider
    private let factory: RTCPeerConnectionFactory
    private let participantId: String
    private var senderCryptor: RTCFrameCryptor?
    private var receiverCryptor: RTCFrameCryptor?
    private var hasKey = false
    private let lock = NSLock()

    public init(factory: RTCPeerConnectionFactory, participantId: String) {
        self.factory = factory
        self.participantId = participantId
        // EXACT Android params (PeerConnectionHolder.kt:354-370). Use the FULL
        // initializer so failureTolerance / keyRingSize /
        // discardFrameWhenCryptorNotReady / keyDerivationAlgorithm are pinned
        // (the short init leaves them at native defaults that differ from
        // Android — see workflow KEY PROVIDER CONFIG note).
        self.keyProvider = RTCFrameCryptorKeyProvider(
            ratchetSalt: Data(),                 // ByteArray(0)
            ratchetWindowSize: 0,
            sharedKeyMode: true,                 // sharedKey = true
            uncryptedMagicBytes: nil,            // ByteArray(0) → nil
            failureTolerance: -1,                // infinite (never auto-disable)
            keyRingSize: 16,
            discardFrameWhenCryptorNotReady: true,
            // RTCKeyDerivationAlgorithm NS_ENUM(NSUInteger): PBKDF2=0, HKDF=1
            // (RTCFrameCryptorKeyProvider.h, webrtc-sdk m144). The Swift bridge
            // rejects `.hkdf` (all-caps acronym case isn't lowercased like
            // `.aesGcm`), so construct by rawValue — bridge-spelling-proof.
            // HKDF matches Android FrameCryptorKeyDerivationAlgorithm.HKDF.
            keyDerivationAlgorithm: RTCKeyDerivationAlgorithm(rawValue: 1)!
        )
    }

    public var keyIsSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return hasKey
    }

    /// Publish / rotate the 32-byte K_video at index 0 (Android setSharedKey(0,key)).
    /// Safe to call before OR after the cryptors are attached — the native
    /// KeyProvider drops inbound frames until a key is present
    /// (discardFrameWhenCryptorNotReady), so attach-before-key is fine.
    public func setKey(_ kVideo: Data) {
        guard kVideo.count == 32 else {
            print("[NativeVideoFrameCryptor] setKey ignored — key is \(kVideo.count) bytes, expected 32")
            return
        }
        lock.lock(); defer { lock.unlock() }
        keyProvider.setSharedKey(kVideo, with: 0)   // ObjC -setSharedKey:withIndex:
        hasKey = true
    }

    /// Create + enable the sender cryptor. Idempotent. Does NOT require the key
    /// to be set yet (the shared KeyProvider holds it; frames are discarded
    /// until setKey runs). Must run on the WebRTC signalling thread / a WebRTC
    /// callback — call from setLocalDescription completion or ensureVideoSealer.
    @discardableResult
    public func attachSender(_ sender: RTCRtpSender) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard senderCryptor == nil else { return true }
        guard let c = RTCFrameCryptor(factory: factory,
                                      rtpSender: sender,
                                      participantId: participantId,
                                      algorithm: .aesGcm,
                                      keyProvider: keyProvider) else {
            print("[NativeVideoFrameCryptor] sender cryptor init returned nil (sender.track nil?) — will retry")
            return false
        }
        c.keyIndex = 0
        c.enabled = true
        senderCryptor = c
        print("[NativeVideoFrameCryptor] sender cryptor attached (aesGcm, idx0, hasKey=\(hasKey))")
        return true
    }

    /// Create + enable the receiver cryptor. Idempotent. Call from the
    /// didAdd-rtpReceiver delegate (runs on the WebRTC signalling thread).
    @discardableResult
    public func attachReceiver(_ receiver: RTCRtpReceiver) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard receiverCryptor == nil else { return true }
        guard let c = RTCFrameCryptor(factory: factory,
                                      rtpReceiver: receiver,
                                      participantId: participantId,
                                      algorithm: .aesGcm,
                                      keyProvider: keyProvider) else {
            print("[NativeVideoFrameCryptor] receiver cryptor init returned nil — will retry")
            return false
        }
        c.keyIndex = 0
        c.enabled = true
        receiverCryptor = c
        print("[NativeVideoFrameCryptor] receiver cryptor attached (aesGcm, idx0, hasKey=\(hasKey))")
        return true
    }

    public func setEnabled(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        senderCryptor?.enabled = on
        receiverCryptor?.enabled = on
    }

    /// Release BEFORE peerConnection.close() — the cryptors hold a native ref
    /// into the sender/receiver (Android dispose order PeerConnectionHolder.kt:993-997).
    public func dispose() {
        lock.lock(); defer { lock.unlock() }
        senderCryptor?.enabled = false
        receiverCryptor?.enabled = false
        senderCryptor = nil
        receiverCryptor = nil
    }
}
#endif

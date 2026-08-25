import Foundation
#if canImport(WebRTC)
import WebRTC

/// IOS-C4b (2026-08-26) — native libwebrtc FrameCryptor (insertable streams)
/// attached to the RTP AUDIO sender/receiver, for
/// ``CallCapabilities/audioSrtpV1``. Sibling of ``NativeVideoFrameCryptor``,
/// same params, same shape, same construction/dispose discipline — kept as a
/// SEPARATE class (own `RTCFrameCryptorKeyProvider`, own key ring) rather
/// than sharing the video one, mirroring Android's `PeerConnectionHolder.kt`
/// (`audioFrameCryptorKeyProvider` distinct from `frameCryptorKeyProvider`):
/// audio and video use independent epoch counters and must never share a key
/// ring slot space.
///
/// Config (ALL must match Android for cross-platform decrypt — see
/// `PeerConnectionHolder.applyAudioFrameCryptionKey`, `CallCapabilities.kt`
/// :354-370 for video's identical params, reused verbatim for audio):
///   algorithm = AES-GCM (32-byte key => AES-256-GCM), shared-key mode,
///   ratchetSalt EMPTY, ratchetWindowSize 0, no magic bytes, failureTolerance
///   -1, keyRingSize 16, discardFrameWhenCryptorNotReady true, key-derivation
///   HKDF. The key is the RAW 32-byte PQC session key — no K_video-style
///   derivation for audio (Android installs the raw session key directly,
///   `installLiveMediaKeys` -> `setAudioSrtpKey`).
///
/// Symbol provenance: `RTCFrameCryptor`/`RTCFrameCryptorKeyProvider`/
/// `RTCKeyDerivationAlgorithm`/`RTCFrameCryptorDelegate`/
/// `RTCFrameCryptionState` are the EXACT symbols `NativeVideoFrameCryptor`
/// already uses successfully in this repo's own `WebRTC` binaryTarget (not
/// `LiveKitWebRTC` — that is a separate, prefixed dependency used only for
/// group calls) — this file is a structural sibling, not a new API surface.
public final class NativeAudioFrameCryptor: NSObject, @unchecked Sendable {
    public let keyProvider: RTCFrameCryptorKeyProvider
    private let factory: RTCPeerConnectionFactory
    private let participantId: String
    private var senderCryptor: RTCFrameCryptor?
    private var receiverCryptor: RTCFrameCryptor?
    private var hasKey = false
    private let lock = NSLock()

    /// Mirrors ``NativeVideoFrameCryptor/onDecryptFailure`` — fired when the
    /// RECEIVER cryptor's native state callback reports DECRYPTIONFAILED /
    /// MISSINGKEY / INTERNALERROR. Not currently wired to a keyframe request
    /// (audio has no keyframe concept); reserved for future rekey-skew
    /// diagnostics.
    public var onDecryptFailure: (() -> Void)?

    public init(factory: RTCPeerConnectionFactory, participantId: String) {
        self.factory = factory
        self.participantId = participantId
        self.keyProvider = RTCFrameCryptorKeyProvider(
            ratchetSalt: Data(),
            ratchetWindowSize: 0,
            sharedKeyMode: true,
            uncryptedMagicBytes: nil,
            failureTolerance: -1,
            keyRingSize: 16,
            discardFrameWhenCryptorNotReady: true,
            // swiftlint:disable:next force_unwrapping
            keyDerivationAlgorithm: RTCKeyDerivationAlgorithm(rawValue: 1)!
        )
        super.init()
    }

    public var keyIsSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return hasKey
    }

    public var receiverIsAttached: Bool {
        lock.lock(); defer { lock.unlock() }
        return receiverCryptor != nil
    }

    public var senderIsAttached: Bool {
        lock.lock(); defer { lock.unlock() }
        return senderCryptor != nil
    }

    /// Publish / rotate the 32-byte raw PQC session key at index 0. Safe to
    /// call before OR after the cryptors are attached.
    public func setKey(_ key: Data) {
        guard key.count == 32 else {
            print("[NativeAudioFrameCryptor] setKey ignored — key is \(key.count) bytes, expected 32")
            return
        }
        lock.lock(); defer { lock.unlock() }
        keyProvider.setSharedKey(key, with: 0)
        hasKey = true
    }

    /// Create + enable the sender cryptor. Idempotent. Must run on the
    /// WebRTC signalling thread / a WebRTC callback, same constraint as
    /// ``NativeVideoFrameCryptor/attachSender(_:)``.
    @discardableResult
    public func attachSender(_ sender: RTCRtpSender) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard senderCryptor == nil else { return true }
        guard let c = RTCFrameCryptor(factory: factory,
                                      rtpSender: sender,
                                      participantId: participantId,
                                      algorithm: .aesGcm,
                                      keyProvider: keyProvider) else {
            print("[NativeAudioFrameCryptor] sender cryptor init returned nil (sender.track nil?) — will retry")
            return false
        }
        c.keyIndex = 0
        c.enabled = true
        senderCryptor = c
        print("[NativeAudioFrameCryptor] sender cryptor attached (aesGcm, idx0, hasKey=\(hasKey))")
        return true
    }

    /// Create + enable the receiver cryptor. Idempotent.
    @discardableResult
    public func attachReceiver(_ receiver: RTCRtpReceiver) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard receiverCryptor == nil else { return true }
        guard let c = RTCFrameCryptor(factory: factory,
                                      rtpReceiver: receiver,
                                      participantId: participantId,
                                      algorithm: .aesGcm,
                                      keyProvider: keyProvider) else {
            print("[NativeAudioFrameCryptor] receiver cryptor init returned nil — will retry")
            return false
        }
        c.keyIndex = 0
        c.enabled = true
        c.delegate = self
        receiverCryptor = c
        print("[NativeAudioFrameCryptor] receiver cryptor attached (aesGcm, idx0, hasKey=\(hasKey))")
        return true
    }

    public func setEnabled(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        senderCryptor?.enabled = on
        receiverCryptor?.enabled = on
    }

    /// Release BEFORE peerConnection.close() — same ordering discipline as
    /// ``NativeVideoFrameCryptor/dispose()``.
    public func dispose() {
        lock.lock(); defer { lock.unlock() }
        senderCryptor?.enabled = false
        receiverCryptor?.enabled = false
        senderCryptor = nil
        receiverCryptor = nil
    }
}

extension NativeAudioFrameCryptor: RTCFrameCryptorDelegate {
    public func frameCryptor(_ frameCryptor: RTCFrameCryptor,
                             didStateChangeWithParticipantId participantId: String,
                             with state: RTCFrameCryptionState) {
        switch state {
        case .decryptionFailed, .missingKey, .internalError:
            print("[NativeAudioFrameCryptor] receiver cryptor state=\(state.rawValue) participantId=\(participantId)")
            onDecryptFailure?()
        default:
            break
        }
    }
}
#endif

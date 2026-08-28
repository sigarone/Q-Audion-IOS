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
/// `RTCFrameCryptorState` are the EXACT symbols `NativeVideoFrameCryptor`
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

    /// Re-bind the receiver cryptor to the audio transceiver's CURRENT
    /// `RTCRtpReceiver`, after the SDP negotiation that made it live has
    /// actually completed. `attachReceiver` is write-once by design; this
    /// disposes the stale cryptor FIRST so the guard doesn't silently no-op
    /// against a cryptor still bound to a pre-negotiation receiver object.
    ///
    /// W-AUDIORXPOSTNEG (2026-08-28) — exact audio mirror of
    /// `NativeVideoFrameCryptor.rebindReceiver` / `QAudionPeerConnection.
    /// rebindVideoReceiverCryptorPostNegotiation`, for the identical bug
    /// class the 2026-07-05 "OFFERER-UPGRADE DECODE FIX" already found and
    /// fixed on the video receive side: `didAdd rtpReceiver` fires and
    /// `attachAudioReceiverCryptor` runs the FIRST time the audio receiver
    /// appears, which for a call negotiating `audioSrtpV1` from the very
    /// first SDP round can be before that round's answer/accept has
    /// actually landed. The native frame transformer then stays bound to
    /// that pre-negotiation state even once the RTP channel goes live:
    /// inbound audio bypasses the decryptor and never reaches the app as
    /// real PCM — `framesDecoded`-equivalent pinned at zero, permanently,
    /// for the whole call. This is exactly the failure shape of a real call
    /// (9b542759, Android<->iOS, 2026-08-28) that negotiated audio-srtp-v1
    /// and was ended by iOS's own W-MEDIADEAD watchdog after ~90s of zero
    /// decoded inbound audio — and it is also why the live Guardian voice-
    /// confidence graph never had anything to plot: `NativeAudioPcmTap`
    /// only ever sees real samples once the receiver cryptor actually
    /// decrypts, so a cryptor stuck on the pre-negotiation receiver starves
    /// `VoiceAnalysisEngine`/Guardian of real audio the same way it starves
    /// playback. The shared `keyProvider` already holds the key — no re-key
    /// needed, mirrors Android's own dispose+recreate for this exact class
    /// of bug (`PeerConnectionHolder.kt`, `enableAudioFrameCryptorOnSender`/
    /// receiver defer-and-flush pattern).
    @discardableResult
    public func rebindReceiver(_ receiver: RTCRtpReceiver) -> Bool {
        lock.lock()
        receiverCryptor?.enabled = false
        receiverCryptor = nil
        lock.unlock()
        return attachReceiver(receiver)
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
                             with state: RTCFrameCryptorState) {
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

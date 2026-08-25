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
///
/// W-KFFAST (2026-08-25) — inherits `NSObject` (was a bare final class)
/// solely so it can conform to `RTCFrameCryptorDelegate` below and be
/// assigned as the receiver cryptor's `delegate` — the same pattern
/// `QAudionWebRtcCallController` already uses to conform to
/// `QAudionPeerConnection.Delegate` (`NSObject, ...Delegate, @unchecked
/// Sendable`). No behavior change to the existing lock-guarded state.
public final class NativeVideoFrameCryptor: NSObject, @unchecked Sendable {
    public let keyProvider: RTCFrameCryptorKeyProvider
    private let factory: RTCPeerConnectionFactory
    private let participantId: String
    private var senderCryptor: RTCFrameCryptor?
    private var receiverCryptor: RTCFrameCryptor?
    private var hasKey = false
    private let lock = NSLock()

    /// W-KFFAST (2026-08-25) — fired when the RECEIVER cryptor's native
    /// state callback reports DECRYPTIONFAILED / MISSINGKEY / INTERNALERROR
    /// (rekey skew, a storm of failing frames, ratchet gap). Mirrors
    /// Android's `FrameCryptor.setObserver` hook in
    /// `PeerConnectionHolder.enableVideoFrameCryptorOnReceiver`
    /// (PeerConnectionHolder.kt:1551-1562) exactly: healthy states
    /// (NEW/OK/KEYRATCHETED) do not trigger. Set by
    /// `QAudionWebRtcCallController` at receiver-attach time; may fire
    /// from the WebRTC/native cryptor callback thread — consumers hop to
    /// @MainActor themselves.
    public var onDecryptFailure: (() -> Void)?

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
            // force-unwrap safe: rawValue 1 is HKDF, a defined case of this
            // fixed NS_ENUM (PBKDF2=0, HKDF=1) — a literal, not external data.
            // swiftlint:disable:next force_unwrapping
            keyDerivationAlgorithm: RTCKeyDerivationAlgorithm(rawValue: 1)!
        )
        super.init()
    }

    public var keyIsSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return hasKey
    }

    /// WIRE_SPEC §8.7 — true once `attachReceiver` succeeded. Combined
    /// with `keyIsSet` this is the "receiver cryptor is BOTH attached
    /// and keyed" readiness predicate that gates `call_media_ready`.
    public var receiverIsAttached: Bool {
        lock.lock(); defer { lock.unlock() }
        return receiverCryptor != nil
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
        // W-KFFAST (2026-08-25) — receiver-only (mirrors Android: only
        // `enableVideoFrameCryptorOnReceiver` calls `setObserver`, never
        // the sender side). `self` conforms to `RTCFrameCryptorDelegate`
        // below; the delegate property is weak on the native side so this
        // creates no retain cycle.
        c.delegate = self
        receiverCryptor = c
        print("[NativeVideoFrameCryptor] receiver cryptor attached (aesGcm, idx0, hasKey=\(hasKey))")
        return true
    }

    /// Re-bind the receiver cryptor to a NEW `RTCRtpReceiver` after a mid-call
    /// renegotiation legitimately moves inbound video to a different receiver
    /// object (WIRE_SPEC §8.6 relatch — see QAudionPeerConnection's
    /// `didAdd rtpReceiver` "RELATCH FIX"). `attachReceiver` is write-once by
    /// design (guards phantom duplicates); this disposes the stale cryptor
    /// FIRST so the guard doesn't silently no-op on the live receiver. The
    /// shared `keyProvider` already holds the key — no re-key needed, mirrors
    /// Android's dispose+recreate at PeerConnectionHolder.kt:3130-3138.
    @discardableResult
    public func rebindReceiver(_ receiver: RTCRtpReceiver) -> Bool {
        lock.lock()
        receiverCryptor?.enabled = false
        receiverCryptor = nil
        lock.unlock()
        return attachReceiver(receiver)
    }

    /// BUG2 fix (2026-07-11) — sender-side mirror of `rebindReceiver`, for
    /// the SAME class of bug the 2026-07-05 "OFFERER-UPGRADE DECODE FIX"
    /// already found and fixed on the receive side (see
    /// QAudionPeerConnection.rebindVideoReceiverCryptorPostNegotiation's
    /// doc): on the iOS-caller + iOS-video-upgrade combo, the video
    /// transceiver is created by a LOCAL `addTrack` on a second-round
    /// offer — attaching the cryptor to the sender AT THAT MOMENT (as
    /// `attachSender`/the fcdc84a fix does, immediately after
    /// `addLocalVideoTrack` and BEFORE the answer even comes back) binds
    /// to the sender's pre-negotiation state. The native frame transformer
    /// then stays attached to that stale binding even after the RTP
    /// channel goes live post-negotiation: outbound H265 either never
    /// gets sealed correctly or seals against a transformer that isn't
    /// wired to the ACTUAL live sender object, producing exactly the
    /// "receiver decrypts garbage / genuinely-corrupted wire bytes"
    /// symptom the peer observes (device-confirmed 2026-07-11 on
    /// Desktop's receive side: packetsLost=0, cutscan proves the bytes
    /// were never valid ciphertext for ANY NAL-boundary candidate).
    /// `attachSender` is write-once (guards phantom duplicates); this
    /// disposes the stale cryptor FIRST so the guard doesn't silently
    /// no-op on the live sender.
    @discardableResult
    public func rebindSender(_ sender: RTCRtpSender) -> Bool {
        lock.lock()
        senderCryptor?.enabled = false
        senderCryptor = nil
        lock.unlock()
        return attachSender(sender)
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

// MARK: - W-KFFAST state callback

/// VERIFICATION GAP (no Swift toolchain / no local `WebRTC.xcframework`
/// header on this box — the framework is a remote binaryTarget, see
/// `QAudionEngine/Package.swift`): `RTCFrameCryptorDelegate` and the
/// `RTCFrameCryptionState` case names below are asserted from the public
/// webrtc-sdk/LiveKit-fork ObjC SDK this vendored build is patched from
/// (`webrtc-sdk/webrtc.git@m144_release`, commit `df1011be` — the SAME
/// upstream commit the Android AES256 patch is built against, per
/// `Package.swift`'s binaryTarget comment) — NOT grep-verified against the
/// actual header. Unlike a guessed `RTCPeerConnectionDelegate` override
/// (see `QAudionWebRtcCallController.resolveAndApplyRouteTier`'s doc for
/// why that one was deliberately avoided), a WRONG protocol requirement
/// here fails LOUDLY: `RTCFrameCryptor` is created via the SAME
/// `RTCFrameCryptor(factory:rtpReceiver:...)` initializer this file
/// already uses successfully (proven call site above), so if
/// `RTCFrameCryptorDelegate`/`RTCFrameCryptionState` did not exist under
/// these exact names the file would already fail to compile at `c.delegate
/// = self` in `attachReceiver` — a compile error, not a silent no-op.
/// First real Xcode build must still confirm this compiles; report to
/// orchestrator either way.
extension NativeVideoFrameCryptor: RTCFrameCryptorDelegate {
    public func frameCryptor(_ frameCryptor: RTCFrameCryptor,
                             didStateChangeWithParticipantId participantId: String,
                             with state: RTCFrameCryptionState) {
        switch state {
        case .decryptionFailed, .missingKey, .internalError:
            print("[NativeVideoFrameCryptor] W-KFFAST: receiver cryptor state=\(state.rawValue) participantId=\(participantId) — requesting peer keyframe")
            onDecryptFailure?()
        default:
            break
        }
    }
}
#endif

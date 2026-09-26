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

    /// W-NATIVESRTPDIAG (this task) — fired for EVERY native FrameCryptor
    /// state transition on EITHER cryptor (sender AND receiver, unlike
    /// ``onDecryptFailure`` above which only ever meant the receiver), rate-
    /// limited (see ``recordStateChangeForLogging(role:state:)``). The
    /// engine has no call id and cannot reach `RTLog` directly (same reason
    /// ``QAudionPeerConnection/onAudioDcWedgeChange`` exists) — the app
    /// layer owns the log line. Argument is a ready-to-ship, pre-formatted
    /// string: `"audiosrtp cryptor role=<tx|rx> state=<name>"`.
    public var onFrameCryptorStateChange: ((String) -> Void)?

    /// W-NATIVESRTPDIAG — rate limiter backing ``onFrameCryptorStateChange``.
    /// See ``FrameCryptorStateChangeLogGate``'s own doc for the pure logic;
    /// guarded by ``lock`` here (the delegate callback's thread is
    /// undocumented beyond "the thread WebRTC calls back on", same caveat
    /// as every other cryptor callback in this file).
    private var stateChangeLogGate = FrameCryptorStateChangeLogGate()

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

    /// Install [key] into the decode ring at [slot] — this ALONE is what
    /// lets this device decode a peer's frames already tagged with this
    /// slot/epoch (the receiver is driven entirely by the on-wire key
    /// index, never by this device's own sender state). Callable
    /// immediately upon deriving the key; does NOT touch this device's own
    /// outbound frames (see `switchSender`). Safe to call before OR after
    /// the cryptors are attached. Returns `false` if the key is the wrong
    /// size (nothing installed).
    public func installKey(_ key: Data, slot: Int32) -> Bool {
        guard key.count == 32 else {
            print("[NativeAudioFrameCryptor] installKey ignored — key is \(key.count) bytes, expected 32")
            return false
        }
        lock.lock(); defer { lock.unlock() }
        currentKeyIndex = Int(slot)
        keyProvider.setSharedKey(key, with: slot)
        hasKey = true
        print("[NativeAudioFrameCryptor] key installed at slot \(slot)")
        return true
    }

    /// Switch THIS device's own outbound audio frames to announce [slot]
    /// (the slot `installKey` just installed). Call this only once the
    /// caller has decided it is safe to switch (see `RekeySwitchGate`) —
    /// this function itself has no timing/coordination logic.
    public func switchSender(slot: Int32) {
        lock.lock(); defer { lock.unlock() }
        currentSenderKeyIndex = Int(slot)
        senderCryptor?.keyIndex = slot
        print("[NativeAudioFrameCryptor] sender switched to slot \(slot)")
    }

    // W-KEYSLOTROTATE (2026-08-30) — Android rotates the FrameCryptor key
    // RING with each rekey: the new key lands at slot = epoch % 16, outbound
    // frames are TAGGED with that slot, and the previous slots stay in the
    // ring as the decrypt grace window ("prev slot kept for grace"). iOS
    // pinned everything to slot 0: setKey overwrote index 0 and the sender
    // kept keyIndex 0, so from the FIRST mid-call rekey both directions
    // died at once — the peer's slot-N-tagged frames found an empty slot N
    // here, and our slot-0-tagged frames hit the peer's RETIRED epoch-0 key
    // (live: call c8416eab, 2026-08-30 — flawless RTP flow at 16.6 pkt/s
    // for 20 minutes, audio silent from rekey epoch 1 at 20:22 on).
    // The slot is EXPLICIT (not inferred by counting distinct keys): the
    // first cut counted keys, and the TRANSITIONAL SAS key that precedes
    // the real ML-KEM key on iOS poisoned the count — the real key landed
    // at slot 1 while Android held it at slot 0, killing epoch 0 outright
    // (live: 2026-08-30 21:16, S26 logging `key_index[1] out of range`).
    // The epoch now flows from AppState's sasReady accounting, which is the
    // one place that can tell transitional / real / rekey apart.
    private var currentKeyIndex: Int = 0

    /// W-GATEBYPASS (2026-09-04) — see NativeVideoFrameCryptor's identical
    /// field for the full rationale: the slot `switchSender` last ACTUALLY
    /// announced, distinct from `currentKeyIndex` (last INSTALLED). Seeding
    /// a freshly (re)created sender cryptor from this instead of
    /// `currentKeyIndex` avoids bypassing a pending RekeySwitchGate window.
    private var currentSenderKeyIndex: Int = 0

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
        c.keyIndex = Int32(currentSenderKeyIndex)  // W-KEYSLOTROTATE / W-GATEBYPASS
        c.enabled = true
        // W-NATIVESRTPDIAG (this task) — was never wired on the SENDER side
        // before (only `attachReceiver` below set `c.delegate = self`), so
        // an encrypt-side failure or state transition was invisible even to
        // `print()`. Same delegate object handles both; the callback tells
        // sender and receiver apart by identity (see the extension below).
        c.delegate = self
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
    /// W-NATIVESRTPDIAG (this task) — now fires ``onFrameCryptorStateChange``
    /// for EVERY transition on EITHER cryptor (rate-limited), in addition to
    /// the pre-existing ``onDecryptFailure`` behavior, which is UNCHANGED:
    /// still receiver-only, still only the three failure states. Role
    /// ("tx"/"rx") is resolved by identity against ``senderCryptor``/
    /// ``receiverCryptor`` under ``lock`` — cheap, and correct even though
    /// both cryptors share this one delegate object.
    public func frameCryptor(_ frameCryptor: RTCFrameCryptor,
                             didStateChangeWithParticipantId participantId: String,
                             with state: RTCFrameCryptorState) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        lock.lock()
        let role: String
        if frameCryptor === senderCryptor {
            role = "tx"
        } else if frameCryptor === receiverCryptor {
            role = "rx"
        } else {
            // Should not happen (a cryptor not tracked by this instance
            // somehow has this instance as its delegate) — fail open with a
            // label that still shows up distinctly in the shipped log
            // rather than silently mislabeling it "tx" or "rx".
            role = "unk"
        }
        let shouldLog = stateChangeLogGate.shouldLog(role: role, stateRawValue: state.rawValue, nowMs: nowMs)
        lock.unlock()

        if shouldLog {
            onFrameCryptorStateChange?("audiosrtp cryptor role=\(role) state=\(Self.stateLabel(state))")
        }
        switch state {
        case .decryptionFailed, .missingKey, .internalError:
            print("[NativeAudioFrameCryptor] \(role) cryptor state=\(state.rawValue) participantId=\(participantId)")
            // Unchanged semantics: only the RECEIVER side drives the
            // pre-existing rekey-skew signal (audio has no keyframe request
            // to make on a sender-side failure the way video does).
            if role == "rx" {
                onDecryptFailure?()
            }
        default:
            break
        }
    }

    /// Short, log-friendly names for `RTCFrameCryptorState`. VERIFICATION
    /// GAP (same caveat as `NativeVideoFrameCryptor`'s own — no local
    /// `WebRTC.xcframework` header on this box): `.decryptionFailed`,
    /// `.missingKey`, `.internalError` are already proven to compile in this
    /// exact file (pre-existing `switch` above). `.new`, `.ok`,
    /// `.encryptionFailed`, `.keyRingRequestFailed` are NOT previously used
    /// anywhere in this codebase — asserted from the public webrtc-sdk
    /// ObjC SDK's `RTCFrameCryptorState` (mirrors the C++
    /// `FrameCryptorTransformer::FrameCryptionState` enum
    /// `kNew/kOk/kEncryptionFailed/kDecryptionFailed/kMissingKey/
    /// kKeyRingRequestFailed/kInternalError` this pinned build is patched
    /// from), not grep-verified against the actual header. A wrong case name
    /// here fails LOUDLY (a compile error), not silently.
    /// Short, all-lowercase codes rather than the full CamelCase enum-case
    /// names: this string reaches `RTLog`/the remote log shipper
    /// (`scripts/ship-ios-logs.py`), whose vocabulary gate caps how many
    /// words per line it does not already recognize
    /// (`MAX_UNKNOWN_WORDS`) — see this task's own report for the exact
    /// tokens added to `APP_VOCAB` for these.
    private static func stateLabel(_ state: RTCFrameCryptorState) -> String {
        switch state {
        case .new: return "new"
        case .ok: return "ok"
        case .encryptionFailed: return "encfail"
        case .decryptionFailed: return "decfail"
        case .missingKey: return "misskey"
        case .keyRingRequestFailed: return "ringfail"
        case .internalError: return "interr"
        @unknown default: return "unk\(state.rawValue)"
        }
    }
}
#endif

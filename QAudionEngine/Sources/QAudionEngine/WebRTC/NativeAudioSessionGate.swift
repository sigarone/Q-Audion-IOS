import AVFoundation
import Foundation
import WebRTC

/// W-ADMMANUAL (2026-08-30) — explicit lifecycle control of WebRTC's own
/// audio unit (VoiceProcessingIO) for native-audio-srtp calls.
///
/// Root cause this exists for, measured on TestFlight 1.0.1052 with the
/// W-SRTPRXDIAG heartbeat: a caller-side srtp call had its mic track wired
/// into the negotiated m-line (`act=1 n=1 dir=0`, outbound-rtp row present)
/// and STILL sent zero packets forever (`tx=0 ptx=0`), while inbound RTP
/// arrived at stats level (`rx` growing) but nothing ever played. Capture
/// dead AND playout dead together means WebRTC's audio device module never
/// ran. In a CallKit app that is the canonical automatic-mode failure: the
/// SDK tries to start its audio unit the moment the transport goes live,
/// which is BEFORE CallKit activates the shared `AVAudioSession` — the start
/// fails, and the SDK does not retry when `didActivate` finally lands.
/// (This app's legacy sealed-DataChannel voice path never noticed, because
/// it does its own capture/playout with `AVAudioEngine` and the WebRTC audio
/// unit was never needed until native srtp audio existed.)
///
/// The documented contract for CallKit apps is manual mode:
/// `RTCAudioSession.useManualAudio = true` makes the SDK keep its audio unit
/// OFF until the app flips `isAudioEnabled = true`, and with manual mode on
/// the SDK also stops configuring/activating the AVAudioSession itself — the
/// app's existing `.voiceChat` configuration and earpiece-route policy stay
/// the sole owner of the session, exactly as they are today.
///
/// Scoping: everything here is gated on the audio-srtp kill switch, and
/// `setNativeAudioActive(true)` is only ever called from the one CallService
/// chokepoint that already decides "native WebRTC owns this call's audio"
/// (the gate=4 branch of `startAudioIOIfReady`), which runs strictly after
/// CallKit's `didActivate` (gate=2) and after the peer answered (gate=3).
/// Legacy DataChannel calls never enable it, so their behavior is
/// byte-for-byte unchanged. Group calls run on LiveKit's own fork of the
/// SDK (`LKRTCAudioSession`, a distinct class with a distinct shared
/// instance — see Package.swift's symbol-namespace note), so arming manual
/// mode on the direct-call SDK's session cannot affect them.
public enum NativeAudioSessionGate {

    /// W-ADMASYNC (2026-08-30) — every RTCAudioSession touch goes through
    /// this ONE serial background queue, asynchronously. Evidence: on live
    /// call fceeb84f BOTH paths that enter this gate stalled at exactly
    /// their first gate call — handleAudioSessionActivated never reached
    /// startAudioIOIfReady (zero gate= lines all call), and
    /// engageAudioSrtpFallback logged engage=1 and then nothing — the
    /// classic shape of a lock-order deadlock inside RTCAudioSession's own
    /// locking against WebRTC's audio/signaling threads. It also froze the
    /// call UI at ring time (main thread parked in the gate). Async on a
    /// serial queue keeps the relay->enable ordering (callers enqueue in
    /// order) while making it impossible for ANY app thread to block here.
    private static let gateQueue = DispatchQueue(label: "com.bcrypto.qaudion.admgate", qos: .userInitiated)

    /// Arm manual-audio mode. Idempotent; called from
    /// `QAudionPeerConnection.init` so it is guaranteed to run before the
    /// first srtp-capable transport ever starts. No-op when the audio-srtp
    /// kill switch is off — automatic mode (today's behavior) stays.
    public static func armManualMode() {
        guard CallCapabilities.audioSrtpSendEnabled else { return }
        gateQueue.async {
            let session = RTCAudioSession.sharedInstance()
            guard !session.useManualAudio else { return }
            session.useManualAudio = true
            session.isAudioEnabled = false
            print("[WebRTC] W-ADMMANUAL: manual audio armed (WebRTC audio unit gated on isAudioEnabled)")
        }
    }

    /// W-ADMACTIVATE (2026-08-30) — the HALF of the manual-audio contract
    /// the first W-ADMMANUAL cut missed, and the cause of the 1.0.1053/4
    /// regression where `isAudioEnabled = true` alone left the unit dead
    /// (`hb tx=0` with ICE connected, inbound counted but silent — calls
    /// bae3d5b4/f999b973). Verbatim from this build's own
    /// RTCAudioSession.h: `RTCAudioSessionActivationDelegate` exists "to
    /// inform RTCAudioSession when the audio session activation state has
    /// changed OUTSIDE of RTCAudioSession. The current known use case of
    /// this is when CallKit activates the audio session for the
    /// application" — and `isAudioEnabled` only starts the unit "when it
    /// is needed", a decision keyed on the session-active bookkeeping that
    /// ONLY these delegate calls update once manual mode is armed. Wired
    /// from CallService's `handleAudioSessionActivated` /
    /// `handleAudioSessionDeactivated` (the CallKit didActivate /
    /// didDeactivate funnels, self-activation fallback included).
    public static func handleCallKitActivation(_ active: Bool) {
        guard CallCapabilities.audioSrtpSendEnabled else { return }
        gateQueue.async {
            let session = RTCAudioSession.sharedInstance()
            guard session.useManualAudio else { return }
            if active {
                session.audioSessionDidActivate(AVAudioSession.sharedInstance())
                applyVoipSessionConfigurationLocked()  // W-SESSIONLOCK
            } else {
                session.audioSessionDidDeactivate(AVAudioSession.sharedInstance())
            }
            print("[WebRTC] W-ADMACTIVATE: session activation relayed active=\(active)")
        }
    }

    /// W-SESSIONLOCK (2026-08-30) — apply the VoIP session configuration
    /// THROUGH `RTCAudioSession`, under its own lock, instead of poking
    /// `AVAudioSession.sharedInstance()` directly.
    ///
    /// This is the contract this build's own RTCAudioSession.h states in
    /// one line: it is a "Proxy class for AVAudioSession that adds a
    /// locking mechanism ... so that interleaving configurations between
    /// WebRTC and the application layer are avoided", and "Callers should
    /// not call setters on AVAudioSession directly". The app has always
    /// violated it (AudioProcessingPipeline.configureForVoIP), which was
    /// harmless while WebRTC owned no audio here — until manual-audio mode
    /// made the two layers configure the same session in earnest.
    ///
    /// Measured consequence (live call, 1.0.1063, 22:57): the app asked for
    /// `.playAndRecord` + `.voiceChat` + 5 ms buffers, and the session that
    /// actually ran had `in=` EMPTY (no input in the route at all),
    /// `out=Speaker` instead of the earpiece and `buf=0.02` — the app's
    /// configuration was simply not the one in force. With no input in the
    /// route BOTH capture engines are silent by construction: WebRTC's VPIO
    /// unit produced `tx=0 ptx=0` all call, and the AVAudioEngine fallback
    /// threw on `start()` (`audioIO capfail=1`). One cause, both symptoms.
    ///
    /// Applied right before the audio unit is enabled (and re-applied on
    /// every CallKit activation, since the route can change with it), on
    /// the same serial queue as every other gate operation.
    private static func applyVoipSessionConfigurationLocked() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        #if os(iOS) && !targetEnvironment(simulator)
        let opts: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .interruptSpokenAudioAndMixWithOthers]
        #else
        let opts: AVAudioSession.CategoryOptions = [.interruptSpokenAudioAndMixWithOthers]
        #endif
        do {
            // Same category/mode/options AudioProcessingPipeline asks for —
            // deliberately duplicated rather than shared, because this must
            // run inside the lock and that type has no WebRTC dependency.
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: opts)
            try session.setPreferredSampleRate(48_000)
            try session.setPreferredIOBufferDuration(0.005)
            // Do NOT setActive here: under CallKit the system activates the
            // session and `handleCallKitActivation` relays that fact. An app
            // -side activation would fight it.
            print("[WebRTC] W-SESSIONLOCK: VoIP session configuration applied under lock")
        } catch {
            print("[WebRTC] W-SESSIONLOCK: configuration failed — \(error.localizedDescription)")
        }
    }

    /// Start (`true`) or stop (`false`) WebRTC's audio unit. Safe to call
    /// redundantly. The `true` edge must only ever fire while CallKit's
    /// audio session is active — the CallService chokepoint guarantees it.
    public static func setNativeAudioActive(_ active: Bool) {
        guard CallCapabilities.audioSrtpSendEnabled else { return }
        gateQueue.async {
            let session = RTCAudioSession.sharedInstance()
            guard session.useManualAudio else { return }
            guard session.isAudioEnabled != active else { return }
            if active { applyVoipSessionConfigurationLocked() }  // W-SESSIONLOCK
            session.isAudioEnabled = active
            print("[WebRTC] W-ADMMANUAL: native audio unit \(active ? "enabled" : "disabled")")
        }
    }
}

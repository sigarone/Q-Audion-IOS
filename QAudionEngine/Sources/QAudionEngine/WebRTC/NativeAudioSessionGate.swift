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
/// OFF until the app flips `isAudioEnabled = true`. Note (corrected
/// 2026-08-30): manual mode gates only whether the audio UNIT may start — the
/// SDK still configures the AVAudioSession once the unit comes up, so the app
/// is NOT the sole owner of the session while a native call runs. An earlier
/// version of this comment claimed otherwise and that claim was wrong.
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

    // W-ADMACTIVATE was here and is deliberately GONE (2026-08-30). See
    // CallService.handleAudioSessionActivated for the two-call proof that
    // relaying CallKit's activation into RTCAudioSession is what stopped the
    // microphone. Do not reintroduce it without live evidence that capture
    // survives it: `audiosrtp hb=1` must show ptx climbing, not tx=0.

    /// Start (`true`) or stop (`false`) WebRTC's audio unit. Safe to call
    /// redundantly. The `true` edge must only ever fire while CallKit's
    /// audio session is active — the CallService chokepoint guarantees it.
    public static func setNativeAudioActive(_ active: Bool) {
        guard CallCapabilities.audioSrtpSendEnabled else { return }
        gateQueue.async {
            let session = RTCAudioSession.sharedInstance()
            guard session.useManualAudio else { return }
            guard session.isAudioEnabled != active else { return }
            session.isAudioEnabled = active
            print("[WebRTC] W-ADMMANUAL: native audio unit \(active ? "enabled" : "disabled")")
        }
    }
}

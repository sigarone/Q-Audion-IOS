import Foundation

/// IOS-C4b / W-SRTPFALLBACK (2026-08-26) — pure decision logic for the
/// native-audio-srtp TX fallback gate, ported from Android's
/// `SrtpFallbackTxGate.shouldStartSrtpFallbackTx` (`CallAudioBridge.kt`).
///
/// ## What this is fencing
///
/// On a call that negotiated ``CallCapabilities/audioSrtpV1``, the native
/// RTP audio track dies with ICE. iOS's manual AVAudioEngine capture
/// (`CallService.startAudioIOIfReady`) is bypassed for the whole call while
/// native audio owns TX/RX (see `CallService`'s own bypass gate) — so an ICE
/// outage on a native-srtp call needs to RE-ENGAGE that manual capture path
/// to keep sending audio over the sealed DataChannel/WS relay, or the call
/// goes one-way silent for as long as ICE stays down.
///
/// Re-engaging capture opens a SECOND audio path next to WebRTC's own ADM —
/// exactly the resource contention the audio-srtp branch exists to avoid —
/// so, mirroring Android's own reasoning, the start edge is fenced: ICE must
/// have stayed bad for the FULL debounce window, must STILL be bad when the
/// debounce expires (a sub-second ICE blip must engage nothing), and the
/// fallback is never engaged twice concurrently. The stop edge (recovery) is
/// deliberately ungated — prompt teardown at ICE recovery bounds the
/// double-audio window, same as Android's TX gate.
///
/// RX needs no fallback of its own: iOS's WS `audio_frame` handler and the
/// DataChannel handler both stay attached for the whole call regardless of
/// which leg is active (`CallService.swift` — "the two receive paths
/// converge... by design... and that must not change", cited in
/// `CallCapabilities.dcMuxAdvertiseEnabled`'s own doc) — if the ANDROID peer
/// also falls back and starts sending sealed frames, iOS's RX path picks
/// them up without any new code.
///
/// Pure — no WebRTC / PeerConnection / Date state — so the exact numbers and
/// branches can be pinned by unit tests without a live call, same discipline
/// as `RestartIceDecisions` / `GlareDecisions` in this directory.
public enum SrtpFallbackDecisions {

    /// Debounce before a bad ICE state on a native-audio-srtp call re-opens
    /// the manual capture path. Mirrors Android
    /// `CallAudioBridge.SRTP_FALLBACK_TX_DEBOUNCE_MS` — "the agreed contract
    /// is >= 1 s of continuous degradation before a second AudioRecord/
    /// AVAudioEngine capture path."
    public static let fallbackEngageDebounceMs: Int64 = 1_000

    /// Decide whether to (re-)engage the manual capture/decode fallback.
    ///
    /// - Parameters:
    ///   - usingNativeAudioSrtp: this call negotiated `audioSrtpV1` and the
    ///     native path is the one actually carrying audio. `false` (a
    ///     DataChannel/WS-relay call) makes this always `false` — that call
    ///     never bypassed the manual path in the first place.
    ///   - iceBad: current ICE connection state is `.failed`/`.disconnected`
    ///     (mirrors `QAudionWebRtcCallController.isIceStateBad`).
    ///   - iceBadSinceMs: monotonic timestamp the CURRENT bad-ICE streak
    ///     started, or `nil` if ICE is not currently bad (or was never
    ///     observed bad this call).
    ///   - nowMs: monotonic "now".
    ///   - fallbackAlreadyEngaged: the manual capture path is already
    ///     running from an EARLIER engage — never double-start it.
    public static func shouldEngageFallback(
        usingNativeAudioSrtp: Bool,
        iceBad: Bool,
        iceBadSinceMs: Int64?,
        nowMs: Int64,
        debounceMs: Int64 = fallbackEngageDebounceMs,
        fallbackAlreadyEngaged: Bool
    ) -> Bool {
        guard usingNativeAudioSrtp, iceBad, !fallbackAlreadyEngaged else { return false }
        guard let since = iceBadSinceMs else { return false }
        return nowMs - since >= debounceMs
    }

    /// Decide whether to tear down an engaged fallback. Deliberately
    /// ungated (no debounce) — the moment ICE recovers, the native path is
    /// carrying audio again and the second capture path must stop promptly
    /// to bound the double-audio window, mirroring Android's stop-edge
    /// reasoning verbatim.
    /// W-SRTPFALLBACKRETRY (2026-08-30) — whether the engage-evaluation
    /// loop should run another round after a round that did not engage.
    /// True while the bad-ICE streak is officially alive (the controller's
    /// `iceBadSinceMs` is set; only genuine recovery clears it) and the
    /// fallback has not engaged yet. The one-shot this replaces evaluated
    /// once per outage: a `.checking` reading at the 1 s mark — common,
    /// because the recovery watchdog fires `restartIce` on the same edge —
    /// consumed the only attempt and left the entire outage without the
    /// fallback TX.
    public static func shouldKeepWaitingToEngage(
        streakAlive: Bool,
        fallbackAlreadyEngaged: Bool
    ) -> Bool {
        streakAlive && !fallbackAlreadyEngaged
    }

    public static func shouldRecoverFromFallback(
        fallbackEngaged: Bool,
        iceBad: Bool
    ) -> Bool {
        fallbackEngaged && !iceBad
    }
}

/// W-CAPTURELIVE-SIGNAL (2026-09-08) — pure decisions for the native-mic
/// liveness check (`QAudionWebRtcCallController.verifyNativeAudioCaptureLiveOrRecover`).
///
/// ## Why the signal changed
///
/// W-CAPTURELIVE (2026-09-07) declared the native mic "live" only when the
/// `NativeAudioPcmTap` registered on the LOCAL mic track had delivered a
/// frame. In the pinned WebRTC build that renderer is never fed for a local
/// track (`LocalAudioSource::AddSink` is an empty override upstream; the
/// LiveKit SDK routes local renderers through the ADM's capture-post-
/// processing hook instead, never through the track sink). Live corpus
/// 2026-09-08, six devices / ~24 calls: 24 × `capturelive=0 … fallback=1`,
/// zero `capturelive=1`, while the same legs' `outbound-rtp.packetsSent`
/// was growing — the sender WAS moving audio and the watchdog muted it and
/// re-engaged the manual capture path on every call anyway.
///
/// The replacement signal is the one already trusted everywhere else in this
/// stack (W-DEADTXNET, W-SRTPRXDIAG): `outbound-rtp.packetsSent` growing
/// after the check was armed. libwebrtc only emits audio send packets when the
/// ADM delivers recorded frames to the send stream, and a disabled track
/// stops them — ptx freezing exactly at every `audiosrtpfb engage=1` mute in
/// the same corpus is the counter proving the same counter.
///
/// ## Why the gate exists
///
/// On the callee the media path is negotiated at OFFER receipt, seconds before
/// the user taps Answer in CallKit and the AVAudioSession is activated; on the
/// caller the session is active from dial time but the peer has not answered.
/// Before both "session active" and "peer answered" hold there is nothing to
/// judge — a check that runs earlier can only false-negative (same rule the
/// W-DEADTXNET sentinel already applies).
///
/// Pure — no WebRTC / Date state — so the numbers and branches are pinned by
/// unit tests (`CaptureLiveDecisionsTests`).
public enum CaptureLiveDecisions {

    /// How often the check re-asks whether the gate has opened.
    public static let gatePollIntervalMs: Int64 = 250
    /// Give-up ceiling for the gate wait (a call ringing this long has other
    /// watchdogs). Logged as `audiosrtp caplive=9 wait=N` when hit.
    public static let gateWaitCapMs: Int64 = 120_000
    /// Sampling interval for the packet-growth window.
    public static let growthPollIntervalMs: Int64 = 500
    /// Window after the gate opens in which packet growth (or the tap) must
    /// prove the mic live before the nudge (was a single sample at 1.5 s; the
    /// stats poll is 1 Hz and its readout trails by up to a tick).
    public static let growthWindowMs: Int64 = 3_000
    /// Window after the mute/unmute nudge before escalating to the fallback.
    public static let afterNudgeWindowMs: Int64 = 1_500

    /// The check may start judging only once CallKit has activated the audio
    /// session AND the peer has answered.
    public static func gateOpen(audioSessionActive: Bool, peerAnswered: Bool) -> Bool {
        audioSessionActive && peerAnswered
    }

    /// `outbound-rtp.packetsSent` proves capture when it is positive and has
    /// grown since the check was armed. `-1` = no outbound row yet (never
    /// live); a frozen non-zero count (`now == atArm`) is NOT live — that is
    /// the dead-sender shape W-DEADTXNET exists for.
    public static func packetsProveLive(packetsAtArm: Int64, packetsNow: Int64) -> Bool {
        packetsNow > 0 && packetsNow > packetsAtArm
    }
}

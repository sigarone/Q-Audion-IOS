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
    public static func shouldRecoverFromFallback(
        fallbackEngaged: Bool,
        iceBad: Bool
    ) -> Bool {
        fallbackEngaged && !iceBad
    }
}

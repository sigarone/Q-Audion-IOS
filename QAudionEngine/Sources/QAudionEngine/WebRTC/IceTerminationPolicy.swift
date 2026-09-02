import Foundation

/// W-ICEGRACE (2026-07-21) — what a WebRTC ICE/connection-state edge should do
/// to a live 1:1 call.
public enum IceTerminationAction: Equatable, Sendable {
    /// No call to tear down (already idle/ended) — ignore the edge.
    case none
    /// Terminal ICE state (`.failed` / `.closed`): the transport is gone for
    /// good, end the call now.
    case endImmediately
    /// Recoverable ICE state (`.disconnected`): give the connection a grace
    /// window to heal itself before ending anything.
    case endAfterGrace
    /// W-ICEGRACEDEGRADE (2026-09-01) — ICE is gone (the grace ran out, or
    /// ICE reported `.failed`) but a relay leg exists for this call: keep the
    /// call, mark the transport degraded, leave the per-frame relay routing
    /// and the ICE-restart machine exactly as they are. From here only the
    /// W-MEDIADEAD inbound-audio backstop (90 s, real decodes) may end the
    /// call — the same contract Android has always had.
    case degradeToRelay
}

/// W-ICEGRACEDEGRADE (2026-09-01) — compile-time switch + the two pure
/// decisions that were missing from this policy: what happens when the
/// grace RUNS OUT, and whether an ICE `.failed` is really the end of the call.
///
/// Evidence (audit memory reference_ios_stability_audit_2026_09_01, P1 item
/// 10): at grace expiry iOS called `endCall()` — base 10 s
/// (AppState.swift:14007-14019) and extended 50 s (:14056-14067) — although
/// during that same grace the audio was ALREADY riding the WS relay
/// per-frame (W-DCTXICEGATE, controller `sendAudioFrameData`; audio-srtp
/// calls via the W-SRTPFALLBACK engage). Android in the same state
/// downgrades to the WS relay (`downgradeToWsRelay("disconnected-after-grace")`,
/// and `"FAILED"` on the terminal edge), keeps the ICE-restart loop running
/// and only ends the call from its media-dead watchdog; Desktop swaps to the
/// WS relay in place at grace expiry since 2026-09-01. iOS was the one
/// platform that hung up on a working relay leg.
///
/// Why ICE `.failed` is part of this and not only the grace timer: the
/// controller arms its restart watchdog on `.failed` as well as
/// `.disconnected` (QAudionWebRtcCallController `didChangeIceConnectionState`
/// — same branch, `armIceRecoveryWatchdogIfNeeded`), so `.failed` is a
/// restartable state there; but AppState ended the call on it immediately.
/// In practice a restart that cannot converge reaches `.failed` well inside
/// the 50 s extended grace, so a grace-only fix would have been decorative.
/// `.closed` (our own teardown) and a DTLS/connection failure (no restart
/// can heal it) stay terminal.
///
/// The relay question is asked when the grace RUNS OUT
/// (`graceExpiryAction`), not when it is armed: the relay's own signalling
/// socket reconnects during the very handoff that broke ICE, so the answer
/// at t=0 is the wrong one to act on at t=10 s. Whether the socket is up at
/// that instant is deliberately NOT an input — an established call is never
/// ended by a client timer; the relay's reconnect plus W-MEDIADEAD (which
/// sits above the server's 60 s disconnect-grace ceiling) bound the outcome.
///
/// Pure (no WebRTC / AppState types) so both branches are pinned by
/// `IceTerminationPolicyTests` on the CI simulator lane.
public enum IceTerminationPolicy {

    /// Kill switch. `true` = an established call with a relay leg degrades
    /// (stays up on the relay, chip RELAY) instead of ending when ICE gives
    /// up. `false` = the pre-2026-09-01 behaviour, byte for byte: every
    /// grace expiry and every ICE `.failed` ends the call. Rollback is this
    /// line; nothing else needs to change (every decision below takes the
    /// switch as a defaulted argument so tests pin BOTH branches).
    public static let iceGraceDegradesToRelay: Bool = true

    /// "A relay leg exists for this call" — the precondition for every
    /// `.degradeToRelay` outcome.
    ///
    /// - `callEstablished`: the call is `.active`/`.encrypted`. A call still
    ///   in setup (`.connecting`/`.ringing`) keeps the F-1 rule — ICE dying
    ///   there ends it, because the W-MEDIADEAD backstop only measures
    ///   CONNECTED silence and a degraded setup would wedge the call UI
    ///   forever.
    /// - `relayLegBound`: CallService has somewhere to send relay frames
    ///   (a backend provider and a peer id) — the same two things its TX
    ///   path needs to route a frame to the WS relay at all.
    public static func relayPathAvailable(callEstablished: Bool, relayLegBound: Bool) -> Bool {
        callEstablished && relayLegBound
    }

    /// What to do when a grace armed by `.endAfterGrace` (base or extended)
    /// runs out with ICE still down.
    public static func graceExpiryAction(
        callIsLive: Bool,
        relayPathAvailable: Bool,
        degradeEnabled: Bool = IceTerminationPolicy.iceGraceDegradesToRelay
    ) -> IceTerminationAction {
        guard callIsLive else { return .none }
        return (degradeEnabled && relayPathAvailable) ? .degradeToRelay : .endImmediately
    }
}

/// W-ICEGRACE — pure decision behind `AppState.handleIceTermination`.
///
/// ICE `.disconnected` is explicitly a RECOVERABLE state in the WebRTC spec —
/// it routinely self-heals within a second or two across a WiFi/cellular
/// hiccup. Only `.failed` and `.closed` are terminal. iOS nevertheless called
/// `endCall()` on the very first `.disconnected` edge, with zero grace, while
/// Android has always armed a 3000 ms window (`DISCONNECT_GRACE_MS`,
/// `CallTransportFactory.kt:821`) and fallen back to the WS relay instead of
/// hanging up.
///
/// Device-verified asymmetry, call f884668c (2026-07-21, iOS↔Android 1:1
/// audio): iOS ended the call at 21.9s (`call.media.summary`
/// end_reason=user_hangup, mic tx frozen at 970 frames) ~0.3s after Android
/// logged "ICE DISCONNECTED — arming 3000ms grace" for the SAME call; Android
/// rode it out and reports duration_ms=85098 for its own leg. Same wire event,
/// opposite behavior — a pure platform-parity gap, live since 2026-05-18.
///
/// Extracted top-level (no WebRTC/AppState types) so this contract has its own
/// regression test, same shape as `VideoTransceiverPhantomGuard` and
/// `AudioDcBackpressureGate`. If the grace ever needs to change, change it here
/// AND in Android's `DISCONNECT_GRACE_MS` together — the two are a protocol
/// pair, not two independent tunables.
///
/// W-ICEGRACEDEGRADE (2026-09-01) — two defaulted inputs, both `false` for
/// every pre-existing caller so the original contract is untouched:
///   - `iceRestartable`: the terminal edge is ICE `.failed` (the controller
///     keeps restarting ICE on it), not `.closed` / a DTLS failure.
///   - `relayPathAvailable`: `IceTerminationPolicy.relayPathAvailable`.
/// A terminal-but-restartable edge with a relay leg degrades instead of
/// ending. A non-terminal edge still arms the grace regardless of the relay
/// — the relay question belongs to `graceExpiryAction`, see its doc.
public func iceTerminationAction(
    callIsLive: Bool,
    iceIsTerminal: Bool,
    iceRestartable: Bool = false,
    relayPathAvailable: Bool = false,
    degradeEnabled: Bool = IceTerminationPolicy.iceGraceDegradesToRelay
) -> IceTerminationAction {
    guard callIsLive else { return .none }
    if iceIsTerminal {
        if degradeEnabled && iceRestartable && relayPathAvailable {
            return .degradeToRelay
        }
        return .endImmediately
    }
    return .endAfterGrace
}

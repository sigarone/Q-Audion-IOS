import Foundation

/// WIRE_SPEC §8.7 — pure constants + predicates for the VIDEODIAG
/// self-heal watchdog. No WebRTC / PeerConnection state so the
/// `readiness-8.7` group of `tools/kat/upgrade-flow/upgrade-flow-kat.json`
/// can gate the exact same rules the app runs (see `UpgradeFlowKatTests`).
///
/// Cross-platform sisters: Desktop `upgradeStateMachine.ts`
/// (RECEIVER_GATE_FAILSAFE_MS / STALL_ESCALATION_BACKOFF_MS /
/// STALL_ESCALATION_LADDER / stallEscalationDue) and the Android
/// `UpgradeFlowKatTest.kt` model — same values, same `>=` boundary
/// semantics on every window.
///
/// SIGNAL-NOT-KILL: the watchdog NEVER drops or tears down a call and
/// never blocks media — it only heals (keyframe request, sink re-attach,
/// `call_media_ready` re-announce) and logs. NEVER-BLOCK: ONE lightweight
/// 1 s-tick task per call, cancelled on hangup; stall/frame counters are
/// bumped on existing hot paths with no per-frame task spawning and
/// nothing scheduled on shared default-style pools.
public enum VideoStallSelfHeal {

    // MARK: - Receiver render-gate failsafe (§8.7)

    /// When inbound video lands before the receiver cryptor is keyed+bound,
    /// the render gate holds at most this long; on expiry the gate lifts
    /// ANYWAY (a brief garbage frame beats permanent black) and a
    /// `video_keyframe_request` goes out. Mirrors the sender's 2 s TX-hold.
    public static let receiverGateFailsafeMs: Int64 = 2000

    // MARK: - Black-video stall rule (§8.7 watchdog)

    /// Observation window for the stall rule (and the per-rule deltas).
    public static let stallWindowMs: Int64 = 3000

    /// BLACK-VIDEO STALL: remote video is expected AND transport frames
    /// arrived within the last window AND nothing rendered for >= the
    /// window. "Frames arrive but never reach the screen" — the exact
    /// signature of the recurring black/purple video bugs. No arrivals at
    /// all is NOT a stall (nothing to recover — peer stopped sending).
    public static func isBlackVideoStall(
        msSinceLastArrivedIncrease: Int64,
        msSinceLastRenderedIncrease: Int64
    ) -> Bool {
        return msSinceLastArrivedIncrease < stallWindowMs
            && msSinceLastRenderedIncrease >= stallWindowMs
    }

    /// §8.7 RECOVERY RULE — arrivals idle this long means "the peer stopped
    /// sending, no media is NOT a black-video stall".
    ///
    /// XP-viola-2026-07-10 (ported from Android `STALL_ARRIVED_IDLE_MS`,
    /// `VideoSelfHeal.kt`) — widened from `2 * stallWindowMs` (6 s). Local
    /// counters (`framesArrived` from getStats(), `framesRendered` from the
    /// renderer) cannot distinguish "peer genuinely stopped sending" from
    /// "peer is sending but our own receiver never bound to accept it" —
    /// both look identical as permanent zero-arrival-increase from this
    /// device. Since `isBlackVideoStall` fires on that second, WORSE case
    /// too, the OLD 6 s recovery threshold undid the very detection it was
    /// supposed to enable: `msSinceLastArrivedIncrease` blew past 6 s within
    /// a couple of ticks, so recovery fired almost immediately after
    /// detection, resetting the ladder back to stage 0 in a loop that never
    /// reached rung 2 (sinkReattach, due at 6 s) or rung 3
    /// (mediaReadyReannounce, due at 12 s). Set safely past the LAST rung's
    /// backoff (12 s) plus the `stallWindowMs` head start baked into when
    /// the arrived-increase clock is first stamped, so a real stall gets the
    /// full ladder before this rule can even apply. This constant was
    /// widened on Android (2026-07-10) but the port to iOS was missed until
    /// now — the AppState watchdog was still running the pre-fix 6 s value.
    public static let stallArrivedIdleMs: Int64 = 20_000

    // MARK: - TX inverse rule (peer keyframe-request storm)

    /// The peer requesting this many keyframes…
    public static let peerKeyframeStormCount: Int = 3
    /// …inside this window means its decoder is starving: force an IDR
    /// immediately (bypassing the 1/s honor limiter once).
    public static let peerKeyframeStormWindowMs: Int64 = 5000

    /// True when `requestTimesMs` (the most recent inbound
    /// `video_keyframe_request` timestamps, oldest first, capped at
    /// `peerKeyframeStormCount`) holds `peerKeyframeStormCount` entries all
    /// inside the storm window ending at `nowMs`.
    public static func isPeerKeyframeStorm(
        requestTimesMs: [Int64],
        nowMs: Int64
    ) -> Bool {
        guard requestTimesMs.count >= peerKeyframeStormCount else { return false }
        let oldest = requestTimesMs[requestTimesMs.count - peerKeyframeStormCount]
        return nowMs - oldest <= peerKeyframeStormWindowMs
    }

    // MARK: - Escalation ladder (§8.7 watchdog)

    /// Rung k is due at `stallStartMs + stallEscalationBackoffMs[k]`
    /// (3 s → 6 s → 12 s since stall DETECTION, capped — after the last
    /// rung the watchdog keeps ticking + logging but takes no further
    /// action). Reset on recovery: a fresh stall restarts from rung 0.
    public static let stallEscalationBackoffMs: [Int64] = [3000, 6000, 12000]

    /// The self-heal action of each ladder rung (index-aligned with the
    /// backoff). ZERO new wire message types: rung 0 and rung 2 reuse the
    /// EXISTING `video_keyframe_request` / `call_media_ready` messages
    /// byte-identically; rung 1 is purely local.
    public enum EscalationAction: Equatable {
        /// Send `video_keyframe_request` (existing wire message, through
        /// the shared 1/s outbound limiter; cheapest first).
        case keyframeRequest
        /// Re-attach the local render sink / renderer to the track
        /// (zero wire traffic).
        case sinkReattach
        /// Re-announce `call_media_ready` for the bound mid (same wire
        /// bytes; deliberate bypass of the normal-path once-per-(callId,
        /// mid) dedup) + force a LOCAL encoder IDR (symmetric case).
        case mediaReadyReannounce
    }

    public static let escalationLadder: [EscalationAction] = [
        .keyframeRequest,
        .sinkReattach,
        .mediaReadyReannounce,
    ]

    /// Pure rung-due predicate: is rung `stage` (0-based, the next unfired
    /// rung) due at `nowMs` for a stall that began at `stallStartMs`?
    /// Returns false once the ladder is exhausted. Desktop
    /// `stallEscalationDue` parity (`>=` boundary).
    public static func stallEscalationDue(
        stallStartMs: Int64,
        stage: Int,
        nowMs: Int64
    ) -> Bool {
        guard stage >= 0, stage < stallEscalationBackoffMs.count else { return false }
        return nowMs - stallStartMs >= stallEscalationBackoffMs[stage]
    }
}

/// Per-call mutable ladder state for the VIDEODIAG watchdog. Pure and
/// clock-agnostic (the caller supplies monotonic `nowMs`), so the
/// `readiness-8.7` KAT scenarios drive THIS object with a virtual clock —
/// the production watchdog in AppState delegates every escalation decision
/// here. NOT thread-safe by itself: the production owner calls it from one
/// isolation context (the 1 s MainActor tick), the KAT driver from the
/// test thread.
public final class VideoStallEscalationEngine {

    /// Number of rungs already fired for the CURRENT stall (0 = none).
    /// KAT `watchdogStage` maps 1:1 onto this.
    public private(set) var stage: Int = 0
    /// Monotonic ms timestamp of stall detection; -1 = not stalled.
    public private(set) var stallStartMs: Int64 = -1

    /// Audit item 2 (2026-08-26, best-practices audit) — cumulative count
    /// of each rung firing across the WHOLE call, index-aligned with
    /// `VideoStallSelfHeal.escalationLadder` (0=keyframeRequest,
    /// 1=sinkReattach, 2=mediaReadyReannounce). UNLIKE `stage`, this is
    /// NOT reset by `noteRecovered()`/a fresh `noteStalled()` — it survives
    /// across every stall-recover cycle of one call so the caller can log
    /// "how often did the ladder escalate this call" (the audit's own
    /// suggested first step towards deciding whether video FEC/LTR is
    /// justified — see `AppState.emitVideoStallEscalationTelemetry`). Reset
    /// only by `reset()` (full per-call teardown), same lifecycle as
    /// `stage`/`stallStartMs` there.
    public private(set) var totalRungFireCounts: [Int] =
        [Int](repeating: 0, count: VideoStallSelfHeal.escalationLadder.count)

    public var isStalled: Bool { return stallStartMs >= 0 }

    public init() {}

    /// Mark stall detection. Idempotent while already stalled (the tick
    /// re-evaluates the rule every second; only the FIRST detection bases
    /// the ladder clock).
    public func noteStalled(nowMs: Int64) {
        guard stallStartMs < 0 else { return }
        stallStartMs = nowMs
        stage = 0
    }

    /// Frames flow again — ladder AND backoff fully reset; the next stall
    /// starts from rung 0 with a fresh base (KAT
    /// `readiness-watchdog-recovery-resets-backoff`).
    public func noteRecovered() {
        stallStartMs = -1
        stage = 0
    }

    /// Full per-call reset (hangup / video-leg rollback). ALSO clears
    /// `totalRungFireCounts` — a fresh call must not inherit the previous
    /// call's escalation history, same "must not bleed into next call"
    /// discipline `QAudionWebRtcCallController` applies to its own per-call
    /// state (`_routeTierDwell.reset()` et al.).
    public func reset() {
        noteRecovered()
        totalRungFireCounts = [Int](repeating: 0, count: VideoStallSelfHeal.escalationLadder.count)
    }

    /// Consume every rung due at `nowMs`, IN ORDER (rungs fire in ladder
    /// order even across a large clock jump — desktop parity). Empty when
    /// not stalled or nothing is due. Bumps `totalRungFireCounts[stage]`
    /// for every rung actually fired here (audit item 2).
    public func dueActions(nowMs: Int64) -> [VideoStallSelfHeal.EscalationAction] {
        guard isStalled else { return [] }
        var fired: [VideoStallSelfHeal.EscalationAction] = []
        while stage < VideoStallSelfHeal.escalationLadder.count,
              VideoStallSelfHeal.stallEscalationDue(
                stallStartMs: stallStartMs, stage: stage, nowMs: nowMs) {
            fired.append(VideoStallSelfHeal.escalationLadder[stage])
            totalRungFireCounts[stage] += 1
            stage += 1
        }
        return fired
    }
}

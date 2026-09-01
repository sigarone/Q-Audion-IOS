import Foundation

/// W-SILENTPATHDEATH + W-OFFERGLARE + W-RESTARTOFFERPARK (2026-08-25) —
/// parity plan Fase E3. Pure decision helpers for the ICE-restart recovery
/// machine, ported from Android's real, shipped implementation
/// (`PeerConnectionHolder.restartIce` / `.handleRemoteOffer` +
/// `CallController.notifyNetworkChanged` / `.iceFailedRecoveryJob`,
/// qaudion-android-new). iOS had ZERO ICE-restart path before this (grep
/// `restartIce` = 0 hits repo-wide) — a WiFi→cellular handoff mid-call had
/// no recovery beyond WS-relay-per-frame fallback and whatever P2P pair
/// happened to survive.
///
/// These types contain NO WebRTC / PeerConnection state so the exact
/// numbers and branches can be pinned by unit tests without a live call —
/// same discipline as `GlareDecisions` / `UpgradeFlowDecisions` /
/// `MediaDeadDecisions` in this directory.
public enum RestartIceDecisions {

    // MARK: - Timing constants (ported verbatim from Android, same values,
    // same reasoning — see PeerConnectionHolder.kt's companion object and
    // CallController.kt's ICE_RESTART_DEBOUNCE_MS / ICE_SELF_REPAIR_*
    // constants, all dated 2026-08-24/25).

    /// Debounce window between consecutive ICE-restart attempts triggered
    /// by an external signal (network-change callback). A flapping
    /// LTE↔WiFi handoff would otherwise spam fresh CallOffer frames.
    /// Android `CallController.ICE_RESTART_DEBOUNCE_MS`.
    public static let iceRestartDebounceMs: Int64 = 3_000

    /// How long the recovery watchdog lets ICE self-repair (continual
    /// candidate gathering) BEFORE the first orchestrated restart, when a
    /// real OS network-change event preceded the bad state. Every
    /// self-recovery Android measured live landed within 0.4-2.3s; this
    /// brackets that with margin. Android `ICE_SELF_REPAIR_WINDOW_MS`.
    public static let selfRepairWindowMs: Int64 = 5_000

    /// Self-repair window used when the bad ICE state came with NO
    /// preceding OS network event — the silent-path-death case this item
    /// is named for (same-SSID AP roam, carrier NAT rebind, captive-portal
    /// re-auth). No interface event means no fresh candidates are coming,
    /// so self-repair is unlikely and every waited second is pure added
    /// outage — escalate sooner. Android `ICE_SELF_REPAIR_SHORT_WINDOW_MS`.
    public static let selfRepairShortWindowMs: Int64 = 1_500

    /// How recent an external network-change signal must be for a bad ICE
    /// state to be attributed to it (vs. treated as silent path death).
    /// Covers the observed spread between the platform callback and the
    /// ICE state excursion on a real handoff. Android
    /// `SILENT_PATH_DEATH_LOOKBACK_MS`.
    public static let silentPathDeathLookbackMs: Int64 = 4_000

    /// First settle window after firing a recovery attempt: how long to
    /// watch for ICE actually leaving the bad state before concluding this
    /// attempt didn't work and trying again. Android
    /// `ICE_FAILED_RECOVERY_INITIAL_SETTLE_MS`.
    public static let recoverySettleInitialMs: Int64 = 1_500

    /// Ceiling the settle window backs off to once repeated attempts show
    /// the WS was never the problem. Android
    /// `ICE_FAILED_RECOVERY_MAX_SETTLE_MS`.
    public static let recoverySettleMaxMs: Int64 = 20_000

    /// W-WATCHDOGDEBOUNCE (2026-08-30) — the actual sleep between two
    /// consecutive watchdog `restartIce` attempts: the proposed settle
    /// window, floored at `iceRestartDebounceMs` plus a margin so the next
    /// attempt can never land inside the debounce and be dropped unmade.
    /// With the raw `recoverySettleInitialMs` (1.5 s) the second attempt
    /// fell at T+1.5 s against a 3 s debounce and was ALWAYS discarded —
    /// the effective ladder was one attempt at T+0 and the next real one
    /// at T+4.5 s, with a logged-but-inert attempt in between. The margin
    /// absorbs timer jitter; the backoff sequence itself is untouched, only
    /// its floor.
    public static func recoveryRetrySettleMs(
        proposedMs: Int64,
        debounceMs: Int64 = iceRestartDebounceMs
    ) -> Int64 {
        max(proposedMs, debounceMs + 500)
    }

    /// Number of inline send attempts for a fresh restart offer before
    /// falling back to the park (250ms/500ms/1s/2s/4s backoff, ≈7.75s
    /// total — comfortably under the old fixed budget, matches Android's
    /// `RESTART_OFFER_MAX_RETRIES`).
    ///
    /// ⚠️ NOT CURRENTLY WIRED TO THE LIVE iOS SEND PATH (audit item 4,
    /// best-practices audit 2026-08-26). This constant — and the specific
    /// 250ms/500ms/1s/2s/4s ladder it implies — exists only as a ported,
    /// unit-tested reference of Android's `RESTART_OFFER_MAX_RETRIES`
    /// shape; `BCryptoCallingApiImpl.sendIceRestartOffer` (the actual live
    /// send path) never calls into it and never retries inline at all — it
    /// makes exactly ONE send attempt (bounded by `ws.ensureAuthenticated
    /// (timeoutSec:)`, an event-driven wait, not a retry loop) before
    /// falling back to the park. See that method's kdoc for the deliberate
    /// reasoning (the ladder exists on Android to race a `WsDispatcher
    /// .awaitSendReady` primitive this iOS WS client has no equivalent of;
    /// `ensureAuthenticated` already subsumes what the ladder is for here).
    /// Kept as a pinned reference value rather than deleted so a future
    /// port of that Android primitive has an already-tested target to wire
    /// against — but do not assume it governs today's live retry timing;
    /// `restartOfferFastPathTimeoutSec` / `restartOfferParkTimeoutSec`
    /// below are what actually ships.
    public static let restartOfferMaxInlineAttempts: Int = 5

    /// W-RESTARTOFFERPARK — how long a restart offer that exhausted the
    /// inline attempts above may wait, event-driven, for the WS to come
    /// back before the parked resend is abandoned. Bounded UNDER the
    /// server's 60s disconnect-grace ceiling so a resend landing inside
    /// this window still renews the server-side grace. Android
    /// `RESTART_OFFER_PARK_BUDGET_MS`.
    ///
    /// On iOS this total IS what ships, decomposed into the two constants
    /// immediately below (`restartOfferFastPathTimeoutSec` +
    /// `restartOfferParkTimeoutSec` == `restartOfferParkBudgetMs` / 1000) —
    /// unlike `restartOfferMaxInlineAttempts` above, whose specific ladder
    /// is not reused.
    public static let restartOfferParkBudgetMs: Int64 = 45_000

    /// W-RESTARTOFFERPARK / audit item 4 (2026-08-26) — the live iOS send
    /// path's actual FIRST-phase wait: how long `sendIceRestartOffer` waits
    /// for an authenticated socket before falling back to the detached
    /// park. Single source of truth for that literal (previously hardcoded
    /// inline in `BCryptoCallingApiImpl.sendIceRestartOffer` as `timeoutSec:
    /// 5`, untested and undocumented as a value anyone could pin) — pulled
    /// out here so the number the live path actually uses is unit-tested
    /// and cross-referenced from the same file as every other restart-ice
    /// timing constant, closing the "tested ladder vs. shipped behavior"
    /// gap the audit flagged.
    /// W-ICERESTARTGATE (2026-09-01, port of Android's IceRestartGate) —
    /// single-flight convergence window: once a restart attempt actually
    /// starts, further callers are refused for this long, because a clean
    /// restart measures ~7s to converge and an overlapping second offer
    /// mid-convergence resets the checklist and doubles the outage
    /// (Android live call cafc3f94: 5-6 overlapping restarts, 6 ICE pair
    /// flips in 11s). The 3s debounce absorbs trigger flaps; this window
    /// is the second, longer layer that protects the convergence itself.
    public static let iceRestartConvergenceWindowMs: Int64 = 10_000

    /// Reason-suffix marking a parked restart's deferred re-run. Exempt
    /// from BOTH the debounce and the convergence gate: the gate was
    /// extended for exactly this continuation, and gating it would
    /// deadlock the park against itself.
    public static let parkedResendReasonSuffix = ".parked-resend"

    public static let restartOfferFastPathTimeoutSec: TimeInterval = 5

    /// W-RESTARTOFFERPARK / audit item 4 — the live path's SECOND-phase
    /// wait: how much longer the detached park task waits for the socket
    /// once the fast path above has already spent its budget.
    /// `restartOfferFastPathTimeoutSec + restartOfferParkTimeoutSec` equals
    /// `restartOfferParkBudgetMs / 1000` (45s) by construction — pinned by
    /// `RestartIceDecisionsTests.test_liveParkTiming_sumsToParkBudget`.
    public static let restartOfferParkTimeoutSec: TimeInterval = 40

    // MARK: - W-SILENTPATHDEATH — self-repair window sizing

    /// Decide how long the ICE-recovery watchdog should let a bad
    /// (disconnected/failed) ICE state self-repair before escalating to an
    /// orchestrated restart, based on how recently an EXTERNAL (OS-driven)
    /// network-change signal was observed. `nil` (never seen one this
    /// call) is treated exactly like Android's zero-initialized
    /// `lastExternalNetworkChangeAtMs = 0L` default: `now - 0` is always
    /// far past the lookback window, so the short window applies until the
    /// first real network event of the call.
    public static func selfRepairWindowMs(msSinceLastExternalNetworkChange: Int64?) -> Int64 {
        guard let elapsed = msSinceLastExternalNetworkChange, elapsed <= silentPathDeathLookbackMs else {
            return selfRepairShortWindowMs
        }
        return selfRepairWindowMs
    }

    // MARK: - W-OFFERGLARE — restart-offer collision, RESPONDER (RX) side

    /// The local PeerConnection's JSEP signaling state at the moment a
    /// remote OFFER (fresh call OR mid-call restart) arrives. Deliberately
    /// a tiny mirror of `RTCSignalingState` rather than importing WebRTC
    /// here — keeps this file (and its tests) buildable without the
    /// WebRTC binary target, matching the other pure-decision files in
    /// this directory.
    public enum LocalSignalingState: Equatable {
        case stable
        case haveLocalOffer
        case other
    }

    /// What to do with an incoming remote OFFER, mirroring Android's
    /// `PeerConnectionHolder.handleRemoteOffer` branch bit-for-bit:
    ///   - `.stable` → apply normally (this is either the call's first
    ///     offer, or a restart offer arriving with nothing of ours pending).
    ///   - `.haveLocalOffer` (a glare: WE also have a pending local offer,
    ///     because both sides raced an ICE restart, or a stray re-offer
    ///     landed while our own restart offer is outstanding) → tiebreak on
    ///     the call's ORIGINAL role (`isInitiator`), fixed for the life of
    ///     the call at setup time — same politeness axis as the already-
    ///     shipped `UpgradeFlowDecisions.glareResolution` (Phase B
    ///     upgrade-glare): the initiator is impolite (wins, keeps its own
    ///     pending offer, ignores the incoming one) and the responder is
    ///     polite (rolls its own pending offer back, then applies the
    ///     peer's). NOT the lexicographic call-id tiebreak `GlareDecisions`
    ///     uses for mutual-dial glare — that mechanism doesn't apply here:
    ///     a restart-offer race shares ONE call id on both sides, so there
    ///     is nothing to lexicographically compare; Android's own
    ///     `handleRemoteOffer` resolves it from `activeAsInitiator` alone.
    ///   - anything else (`.other` — e.g. `haveRemoteOffer`,
    ///     `haveLocalPrAnswer`) → ignore the offer; unexpected mid-
    ///     negotiation state, most likely a duplicate `call_incoming`
    ///     dispatch racing this one.
    public enum RemoteOfferVerdict: Equatable {
        case applyNormally
        case initiatorIgnoreKeepPendingOffer
        case responderRollbackThenApply
        case ignoreUnexpectedState
    }

    public static func resolveIncomingOffer(
        signalingState: LocalSignalingState,
        isInitiator: Bool
    ) -> RemoteOfferVerdict {
        switch signalingState {
        case .stable:
            return .applyNormally
        case .haveLocalOffer:
            return isInitiator ? .initiatorIgnoreKeepPendingOffer : .responderRollbackThenApply
        case .other:
            return .ignoreUnexpectedState
        }
    }
}

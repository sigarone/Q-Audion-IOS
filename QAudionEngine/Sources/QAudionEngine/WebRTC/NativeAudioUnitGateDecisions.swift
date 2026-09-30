import Foundation

/// W-ADMGATE (2026-09-26) — who activated the shared `AVAudioSession` for the
/// call in progress. The native-SRTP audio unit (WebRTC's own VoiceProcessingIO,
/// gated by `RTCAudioSession.isAudioEnabled` in manual audio mode) may only be
/// started on a session CallKit itself has activated, or on one CallKit will
/// never activate — never on the app's own early self-activation of a
/// CallKit-managed call, which is the pre-priority session the reference
/// implementations deliberately never start the unit on.
///
/// Raw values are the numeric `src=` field of the `admgate` log lines.
public enum AudioSessionActivationSource: Int, Sendable, Equatable {
    /// Nothing activated the session for this call yet (or it was deactivated).
    /// Not named `none`: that would read as `Optional.none` wherever the
    /// type is optional or generic (e.g. `XCTAssertEqual(x, .none)`).
    case notActivated = 0
    /// `CXProviderDelegate.provider(_:didActivate:)` — CallKit's own,
    /// priority-elevated activation.
    case callKit = 1
    /// This app's own locked `setActive(true)` right after a CXStartCallAction
    /// or CXAnswerCallAction was fulfilled: CallKit's `didActivate` is still
    /// expected to follow for the same call.
    case selfExpectingCallKit = 2
    /// This app's own activation of a call CallKit will never activate: the
    /// suppressed/foreground-answer path, the wake-only self-managed session,
    /// CallKit-free mode, or a CallKit failure fallback.
    case selfManaged = 3
}

/// W-ADMGATE (2026-09-26) — pure decisions for the native-SRTP audio-unit
/// lifecycle (manual audio mode). No WebRTC / AVFoundation / clock state, so
/// every branch is pinned by `NativeAudioUnitGateDecisionsTests`.
///
/// ## The rule
///
/// WebRTC's own audio unit may run only when ALL of these hold:
/// 1. the call's native-SRTP snapshot is on (otherwise manual mode was never
///    armed and there is no m=audio: the custom path owns audio, untouched);
/// 2. the peer negotiated `audio-srtp-v1`;
/// 3. the relay fallback is not engaged (then the custom `AudioCapture` owns
///    the mic and two VoiceProcessingIO units must never run together);
/// 4. the session is active (for an activation that still expects CallKit,
///    confirmed by `RTCAudioSession` itself: ``sessionActiveForUnit``);
/// 5. the call is answered — incoming: the local accept, outgoing: the remote
///    answer (the reference implementations enable at `didActivate` for an
///    incoming call and at the remote answer for an outgoing one; with the
///    session-active condition above, "answered" covers both directions);
/// 6. the activation came from CallKit, or from a self-managed session, or
///    CallKit's own `didActivate` has been waited for long enough
///    (``callKitActivationWaitMs``): CallKit is known to skip `didActivate`
///    for a session a previous call left active (W-CKSTARTACTIVATE), and a
///    call that never starts its unit is the one outcome worse than starting
///    it on a self-activated session.
public enum NativeAudioUnitGateDecisions {

    /// Why the unit may (0) or may not start. Raw values are the numeric
    /// `verdict=` field of the `admgate verdict=` lines.
    public enum Verdict: Int, Sendable, Equatable {
        case enable = 0
        case notNativeCall = 1
        case notNegotiated = 2
        case fallbackActive = 3
        case noSession = 4
        case notAnswered = 5
        case awaitingCallKit = 6
    }

    /// Why the unit was switched on or off. Raw values are the numeric `why=`
    /// field of the `admgate en=` lines (the verdict codes above are logged
    /// under `verdict=`, so the two never share a field).
    public enum ChangeReason: Int, Sendable, Equatable {
        /// `CallService.startAudioIOIfReady`'s native branch, verdict `.enable`.
        case gate = 1
        /// CallKit `didDeactivate` (`CallService.handleAudioSessionDeactivated`).
        case sessionDeactivated = 2
        /// `CallService.teardownAudioStack` (call end, defensive teardowns).
        case teardown = 3
        /// Relay fallback engaged: the custom `AudioCapture` takes the mic.
        case fallbackEngage = 4
        /// Relay fallback recovered: the native unit takes the mic back.
        case fallbackRecover = 5
        /// W-CAPTURELIVE nudge (stop, then start the unit again).
        case captureLiveNudge = 6
        /// `QAudionPeerConnection.close()`, before `pc.close()` (backstop).
        case peerConnectionClose = 7
        /// A self-managed re-activation while the unit was enabled (the
        /// wake-only path after CallKit released the session): restart it.
        case selfManagedReactivation = 8
        /// Group calls v2 (`GroupAudioUnitDriver`): the unit of a group call is
        /// enabled once its audio session is active.
        case groupEnable = 9
        /// Group calls v2: the group call ended and released its arm.
        case groupEnd = 10
    }

    /// How long a `.selfExpectingCallKit` activation waits for CallKit's own
    /// `didActivate` before the unit is started anyway. Heuristic (no
    /// platform signal says "CallKit will not call didActivate"): the
    /// existing W469 self-activation fallback waits 1 s after the answer for
    /// the same event; this is that plus margin.
    public static let callKitActivationWaitMs: Int64 = 1_500

    /// Settle time between disabling the native unit and starting the custom
    /// `AudioCapture` (relay fallback). `isAudioEnabled = false` is applied by
    /// WebRTC asynchronously on its own audio thread and exposes no
    /// completion signal, so the stop cannot be awaited; this is the
    /// conservative bounded wait instead. Heuristic, not sourced.
    public static let fallbackUnitStopSettleMs: Int64 = 300

    public static func verdict(
        nativeSnapshot: Bool,
        negotiated: Bool,
        fallbackActive: Bool,
        sessionActive: Bool,
        answered: Bool,
        source: AudioSessionActivationSource,
        callKitWaitExpired: Bool
    ) -> Verdict {
        guard nativeSnapshot else { return .notNativeCall }
        guard negotiated else { return .notNegotiated }
        guard !fallbackActive else { return .fallbackActive }
        guard sessionActive, source != .notActivated else { return .noSession }
        guard answered else { return .notAnswered }
        if source == .selfExpectingCallKit, !callKitWaitExpired { return .awaitingCallKit }
        return .enable
    }

    /// W-ADMCONFIRM (2026-09-26) — the `sessionActive` input of ``verdict``.
    ///
    /// `appSessionActive` is `CallService`'s own bookkeeping, set by every
    /// `handleAudioSessionActivated` — including `CallKitProvider`'s W571 last
    /// resort, which fires it after ALL of its `setActive(true)` attempts
    /// FAILED. For a `.selfExpectingCallKit` activation the SDK's real state
    /// must agree: that source only comes from
    /// `CallKitProvider.activateAudioSession`, which activates exclusively
    /// through `RTCAudioSession`'s own locked `setActive`, so `isActive` is
    /// authoritative for it, and enabling the unit on a session nobody
    /// activated is the dead-TX shape this gate exists to prevent (the unit
    /// waits instead for CallKit's own `didActivate`). `.callKit` is CallKit's
    /// activation itself. `.selfManaged` also covers paths that activate
    /// `AVAudioSession` directly, outside the SDK's bookkeeping (CallKit-free
    /// mode, the CallKit failure fallbacks, W469), where `isActive` can read
    /// `false` on a genuinely active session: those keep the bookkeeping
    /// value, as before.
    public static func sessionActiveForUnit(
        appSessionActive: Bool,
        source: AudioSessionActivationSource,
        rtcSessionActive: Bool
    ) -> Bool {
        guard appSessionActive else { return false }
        guard source == .selfExpectingCallKit else { return true }
        return rtcSessionActive
    }

    /// Combine the source already recorded for this call with a new
    /// activation. CallKit's own activation is never downgraded by a later
    /// self-activation of the same call; a self-managed activation (CallKit
    /// will not come) wins over one that still expects CallKit.
    public static func mergedSource(
        current: AudioSessionActivationSource,
        incoming: AudioSessionActivationSource
    ) -> AudioSessionActivationSource {
        if current == .callKit || incoming == .callKit { return .callKit }
        if current == .selfManaged || incoming == .selfManaged { return .selfManaged }
        if incoming == .selfExpectingCallKit || current == .selfExpectingCallKit { return .selfExpectingCallKit }
        return .notActivated
    }

    /// W-DEACTOWN (2026-09-27) — which call a CallKit `didDeactivate` belongs
    /// to. Raw values are the numeric `own=` codes of the log lines.
    public enum DeactivationOwner: Int, Sendable, Equatable {
        /// Paired with a CallKit `didActivate` handled during the current call.
        case currentCall = 0
        /// Paired with the `didActivate` of a call that has since ended: a late
        /// notification for the previous call of a back-to-back pair.
        case endedCall = 1
        /// No CallKit activation to pair it with (none seen, or already
        /// consumed by an earlier deactivation): taken as the current call's,
        /// the behaviour before this decision existed.
        case unattributed = 2
    }

    /// W-DEACTOWN (2026-09-27) — `didDeactivate` carries no call identity, so
    /// it is attributed through its pairing: CallKit delivers `didActivate`
    /// and `didDeactivate` strictly alternating on the provider's queue, so a
    /// deactivation belongs to the call during which the last CallKit
    /// `didActivate` was handled. `pairedActivationGeneration` is the call
    /// generation (CallService's W-STALESEALER counter, bumped at every call
    /// end) recorded at that `didActivate`, `nil` if there is none;
    /// `currentGeneration` is the generation now.
    ///
    /// Known limit: when CallKit skips `didActivate` for a call because the
    /// previous call left the session active (W-CKSTARTACTIVATE), a genuine
    /// deactivation of that call is paired with the previous call and read as
    /// `.endedCall`. On a native call the caller then keeps the unit enabled
    /// (never mutes a live call); WebRTC still receives the deactivation
    /// itself (`CallKitProvider` forwards it before this decision runs).
    public static func callKitDeactivationOwner(
        pairedActivationGeneration: Int?,
        currentGeneration: Int
    ) -> DeactivationOwner {
        guard let paired = pairedActivationGeneration else { return .unattributed }
        return paired == currentGeneration ? .currentCall : .endedCall
    }

    /// W-NUDGEOWN (2026-09-27) — what the capture-live nudge (manual audio
    /// mode) may do after its owner-checked stop
    /// (`NativeAudioSessionGate.setNativeAudioInactive(ifCurrent:reason:)`).
    public enum NudgeOwnership: Int, Sendable, Equatable {
        /// This PeerConnection still owns the unit: ask for the restart.
        case restart = 0
        /// It no longer does (closed, replaced, or a later call armed): the
        /// check is stale and must stop here — no restart request and no
        /// escalation to the relay fallback, both of which would act on the
        /// successor's call.
        case stale = 1
    }

    /// `ownerToken`: the arm token of the PeerConnection the check was armed
    /// for (0 = it never armed). `stopped`: the owner-checked stop switched
    /// the unit off. `ownerStillCurrent`: that token is still the arm in force
    /// (read after a stop that did nothing — the unit may simply have been
    /// off already, which still wants the restart).
    public static func nudgeOwnership(ownerToken: Int, stopped: Bool, ownerStillCurrent: Bool) -> NudgeOwnership {
        guard ownerToken != 0 else { return .stale }
        if stopped { return .restart }
        return ownerStillCurrent ? .restart : .stale
    }

    /// W-ADMBALANCE (2026-09-26) — the iteration cap for the locked
    /// `RTCAudioSession.setActive(false)` loop in
    /// `CallKitProvider.reportCallEnded` (the loop itself also stops when the
    /// activation count reaches 0).
    ///
    /// Legacy calls keep the W-DRAINACTIVATION drain byte-for-byte: cap
    /// `maxDrain`, i.e. until the count reaches 0. A native-SRTP call issues ONE: it
    /// balances the app's own self-activation and nothing else. In manual mode
    /// WebRTC's own configure/unconfigure of the session are paired by the
    /// unit's disable, and CallKit's `didDeactivate` balances its own
    /// `didActivate`; draining those too made THIS app deactivate the real
    /// session while CallKit was about to, and — when the next call's session
    /// had already been activated — deactivate that one.
    public static func deactivationCalls(
        activationCount: Int,
        nativeManualCall: Bool,
        maxDrain: Int = 10
    ) -> Int {
        guard activationCount > 0 else { return 0 }
        return nativeManualCall ? 1 : maxDrain
    }
}

/// W-AUDIORXREBIND (2026-09-26) — `NativeAudioFrameCryptor.rebindReceiver`
/// used to dispose and re-create the receiver FrameCryptor on EVERY call to
/// `installAudioSrtpIfPossible` (three triggers per call plus every rekey),
/// although its caller documented it as a no-op when the receiver had not
/// changed. Re-creating the transformer on a live receiver opens a window in
/// which inbound frames are dropped. Pure so it can be pinned by a test.
///
/// Conservative on purpose: until one rebind has run on a COMPLETED
/// negotiation (signaling stable, transceiver has a mid), every rebind runs as
/// before, even on the same receiver id, because W-AUDIORXPOSTNEG (and the
/// video OFFERER-UPGRADE DECODE FIX it mirrors) found a transformer attached
/// before the negotiation completed can stay bound to the pre-negotiation
/// state on the SAME receiver object. Only the later, repeated rebinds on an
/// unchanged receiver are skipped.
public enum NativeAudioReceiverRebindDecision {
    public static func shouldRebind(
        boundReceiverId: String?,
        liveReceiverId: String,
        alreadyReboundPostNegotiation: Bool
    ) -> Bool {
        guard alreadyReboundPostNegotiation else { return true }
        guard let bound = boundReceiverId, !bound.isEmpty else { return true }
        return bound != liveReceiverId
    }
}

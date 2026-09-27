import XCTest
@testable import QAudionEngine

/// W-ADMGATE (2026-09-26) — pins when WebRTC's own audio unit may be enabled
/// (`RTCAudioSession.isAudioEnabled = true`) on a native-SRTP call, the
/// activation-source merge, the reportCallEnded balance policy and the
/// receiver-rebind decision. Same style as `CaptureLiveDecisionsTests`.
final class NativeAudioUnitGateDecisionsTests: XCTestCase {

    private typealias D = NativeAudioUnitGateDecisions

    /// Everything satisfied, CallKit's own activation: enable.
    private func verdict(
        native: Bool = true,
        negotiated: Bool = true,
        fallback: Bool = false,
        session: Bool = true,
        answered: Bool = true,
        source: AudioSessionActivationSource = .callKit,
        waitExpired: Bool = false
    ) -> D.Verdict {
        D.verdict(nativeSnapshot: native, negotiated: negotiated, fallbackActive: fallback,
                  sessionActive: session, answered: answered, source: source,
                  callKitWaitExpired: waitExpired)
    }

    func test_allConditionsWithCallKitActivation_enables() {
        XCTAssertEqual(verdict(), .enable)
    }

    /// Toggle off for this call: never, whatever else holds — the custom path
    /// owns audio and manual mode was never armed.
    func test_nativeSnapshotOff_neverEnables() {
        XCTAssertEqual(verdict(native: false), .notNativeCall)
        XCTAssertEqual(verdict(native: false, source: .selfManaged, waitExpired: true), .notNativeCall)
    }

    /// Toggle on but the peer did not agree: the m=audio line exists, the unit
    /// must stay off so the custom VoiceProcessingIO is the only one running.
    func test_notNegotiated_neverEnables() {
        XCTAssertEqual(verdict(negotiated: false), .notNegotiated)
    }

    /// Relay fallback engaged: the custom AudioCapture owns the mic.
    func test_fallbackActive_neverEnables() {
        XCTAssertEqual(verdict(fallback: true), .fallbackActive)
    }

    func test_noSessionOrNoSource_doesNotEnable() {
        XCTAssertEqual(verdict(session: false), .noSession)
        XCTAssertEqual(verdict(source: .notActivated), .noSession)
    }

    /// Outgoing call: CallKit activates before the peer answers — wait for the
    /// remote answer. Incoming: the local accept precedes didActivate.
    func test_notAnswered_doesNotEnable() {
        XCTAssertEqual(verdict(answered: false), .notAnswered)
        XCTAssertEqual(verdict(answered: false, source: .selfManaged), .notAnswered)
    }

    /// Own self-activation of a CallKit-managed call: wait for didActivate...
    func test_selfActivationExpectingCallKit_waits() {
        XCTAssertEqual(verdict(source: .selfExpectingCallKit), .awaitingCallKit)
    }

    /// ...but not forever (CallKit may skip didActivate for a session a
    /// previous call left active).
    func test_selfActivationExpectingCallKit_enablesAfterWait() {
        XCTAssertEqual(verdict(source: .selfExpectingCallKit, waitExpired: true), .enable)
    }

    /// A call CallKit never activates does not wait.
    func test_selfManaged_enablesImmediately() {
        XCTAssertEqual(verdict(source: .selfManaged), .enable)
    }

    /// The numeric codes are log fields: pin them.
    func test_verdictRawValues_areStableLogCodes() {
        XCTAssertEqual(D.Verdict.enable.rawValue, 0)
        XCTAssertEqual(D.Verdict.notNativeCall.rawValue, 1)
        XCTAssertEqual(D.Verdict.notNegotiated.rawValue, 2)
        XCTAssertEqual(D.Verdict.fallbackActive.rawValue, 3)
        XCTAssertEqual(D.Verdict.noSession.rawValue, 4)
        XCTAssertEqual(D.Verdict.notAnswered.rawValue, 5)
        XCTAssertEqual(D.Verdict.awaitingCallKit.rawValue, 6)
        XCTAssertEqual(AudioSessionActivationSource.notActivated.rawValue, 0)
        XCTAssertEqual(AudioSessionActivationSource.callKit.rawValue, 1)
        XCTAssertEqual(AudioSessionActivationSource.selfExpectingCallKit.rawValue, 2)
        XCTAssertEqual(AudioSessionActivationSource.selfManaged.rawValue, 3)
        XCTAssertEqual(D.ChangeReason.gate.rawValue, 1)
        XCTAssertEqual(D.ChangeReason.sessionDeactivated.rawValue, 2)
        XCTAssertEqual(D.ChangeReason.teardown.rawValue, 3)
        XCTAssertEqual(D.ChangeReason.fallbackEngage.rawValue, 4)
        XCTAssertEqual(D.ChangeReason.fallbackRecover.rawValue, 5)
        XCTAssertEqual(D.ChangeReason.captureLiveNudge.rawValue, 6)
        XCTAssertEqual(D.ChangeReason.peerConnectionClose.rawValue, 7)
        XCTAssertEqual(D.ChangeReason.selfManagedReactivation.rawValue, 8)
    }

    // MARK: - sessionActiveForUnit (W-ADMCONFIRM)

    /// THE bug: CallKitProvider's W571 last resort reports an activation after
    /// every setActive(true) attempt failed. For a self-activation expecting
    /// CallKit the SDK's own state decides, so the unit is not started (even
    /// after the CallKit wait) on a session nobody activated.
    func test_unconfirmedSelfActivationExpectingCallKit_isNoSession() {
        let active = D.sessionActiveForUnit(
            appSessionActive: true, source: .selfExpectingCallKit, rtcSessionActive: false)
        XCTAssertFalse(active)
        XCTAssertEqual(verdict(session: active, source: .selfExpectingCallKit, waitExpired: true), .noSession)
    }

    func test_confirmedSelfActivationExpectingCallKit_isActive() {
        XCTAssertTrue(D.sessionActiveForUnit(
            appSessionActive: true, source: .selfExpectingCallKit, rtcSessionActive: true))
    }

    /// CallKit's own activation and self-managed ones (some of which activate
    /// AVAudioSession outside the SDK's bookkeeping) keep the app's value.
    func test_callKitAndSelfManaged_keepTheAppBookkeeping() {
        XCTAssertTrue(D.sessionActiveForUnit(appSessionActive: true, source: .callKit, rtcSessionActive: false))
        XCTAssertTrue(D.sessionActiveForUnit(appSessionActive: true, source: .selfManaged, rtcSessionActive: false))
    }

    func test_appSessionInactive_isNeverActive() {
        for source in [AudioSessionActivationSource.notActivated, .callKit, .selfExpectingCallKit, .selfManaged] {
            XCTAssertFalse(D.sessionActiveForUnit(appSessionActive: false, source: source, rtcSessionActive: true))
        }
    }

    // MARK: - mergedSource

    func test_callKitIsNeverDowngraded() {
        XCTAssertEqual(D.mergedSource(current: .callKit, incoming: .selfExpectingCallKit), .callKit)
        XCTAssertEqual(D.mergedSource(current: .callKit, incoming: .selfManaged), .callKit)
        XCTAssertEqual(D.mergedSource(current: .selfExpectingCallKit, incoming: .callKit), .callKit)
    }

    func test_selfManagedBeatsSelfExpecting() {
        XCTAssertEqual(D.mergedSource(current: .selfExpectingCallKit, incoming: .selfManaged), .selfManaged)
        XCTAssertEqual(D.mergedSource(current: .selfManaged, incoming: .selfExpectingCallKit), .selfManaged)
    }

    func test_firstActivationIsTakenAsIs() {
        XCTAssertEqual(D.mergedSource(current: .notActivated, incoming: .selfExpectingCallKit), .selfExpectingCallKit)
        XCTAssertEqual(D.mergedSource(current: .notActivated, incoming: .notActivated), .notActivated)
    }

    // MARK: - deactivationCalls

    /// Legacy calls keep the W-DRAINACTIVATION drain exactly: the cap stays
    /// 10 and the loop's own `activationCount > 0` stops it at zero.
    func test_legacyCall_drainsToZeroBounded() {
        XCTAssertEqual(D.deactivationCalls(activationCount: 3, nativeManualCall: false), 10)
        XCTAssertEqual(D.deactivationCalls(activationCount: 25, nativeManualCall: false), 10)
        XCTAssertEqual(D.deactivationCalls(activationCount: 0, nativeManualCall: false), 0)
        XCTAssertEqual(D.deactivationCalls(activationCount: -1, nativeManualCall: false), 0)
    }

    /// Native calls balance only the app's own self-activation.
    func test_nativeCall_singleBalancedDeactivation() {
        XCTAssertEqual(D.deactivationCalls(activationCount: 3, nativeManualCall: true), 1)
        XCTAssertEqual(D.deactivationCalls(activationCount: 1, nativeManualCall: true), 1)
        XCTAssertEqual(D.deactivationCalls(activationCount: 0, nativeManualCall: true), 0)
    }

    // MARK: - callKitDeactivationOwner (W-DEACTOWN)

    /// Paired with a didActivate handled during this call: this call's own
    /// deactivation (interruption, call end before the teardown ran).
    func test_deactivationPairedWithCurrentCall_isTheCurrentCalls() {
        XCTAssertEqual(D.callKitDeactivationOwner(pairedActivationGeneration: 7, currentGeneration: 7), .currentCall)
    }

    /// THE race: the previous call's didDeactivate lands after the next call
    /// started (the generation was bumped by the previous call's end).
    func test_deactivationPairedWithEndedCall_isStale() {
        XCTAssertEqual(D.callKitDeactivationOwner(pairedActivationGeneration: 6, currentGeneration: 7), .endedCall)
        XCTAssertEqual(D.callKitDeactivationOwner(pairedActivationGeneration: 0, currentGeneration: 1), .endedCall)
    }

    /// No didActivate to pair with: the pre-fix behaviour (current call).
    func test_unpairedDeactivation_isUnattributed() {
        XCTAssertEqual(D.callKitDeactivationOwner(pairedActivationGeneration: nil, currentGeneration: 7), .unattributed)
    }

    func test_deactivationOwnerRawValues_areStableLogCodes() {
        XCTAssertEqual(D.DeactivationOwner.currentCall.rawValue, 0)
        XCTAssertEqual(D.DeactivationOwner.endedCall.rawValue, 1)
        XCTAssertEqual(D.DeactivationOwner.unattributed.rawValue, 2)
    }

    // MARK: - nudgeOwnership (W-NUDGEOWN)

    /// The owner stopped its own unit: restart it through the gate.
    func test_nudge_ownerStoppedItsUnit_restarts() {
        XCTAssertEqual(D.nudgeOwnership(ownerToken: 3, stopped: true, ownerStillCurrent: true), .restart)
    }

    /// Still the owner but the unit was already off: the restart is still wanted.
    func test_nudge_ownerWithUnitAlreadyOff_restarts() {
        XCTAssertEqual(D.nudgeOwnership(ownerToken: 3, stopped: false, ownerStillCurrent: true), .restart)
    }

    /// THE race: a replacement (or the next call) armed meanwhile. Nothing may
    /// be restarted or escalated on its behalf.
    func test_nudge_replacedOwner_isStale() {
        XCTAssertEqual(D.nudgeOwnership(ownerToken: 3, stopped: false, ownerStillCurrent: false), .stale)
    }

    /// A check armed for a PeerConnection that never armed owns nothing.
    func test_nudge_noOwnerToken_isStale() {
        XCTAssertEqual(D.nudgeOwnership(ownerToken: 0, stopped: false, ownerStillCurrent: false), .stale)
        XCTAssertEqual(D.nudgeOwnership(ownerToken: 0, stopped: true, ownerStillCurrent: true), .stale)
    }

    // MARK: - NativeAudioReceiverRebindDecision

    private func rebind(_ bound: String?, _ live: String, done: Bool) -> Bool {
        NativeAudioReceiverRebindDecision.shouldRebind(
            boundReceiverId: bound, liveReceiverId: live, alreadyReboundPostNegotiation: done)
    }

    /// The first post-negotiation rebind always happens (W-AUDIORXPOSTNEG),
    /// even on the same receiver id.
    func test_firstPostNegotiationRebind_alwaysHappens() {
        XCTAssertTrue(rebind("r1", "r1", done: false))
        XCTAssertTrue(rebind(nil, "r1", done: false))
    }

    /// After it: only a changed or missing receiver rebinds (rekeys and
    /// repeated triggers no longer re-create a live transformer).
    func test_laterRebinds_onlyWhenReceiverChangedOrUnbound() {
        XCTAssertFalse(rebind("r1", "r1", done: true))
        XCTAssertTrue(rebind("r0", "r1", done: true))
        XCTAssertTrue(rebind(nil, "r1", done: true))
        XCTAssertTrue(rebind("", "r1", done: true))
    }
}

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
        XCTAssertEqual(verdict(source: .none), .noSession)
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
        XCTAssertEqual(AudioSessionActivationSource.none.rawValue, 0)
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
        XCTAssertEqual(D.mergedSource(current: .none, incoming: .selfExpectingCallKit), .selfExpectingCallKit)
        XCTAssertEqual(D.mergedSource(current: .none, incoming: .none), .none)
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

    // MARK: - NativeAudioReceiverRebindDecision

    func test_rebind_onlyWhenReceiverChangedOrUnbound() {
        XCTAssertTrue(NativeAudioReceiverRebindDecision.shouldRebind(boundReceiverId: nil, liveReceiverId: "r1"))
        XCTAssertTrue(NativeAudioReceiverRebindDecision.shouldRebind(boundReceiverId: "", liveReceiverId: "r1"))
        XCTAssertTrue(NativeAudioReceiverRebindDecision.shouldRebind(boundReceiverId: "r0", liveReceiverId: "r1"))
        XCTAssertFalse(NativeAudioReceiverRebindDecision.shouldRebind(boundReceiverId: "r1", liveReceiverId: "r1"))
    }
}

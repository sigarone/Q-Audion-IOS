import XCTest
@testable import QAudionEngine

/// W-CALLERBUSY (2026-10-03, review of #169) — a `call_busy` / `call_peer_offline` that lands BEFORE CallKit has
/// finished starting the outgoing call.
///
/// `AppState.startCall` assigns `activeCallKitId` only after `CallKitManaging.startOutgoingCall` returns (the
/// `CXStartCallAction` round trip). In the incident of 2026-10-03 10:43 the server's busy arrived 577 ms after the
/// dial and the CallKit start was fulfilled at about 691 ms: `AppState.endCall` found `activeCallKitId == nil`,
/// reported nothing, and the late assignment re-created the orphan call group that made every redial fail with
/// `maximumCallGroupsReached`. The decision that closes it is `OutgoingCallKitStartPolicy`; `AppState` cannot be
/// driven here (CallKit, live provider, WebSocket), so the wiring is pinned by `CallerBusyWiringTests` and the
/// sequence is replayed below against the real policy, the real accept latch and `MockCallKitManager`.
final class OutgoingCallKitStartPolicyTests: XCTestCase {

    private let callA = "11111111-1111-4111-8111-111111111111"
    private let callB = "22222222-2222-4222-8222-222222222222"

    private func isAdopt(_ d: OutgoingCallKitStartPolicy.Decision) -> Bool {
        if case .adopt = d { return true }
        return false
    }

    private func lateReason(_ d: OutgoingCallKitStartPolicy.Decision) -> CallEndReason? {
        if case .endAtOnce(let reason) = d { return reason }
        return nil
    }

    // MARK: - the pure decision

    /// The normal case: CallKit answered before anything ended the call. The uuid is adopted, as it always was.
    func testACallThatIsStillCurrentAdoptsTheCallKitCall() {
        XCTAssertTrue(isAdopt(OutgoingCallKitStartPolicy.decide(callStillCurrent: true, endedBy: nil)))
        for outcome in CallerTerminalOutcome.allCases {
            // A stale outcome (of an earlier call) never turns a live call into an ended one.
            XCTAssertTrue(isAdopt(OutgoingCallKitStartPolicy.decide(callStillCurrent: true, endedBy: outcome)), "\(outcome)")
        }
    }

    func testABusyThatLandedBeforeTheStartReturnedIsReportedUnanswered() {
        let d = OutgoingCallKitStartPolicy.decide(callStillCurrent: false, endedBy: .busy)
        XCTAssertEqual(lateReason(d), CallEndReason.unanswered)
    }

    func testAPeerOfflineThatLandedBeforeTheStartReturnedIsReportedRemoteEnded() {
        let d = OutgoingCallKitStartPolicy.decide(callStillCurrent: false, endedBy: .peerOffline)
        XCTAssertEqual(lateReason(d), CallEndReason.remoteEnded)
    }

    /// A hangup (or any other ending) before the start returned: the `AppState.endCall` default, a local end.
    func testAnotherEndingIsReportedUserEnded() {
        let d = OutgoingCallKitStartPolicy.decide(callStillCurrent: false, endedBy: nil)
        XCTAssertEqual(lateReason(d), CallEndReason.userEnded)
    }

    func testAnEndedCallIsNeverAdoptedAndNeverReportedAsFailed() {
        let outcomes: [CallerTerminalOutcome?] = [nil] + CallerTerminalOutcome.allCases.map { Optional($0) }
        for outcome in outcomes {
            let d = OutgoingCallKitStartPolicy.decide(callStillCurrent: false, endedBy: outcome)
            XCTAssertFalse(isAdopt(d), "\(String(describing: outcome)): an ended call's uuid must not become activeCallKitId")
            guard let reason = lateReason(d) else { return XCTFail("an ended call must be reported ended") }
            if case .failed = reason { XCTFail("\(String(describing: outcome)): nothing failed") }
            if case .declined = reason { XCTFail("\(String(describing: outcome)): nobody declined") }
        }
    }

    /// The late report uses exactly the reason the teardown reports (`CallerTerminalOutcome.callKitEndReason`).
    func testTheLateReasonIsTheTeardownReasonOfTheOutcome() {
        for outcome in CallerTerminalOutcome.allCases {
            let d = OutgoingCallKitStartPolicy.decide(callStillCurrent: false, endedBy: outcome)
            XCTAssertEqual(lateReason(d), outcome.callKitEndReason, "\(outcome)")
        }
    }

    // MARK: - the record of how a call ended

    func testTheEndRecordAnswersOnlyForItsOwnCall() {
        let hex = "8b392e49-aaaa-4bbb-8ccc-0123456789ab"
        let record = CallerTerminalEndRecord(callId: hex.uppercased(), outcome: .busy)
        XCTAssertEqual(record.callId, hex, "stored lowercased, like the latch's id")
        XCTAssertEqual(record.outcome(forCallId: hex), .busy)
        XCTAssertEqual(record.outcome(forCallId: hex.uppercased()), .busy, "case-insensitive")
        XCTAssertNil(record.outcome(forCallId: callB), "another call's start must not be told this call's outcome")
        XCTAssertNil(record.outcome(forCallId: ""))
        XCTAssertNil(CallerTerminalEndRecord(callId: "", outcome: .busy).outcome(forCallId: ""))
    }

    // MARK: - the incident sequence, replayed

    /// The `AppState` pieces that matter, reduced to what the policy sees. `endCall` reports to CallKit only when it
    /// knows the uuid (`activeCallKitId`); `callKitStartReturned` is the tail of `startCall`'s CallKit `Task`
    /// (`AppState.settleOutgoingCallKitStart`).
    private final class Dialer {
        let callKit = MockCallKitManager()
        var latch = CallerAcceptLatch()
        var isInCall = false
        var phase: CallerAcceptLatch.Phase = .idle
        var activeCallKitId: UUID?
        var terminalEnd: CallerTerminalEndRecord?

        func dial(_ id: String) {
            latch.beginOutgoing(callId: id)
            isInCall = true
            phase = .ringing
        }

        /// `AppState.endCall(notifyPeerInBand:outcome:)`, CallKit part and the state it clears.
        func endCall(outcome: CallerTerminalOutcome? = nil) async {
            if let uuid = activeCallKitId {
                await callKit.reportCallEnded(uuid: uuid, reason: outcome?.callKitEndReason ?? .userEnded)
            }
            activeCallKitId = nil
            latch.reset()
            isInCall = false
            phase = .idle
        }

        /// The gate, then `endOutgoingCallAfterTerminalEnvelope`.
        func terminalEnvelope(_ outcome: CallerTerminalOutcome, callId: String) async {
            guard case .endOutgoingCall = latch.terminalEnvelopeArrived(envelopeCallId: callId, phase: phase) else { return }
            terminalEnd = CallerTerminalEndRecord(callId: callId, outcome: outcome)
            await endCall(outcome: outcome)
        }

        func callKitStartReturned(uuid: UUID, wireCallId: String) async {
            let current = isInCall && latch.isCurrentOutgoingCall(envelopeCallId: wireCallId)
            switch OutgoingCallKitStartPolicy.decide(
                callStillCurrent: current, endedBy: terminalEnd?.outcome(forCallId: wireCallId)) {
            case .adopt:
                activeCallKitId = uuid
            case .endAtOnce(let reason):
                await callKit.reportCallEnded(uuid: uuid, reason: reason)
            }
        }
    }

    /// The incident: busy first, the CallKit start returns afterwards. Exactly one report, `.unanswered`, and no
    /// orphan left in `activeCallKitId` (what `noCallInFlight()` and the next dial look at).
    func testBusyBeforeTheCallKitStartReturnsClosesTheLateCallKitCall() async {
        let d = Dialer()
        let uuid = UUID()
        d.dial(callA)
        await d.terminalEnvelope(.busy, callId: callA)
        XCTAssertNil(d.activeCallKitId)
        XCTAssertTrue(d.callKit.records.isEmpty, "endCall had no CallKit uuid to report yet")

        await d.callKitStartReturned(uuid: uuid, wireCallId: callA)

        XCTAssertNil(d.activeCallKitId, "the ended call's uuid must not be stored")
        XCTAssertEqual(d.callKit.records, [CallRecord(action: .reportCallEnded(uuid: uuid, reason: .unanswered))])
    }

    func testPeerOfflineBeforeTheCallKitStartReturnsClosesTheLateCallKitCall() async {
        let d = Dialer()
        let uuid = UUID()
        d.dial(callA)
        await d.terminalEnvelope(.peerOffline, callId: callA)
        await d.callKitStartReturned(uuid: uuid, wireCallId: callA)
        XCTAssertNil(d.activeCallKitId)
        XCTAssertEqual(d.callKit.records, [CallRecord(action: .reportCallEnded(uuid: uuid, reason: .remoteEnded))])
    }

    /// The other order (CallKit answered first): adopted, and the teardown reports it once, as before.
    func testBusyAfterTheCallKitStartReturnedIsReportedOnceByTheTeardown() async {
        let d = Dialer()
        let uuid = UUID()
        d.dial(callA)
        await d.callKitStartReturned(uuid: uuid, wireCallId: callA)
        XCTAssertEqual(d.activeCallKitId, uuid)

        await d.terminalEnvelope(.busy, callId: callA)

        XCTAssertNil(d.activeCallKitId)
        XCTAssertEqual(d.callKit.records, [CallRecord(action: .reportCallEnded(uuid: uuid, reason: .unanswered))])
    }

    /// A local hangup before the start returned is the same hole: ended at once, as a local end.
    func testAHangupBeforeTheCallKitStartReturnsClosesTheLateCallKitCall() async {
        let d = Dialer()
        let uuid = UUID()
        d.dial(callA)
        await d.endCall()
        await d.callKitStartReturned(uuid: uuid, wireCallId: callA)
        XCTAssertNil(d.activeCallKitId)
        XCTAssertEqual(d.callKit.records, [CallRecord(action: .reportCallEnded(uuid: uuid, reason: .userEnded))])
    }

    /// Dial, busy, an immediate redial, and only then the first start returns: the first uuid is closed, the redial's
    /// own CallKit call is not touched, and it is adopted when it returns.
    func testALateStartOfAnEarlierCallNeverTouchesTheRedial() async {
        let d = Dialer()
        let first = UUID()
        let second = UUID()
        d.dial(callA)
        await d.terminalEnvelope(.busy, callId: callA)
        d.dial(callB)                                   // the redial, before call A's CallKit start returned

        await d.callKitStartReturned(uuid: first, wireCallId: callA)
        XCTAssertNil(d.activeCallKitId, "the redial has no CallKit call yet, and call A's must not become it")
        XCTAssertEqual(d.callKit.records, [CallRecord(action: .reportCallEnded(uuid: first, reason: .unanswered))])
        XCTAssertTrue(d.isInCall)
        XCTAssertTrue(d.latch.isCurrentOutgoingCall(envelopeCallId: callB))

        await d.callKitStartReturned(uuid: second, wireCallId: callB)
        XCTAssertEqual(d.activeCallKitId, second)
        XCTAssertEqual(d.callKit.records.count, 1, "the redial's call is adopted, not reported")
    }

    /// The incident's three dials, each with the busy landing before CallKit answered: nothing is left open and every
    /// CallKit call was reported once.
    func testThreeBusyDialsLeaveNoCallKitCallOpen() async {
        let d = Dialer()
        var uuids: [UUID] = []
        for callId in [callA, callB, "33333333-3333-4333-8333-333333333333"] {
            let uuid = UUID()
            uuids.append(uuid)
            d.dial(callId)
            await d.terminalEnvelope(.busy, callId: callId)
            await d.callKitStartReturned(uuid: uuid, wireCallId: callId)
            XCTAssertNil(d.activeCallKitId, "after each busy the app holds no CallKit call")
            XCTAssertFalse(d.isInCall)
        }
        XCTAssertEqual(d.callKit.records, uuids.map { CallRecord(action: .reportCallEnded(uuid: $0, reason: .unanswered)) })
    }
}

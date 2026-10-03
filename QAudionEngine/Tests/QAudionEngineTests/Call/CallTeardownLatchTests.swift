import XCTest
@testable import QAudionEngine

/// W-CALLERBUSY (2026-10-03, review of #169) — `AppState.endCall`'s H-6 re-entrancy guard, scoped to the call it
/// guards (`CallTeardownLatch`).
///
/// The defect: the guard was a plain flag that stays up for 0.3 s after a teardown. A redial inside that window
/// inherited it, so the redial's own teardown (a `call_busy` comes back within a second) did nothing and left a zombie
/// `.connecting` call with `isInCall == true`. `AppState` cannot be driven here, so the latch is tested on its own and
/// the sequence is replayed against it and the real `CallerAcceptLatch`; `CallerBusyWiringTests` pins that
/// `AppState` uses it.
final class CallTeardownLatchTests: XCTestCase {

    private let callA = "11111111-1111-4111-8111-111111111111"
    private let callB = "22222222-2222-4222-8222-222222222222"

    // MARK: - the latch

    /// H-6, unchanged for one call: a second teardown while the first is in flight is refused.
    func testASecondTeardownOfTheSameCallIsRefusedUntilTheTimerReleases() throws {
        var latch = CallTeardownLatch()
        XCTAssertFalse(latch.inFlight)
        let token = try XCTUnwrap(latch.begin())
        XCTAssertTrue(latch.inFlight)
        XCTAssertNil(latch.begin(), "H-6: CallKit onEndCall racing a remote call_hangup must be a no-op")
        latch.release(token: token)
        XCTAssertFalse(latch.inFlight)
        XCTAssertNotNil(latch.begin(), "the guard is open again once its own teardown has settled")
    }

    /// A new call is admitted inside the previous call's window: the guard no longer applies.
    func testAdmittingANewCallOpensTheGuardOfThePreviousTeardown() throws {
        var latch = CallTeardownLatch()
        _ = try XCTUnwrap(latch.begin())
        latch.newCallAdmitted()
        XCTAssertFalse(latch.inFlight)
        XCTAssertNotNil(latch.begin(), "the redial's own teardown must run")
    }

    /// The earlier teardown's 0.3 s timer must not open the guard of a later call's teardown.
    func testAnEarlierTimerNeverReleasesALaterTeardown() throws {
        var latch = CallTeardownLatch()
        let first = try XCTUnwrap(latch.begin())
        latch.newCallAdmitted()
        let second = try XCTUnwrap(latch.begin())
        XCTAssertNotEqual(first, second)

        latch.release(token: first)
        XCTAssertTrue(latch.inFlight, "the first call's timer says nothing about the second call's teardown")
        XCTAssertNil(latch.begin(), "H-6 still holds for the second call")

        latch.release(token: second)
        XCTAssertFalse(latch.inFlight)
    }

    func testReleasingWhenNothingIsInFlightIsANoOp() {
        var latch = CallTeardownLatch()
        latch.release(token: 1)
        XCTAssertFalse(latch.inFlight)
        XCTAssertNotNil(latch.begin())
    }

    // MARK: - the incident sequence, replayed

    /// The `AppState` pieces that matter: the accept latch, the teardown latch, `startCall`'s commit point
    /// (`beginOutgoing` + `newCallAdmitted`) and `endCall`'s guard, plus the busy handler's "hangup in flight" test.
    private final class Caller {
        var accept = CallerAcceptLatch()
        var teardown = CallTeardownLatch()
        var isInCall = false
        var phase: CallerAcceptLatch.Phase = .idle
        var outcomeShown: CallerTerminalOutcome?
        var teardownsRun = 0
        /// The 0.3 s timers `endCall` armed, in order.
        var pendingTimers: [Int] = []

        func dial(_ id: String) {
            accept.beginOutgoing(callId: id)
            teardown.newCallAdmitted()
            isInCall = true
            phase = .ringing
        }

        /// `AppState.endCall`: the guard, then the part of the teardown this model needs.
        @discardableResult
        func endCall() -> Bool {
            guard let token = teardown.begin() else { return false }
            teardownsRun += 1
            accept.reset()
            isInCall = false
            phase = .idle
            pendingTimers.append(token)
            return true
        }

        /// The 0.3 s `asyncAfter` of the `index`-th teardown.
        func fireTimer(_ index: Int) {
            teardown.release(token: pendingTimers[index])
        }

        /// The gate, then `endOutgoingCallAfterTerminalEnvelope`.
        func terminalEnvelope(_ outcome: CallerTerminalOutcome, callId: String) {
            guard case .endOutgoingCall = accept.terminalEnvelopeArrived(envelopeCallId: callId, phase: phase) else { return }
            let hangupInFlight = teardown.inFlight
            endCall()
            if !hangupInFlight { outcomeShown = outcome }
        }
    }

    /// The reported case: a call ends, the user redials within 0.3 s, and the redial's busy lands inside that same
    /// window. The redial's teardown must run: no zombie `.connecting` call, and the outcome is shown.
    func testARedialWithinTheGuardWindowStillTearsDownOnBusy() {
        let c = Caller()
        c.dial(callA)
        c.endCall()                                   // call A ends (a hangup, or an earlier busy)
        XCTAssertTrue(c.teardown.inFlight, "A's 0.3 s window is open")

        c.dial(callB)                                 // the redial, inside A's window
        XCTAssertFalse(c.teardown.inFlight, "the redial is a new call: A's guard does not apply to it")

        c.terminalEnvelope(.busy, callId: callB)      // its busy, still inside A's window

        XCTAssertFalse(c.isInCall, "no zombie .connecting call")
        XCTAssertEqual(c.phase, .idle)
        XCTAssertEqual(c.teardownsRun, 2, "the redial's own teardown ran")
        XCTAssertEqual(c.outcomeShown, .busy, "and its outcome is shown")
    }

    /// A's timer fires while B's teardown guard is up: B's guard stays up (H-6 for B), then B's own timer opens it.
    func testTheEarlierCallsTimerDoesNotOpenTheRedialsGuard() {
        let c = Caller()
        c.dial(callA)
        c.endCall()                                   // timer 0
        c.dial(callB)
        c.endCall()                                   // timer 1, B's teardown

        c.fireTimer(0)
        XCTAssertTrue(c.teardown.inFlight, "A's timer must not open B's guard early")
        XCTAssertFalse(c.endCall(), "a second teardown of B inside its window is still refused (H-6)")

        c.fireTimer(1)
        XCTAssertFalse(c.teardown.inFlight)
    }

    /// The three dials of the incident (24 s apart, so no overlap): each busy runs its teardown and shows its outcome.
    func testEveryBusyOfConsecutiveDialsRunsItsOwnTeardown() {
        let c = Caller()
        var expected = 0
        for id in [callA, callB, "33333333-3333-4333-8333-333333333333"] {
            c.outcomeShown = nil
            c.dial(id)
            c.terminalEnvelope(.busy, callId: id)
            expected += 1
            XCTAssertEqual(c.teardownsRun, expected)
            XCTAssertEqual(c.outcomeShown, .busy)
            XCTAssertFalse(c.isInCall)
            c.fireTimer(expected - 1)
        }
    }

    /// A local hangup of THIS call is the one that owns its ending: a late busy for it is dropped by the id gate (the
    /// hangup reset the accept latch), runs no second teardown and shows no outcome.
    func testALateBusyForALocallyHungUpCallDoesNothing() {
        let c = Caller()
        c.dial(callA)
        c.endCall()                                   // the user hung up
        c.terminalEnvelope(.busy, callId: callA)

        XCTAssertEqual(c.teardownsRun, 1)
        XCTAssertNil(c.outcomeShown)
    }
}

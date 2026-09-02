import XCTest
@testable import QAudionEngine

/// W-ICEGRACE (2026-07-21) — tests for `iceTerminationAction`, the pure policy
/// behind `AppState.handleIceTermination`.
///
/// Regression coverage for a platform-parity gap live since 2026-05-18: iOS
/// called `endCall()` on the very first ICE `.disconnected` edge with ZERO
/// grace, while Android arms 3000 ms (`DISCONNECT_GRACE_MS`,
/// CallTransportFactory.kt:821) and falls back to the WS relay. Device-verified
/// on call f884668c (2026-07-21, iOS↔Android 1:1 audio): iOS killed the call at
/// 21.9s ~0.3s after Android logged its own "arming 3000ms grace" for the SAME
/// call, which Android then rode out to 85s.
///
/// No WebRTC import needed: the decision is pure, so it runs on the macOS CI
/// runner (`swift test`) without the WebRTC binary.
final class IceTerminationPolicyTests: XCTestCase {

    // THE BUG: a plain `.disconnected` on a live call must NOT end it outright.
    func testDisconnectedOnLiveCallGetsGraceNotImmediateEnd() {
        XCTAssertEqual(
            iceTerminationAction(callIsLive: true, iceIsTerminal: false),
            .endAfterGrace
        )
    }

    // Terminal states stay terminal — the pre-existing protection against a
    // genuinely dead transport leaving the call UI wedged forever must survive.
    func testFailedOrClosedOnLiveCallEndsImmediately() {
        XCTAssertEqual(
            iceTerminationAction(callIsLive: true, iceIsTerminal: true),
            .endImmediately
        )
    }

    // No live call: nothing to tear down, both edges are a no-op (guards the
    // F-1 regression note in handleIceTermination -- .idle/.ended return early).
    func testNoLiveCallIsAlwaysNoop() {
        XCTAssertEqual(
            iceTerminationAction(callIsLive: false, iceIsTerminal: false),
            .none
        )
        XCTAssertEqual(
            iceTerminationAction(callIsLive: false, iceIsTerminal: true),
            .none
        )
    }

    // Explicit statement of the invariant that actually broke the live call:
    // for a live call, a transient edge must never produce the same action as
    // a terminal one.
    func testTransientAndTerminalNeverCollapseToTheSameAction() {
        XCTAssertNotEqual(
            iceTerminationAction(callIsLive: true, iceIsTerminal: false),
            iceTerminationAction(callIsLive: true, iceIsTerminal: true)
        )
    }

    // MARK: - W-ICEGRACEDEGRADE (2026-09-01)

    // The switch ships ON. Flipping it is the documented rollback; every
    // test below pins BOTH branches explicitly so the flip alone is a full
    // revert (no test edit needed).
    func testDegradeSwitchDefaultsOn() {
        XCTAssertTrue(IceTerminationPolicy.iceGraceDegradesToRelay)
    }

    // THE BUG (audit 2026-09-01, P1 item 10): grace ran out while the audio
    // was already riding the WS relay, and iOS hung up on it. With a relay
    // leg the call must stay up, degraded — Android's contract.
    func testGraceExpiryWithRelayDegradesInsteadOfEnding() {
        XCTAssertEqual(
            IceTerminationPolicy.graceExpiryAction(
                callIsLive: true, relayPathAvailable: true, degradeEnabled: true),
            .degradeToRelay
        )
    }

    // No relay leg: the grace still means what it always meant.
    func testGraceExpiryWithoutRelayEndsTheCall() {
        XCTAssertEqual(
            IceTerminationPolicy.graceExpiryAction(
                callIsLive: true, relayPathAvailable: false, degradeEnabled: true),
            .endImmediately
        )
    }

    // Switch off = the pre-2026-09-01 behaviour, relay or not.
    func testGraceExpiryWithSwitchOffAlwaysEnds() {
        XCTAssertEqual(
            IceTerminationPolicy.graceExpiryAction(
                callIsLive: true, relayPathAvailable: true, degradeEnabled: false),
            .endImmediately
        )
    }

    // The call ended normally while the grace was counting: nothing to do,
    // whatever the relay says (guards the liveness re-check at expiry).
    func testGraceExpiryOnDeadCallIsNoop() {
        XCTAssertEqual(
            IceTerminationPolicy.graceExpiryAction(
                callIsLive: false, relayPathAvailable: true, degradeEnabled: true),
            .none
        )
    }

    // ICE `.failed` is restartable (the controller keeps restarting on it) —
    // with a relay leg it degrades, exactly like the grace expiry, so a
    // restart that cannot converge no longer ends the call under the relay.
    func testIceFailedWithRelayDegrades() {
        XCTAssertEqual(
            iceTerminationAction(callIsLive: true, iceIsTerminal: true,
                                 iceRestartable: true, relayPathAvailable: true,
                                 degradeEnabled: true),
            .degradeToRelay
        )
    }

    // ICE `.failed` without a relay leg is still the end of the call.
    func testIceFailedWithoutRelayStillEndsImmediately() {
        XCTAssertEqual(
            iceTerminationAction(callIsLive: true, iceIsTerminal: true,
                                 iceRestartable: true, relayPathAvailable: false,
                                 degradeEnabled: true),
            .endImmediately
        )
    }

    // `.closed` / DTLS failure: no restart can heal it — never degraded, even
    // with a relay leg. The pre-existing "dead transport must not wedge the
    // call UI" protection survives on that edge.
    func testClosedOrDtlsFailureIsNeverDegraded() {
        XCTAssertEqual(
            iceTerminationAction(callIsLive: true, iceIsTerminal: true,
                                 iceRestartable: false, relayPathAvailable: true,
                                 degradeEnabled: true),
            .endImmediately
        )
    }

    // Switch off restores the old terminal contract on the ICE `.failed` edge.
    func testIceFailedWithSwitchOffEndsImmediately() {
        XCTAssertEqual(
            iceTerminationAction(callIsLive: true, iceIsTerminal: true,
                                 iceRestartable: true, relayPathAvailable: true,
                                 degradeEnabled: false),
            .endImmediately
        )
    }

    // A `.disconnected` edge ALWAYS arms the grace, relay or not: the relay
    // question is asked when the grace runs out, not when it is armed.
    func testDisconnectedEdgeArmsGraceRegardlessOfRelay() {
        XCTAssertEqual(
            iceTerminationAction(callIsLive: true, iceIsTerminal: false,
                                 iceRestartable: false, relayPathAvailable: true,
                                 degradeEnabled: true),
            .endAfterGrace
        )
    }

    // No live call: still a no-op on every new input combination.
    func testNoLiveCallIsNoopWithRelayInputs() {
        XCTAssertEqual(
            iceTerminationAction(callIsLive: false, iceIsTerminal: true,
                                 iceRestartable: true, relayPathAvailable: true,
                                 degradeEnabled: true),
            .none
        )
    }

    // A relay leg exists only for an ESTABLISHED call with somewhere to send
    // relay frames: a call still in setup keeps the F-1 rule (ICE dying there
    // ends it — W-MEDIADEAD only measures connected silence).
    func testRelayPathNeedsEstablishedCallAndBoundLeg() {
        XCTAssertTrue(IceTerminationPolicy.relayPathAvailable(callEstablished: true, relayLegBound: true))
        XCTAssertFalse(IceTerminationPolicy.relayPathAvailable(callEstablished: false, relayLegBound: true))
        XCTAssertFalse(IceTerminationPolicy.relayPathAvailable(callEstablished: true, relayLegBound: false))
        XCTAssertFalse(IceTerminationPolicy.relayPathAvailable(callEstablished: false, relayLegBound: false))
    }
}

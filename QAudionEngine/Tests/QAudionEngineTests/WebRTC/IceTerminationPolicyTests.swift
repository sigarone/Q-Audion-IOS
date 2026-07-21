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
}

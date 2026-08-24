import XCTest
@testable import QAudionApp

/// W-FGREAP — pins `evaluateNoCallInFlight`, the pure predicate extracted from
/// `AppState.noCallInFlight()`. That method itself is `private` on a
/// deeply-dependency-injected `@MainActor` class with no lightweight test
/// init, so the four-property gate logic was pulled into a free function
/// specifically so this class of bug (the foreground/teardown reaper tearing
/// down a call CallKit already knows is ringing, because `callState` alone
/// was checked instead of all four properties) has real, running coverage
/// instead of only the manual trace this PR's review relied on.
///
/// NOTE (not yet wired into a build target): this repo has no
/// `QAudionAppTests` XCTest target in `QAudionApp/project.yml` today — see
/// `PeerTrustEvaluatorTests.swift`/`LocalCallerIdSettingsTests.swift` for the
/// same disclosed gap. Written and reasoned through without a local
/// Swift/Xcode toolchain to compile it; wiring the target in is a separate,
/// mechanical `project.yml` change.
final class NoCallInFlightTests: XCTestCase {

    private let someUUID = UUID()

    // MARK: - The "no call at all" baseline

    func test_allClear_returnsTrue() {
        XCTAssertTrue(evaluateNoCallInFlight(
            callState: .idle, activeCallKitId: nil,
            incomingCallRingVisible: false, isInCall: false
        ))
    }

    // MARK: - Each of the four properties independently blocks reaping

    func test_callStateNotIdle_returnsFalse() {
        for state: CallState in [.connecting, .ringing, .active, .encrypted, .ended] {
            XCTAssertFalse(evaluateNoCallInFlight(
                callState: state, activeCallKitId: nil,
                incomingCallRingVisible: false, isInCall: false
            ), "callState \(state) must block reaping")
        }
    }

    func test_activeCallKitIdSet_returnsFalse() {
        XCTAssertFalse(evaluateNoCallInFlight(
            callState: .idle, activeCallKitId: someUUID,
            incomingCallRingVisible: false, isInCall: false
        ))
    }

    func test_incomingCallRingVisible_returnsFalse() {
        XCTAssertFalse(evaluateNoCallInFlight(
            callState: .idle, activeCallKitId: nil,
            incomingCallRingVisible: true, isInCall: false
        ))
    }

    func test_isInCall_returnsFalse() {
        XCTAssertFalse(evaluateNoCallInFlight(
            callState: .idle, activeCallKitId: nil,
            incomingCallRingVisible: false, isInCall: true
        ))
    }

    // MARK: - The exact bug this predicate replaces (W-FGREAP)

    /// The original bug: a call CallKit owns the ring for (PushKit-first, or
    /// backgrounded WS) deliberately leaves `callState == .idle` while it
    /// rings — the old reaper checked `callState == .idle` alone and reaped
    /// a call that was legitimately ringing. This is precisely that state:
    /// idle callState, but a CallKit UUID and the ring flag both live.
    func test_ringingUnderCallKit_callStateIdle_stillBlocksReaping() {
        XCTAssertFalse(evaluateNoCallInFlight(
            callState: .idle, activeCallKitId: someUUID,
            incomingCallRingVisible: true, isInCall: false
        ), "a CallKit-owned ringing call must not be reaped just because callState == .idle")
    }

    /// Answered-but-not-yet-.active: `isInCall` is the property that must
    /// carry this window (callState may already have moved past `.ringing`
    /// depending on where in the accept flow this is asked).
    func test_answeredCall_isInCallTrue_blocksReaping() {
        XCTAssertFalse(evaluateNoCallInFlight(
            callState: .active, activeCallKitId: someUUID,
            incomingCallRingVisible: false, isInCall: true
        ))
    }

    /// A genuinely stale CallKit UUID with no corresponding app-side state
    /// at all — the one case the reaper exists to actually catch.
    func test_orphanedCallKitUUIDWithNoAppState_isNotCaughtByThisPredicate() {
        // Deliberately-named to document a boundary: evaluateNoCallInFlight
        // answers "does THIS app have any call of its own" — it does not
        // itself inspect CallKit's outstanding-call list. A stale UUID that
        // this app never set activeCallKitId/incomingCallRingVisible/isInCall
        // for (e.g. process relaunch losing in-memory state) is exactly the
        // scenario where all four properties are already at rest and the
        // predicate correctly returns true, letting the reaper's own
        // provider.endAllOutstanding() do its job.
        XCTAssertTrue(evaluateNoCallInFlight(
            callState: .idle, activeCallKitId: nil,
            incomingCallRingVisible: false, isInCall: false
        ))
    }
}

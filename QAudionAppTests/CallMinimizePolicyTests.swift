import XCTest
@testable import QAudionApp

/// Reducing a live call to the "call in progress" bar: when the reduce button is offered, which surface is on screen,
/// how the "call reduced" state moves, and how the bar writes the length of the call.
///
/// The views and `AppState` cannot be driven here; `CallMinimizeWiringTests` (engine tests) pins that they use these
/// rules. These tests pin the rules themselves.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-app-tests.yml`.
final class CallMinimizePolicyTests: XCTestCase {

    private let connectedStates: [CallState] = [.active, .encrypted]
    private let notConnectedStates: [CallState] = [.idle, .connecting, .ringing, .ended]

    // MARK: - connected

    func testOnlyActiveAndEncryptedCountAsConnected() {
        for state in connectedStates {
            XCTAssertTrue(CallMinimizePolicy.isConnected(state), "\(state)")
        }
        for state in notConnectedStates {
            XCTAssertFalse(CallMinimizePolicy.isConnected(state), "\(state)")
        }
    }

    // MARK: - the reduce button

    func testTheReduceButtonIsOfferedOnAConnectedAudioCall() {
        for state in connectedStates {
            XCTAssertTrue(
                CallMinimizePolicy.canMinimize(callState: state, isVideoCall: false, remoteScreenSharing: false),
                "\(state)")
        }
    }

    /// Dialling, ringing, closing: the user stays on the call screen.
    func testTheReduceButtonIsNotOfferedBeforeTheCallIsConnected() {
        for state in notConnectedStates {
            XCTAssertFalse(
                CallMinimizePolicy.canMinimize(callState: state, isVideoCall: false, remoteScreenSharing: false),
                "\(state)")
        }
    }

    /// A video call, or a call where the other side shares their screen, has its own screen and is not reduced.
    func testTheReduceButtonIsNotOfferedOnAVideoCallOrAScreenShare() {
        for state in connectedStates {
            XCTAssertFalse(
                CallMinimizePolicy.canMinimize(callState: state, isVideoCall: true, remoteScreenSharing: false),
                "video \(state)")
            XCTAssertFalse(
                CallMinimizePolicy.canMinimize(callState: state, isVideoCall: false, remoteScreenSharing: true),
                "screen share \(state)")
        }
    }

    // MARK: - which surface

    func testTheBarShowsOnlyWithTheCallInProgressReducedAndConnected() {
        for state in connectedStates {
            XCTAssertEqual(
                CallMinimizePolicy.surface(isInCall: true, minimized: true, callState: state), .appWithBar, "\(state)")
        }
    }

    func testAnUnreducedCallStaysOnItsOwnScreen() {
        for state in connectedStates + notConnectedStates {
            XCTAssertEqual(
                CallMinimizePolicy.surface(isInCall: true, minimized: false, callState: state), .callScreen, "\(state)")
        }
    }

    /// If the state leaves "connected" while the call is reduced, the call screen takes its place back: the user is never
    /// left in the app without the bar and without a way to hang up.
    func testTheBarGivesWayToTheCallScreenWhenTheCallIsNotConnected() {
        for state in notConnectedStates {
            XCTAssertEqual(
                CallMinimizePolicy.surface(isInCall: true, minimized: true, callState: state), .callScreen, "\(state)")
        }
    }

    /// No call, no bar, whatever a stale flag says.
    func testNoCallMeansNoBar() {
        for state in connectedStates + notConnectedStates {
            XCTAssertEqual(
                CallMinimizePolicy.surface(isInCall: false, minimized: true, callState: state), .callScreen, "\(state)")
        }
    }

    // MARK: - reduced / back

    func testReduceTapReducesTheCallWhenItCanBeReduced() {
        XCTAssertTrue(CallMinimizePolicy.next(minimized: false, event: .reduceTapped, canMinimize: true))
    }

    /// The state may have changed between drawing the button and the tap: the tap then does nothing.
    func testReduceTapIsIgnoredWhenTheCallCannotBeReducedAnyMore() {
        XCTAssertFalse(CallMinimizePolicy.next(minimized: false, event: .reduceTapped, canMinimize: false))
        XCTAssertTrue(CallMinimizePolicy.next(minimized: true, event: .reduceTapped, canMinimize: false),
                      "an already reduced call is left as it is")
    }

    func testTheBarTapBringsTheCallScreenBack() {
        XCTAssertFalse(CallMinimizePolicy.next(minimized: true, event: .barTapped, canMinimize: true))
        XCTAssertFalse(CallMinimizePolicy.next(minimized: true, event: .barTapped, canMinimize: false))
        XCTAssertFalse(CallMinimizePolicy.next(minimized: false, event: .barTapped, canMinimize: true))
    }

    /// A call never starts reduced and never stays reduced once it is over.
    func testTheBoundariesOfACallClearTheReducedState() {
        XCTAssertFalse(CallMinimizePolicy.next(minimized: true, event: .callBoundary, canMinimize: true))
        XCTAssertFalse(CallMinimizePolicy.next(minimized: true, event: .callBoundary, canMinimize: false))
        XCTAssertFalse(CallMinimizePolicy.next(minimized: false, event: .callBoundary, canMinimize: true))
    }

    /// A whole call: reduce, back, reduce again, the call ends.
    func testAReduceBackReduceEndSequence() {
        var minimized = false
        minimized = CallMinimizePolicy.next(minimized: minimized, event: .reduceTapped, canMinimize: true)
        XCTAssertTrue(minimized)
        minimized = CallMinimizePolicy.next(minimized: minimized, event: .barTapped, canMinimize: true)
        XCTAssertFalse(minimized)
        minimized = CallMinimizePolicy.next(minimized: minimized, event: .reduceTapped, canMinimize: true)
        XCTAssertTrue(minimized)
        minimized = CallMinimizePolicy.next(minimized: minimized, event: .callBoundary, canMinimize: false)
        XCTAssertFalse(minimized)
    }

    // MARK: - the length of the call

    func testElapsedTextIsMinutesAndSecondsBelowOneHour() {
        XCTAssertEqual(CallElapsedText.format(seconds: 0), "0:00")
        XCTAssertEqual(CallElapsedText.format(seconds: 9), "0:09")
        XCTAssertEqual(CallElapsedText.format(seconds: 65), "1:05")
        XCTAssertEqual(CallElapsedText.format(seconds: 600), "10:00")
        XCTAssertEqual(CallElapsedText.format(seconds: 3599), "59:59")
    }

    func testElapsedTextIsHoursMinutesAndSecondsFromOneHour() {
        XCTAssertEqual(CallElapsedText.format(seconds: 3600), "1:00:00")
        XCTAssertEqual(CallElapsedText.format(seconds: 3661), "1:01:01")
        XCTAssertEqual(CallElapsedText.format(seconds: 7384), "2:03:04")
        XCTAssertEqual(CallElapsedText.format(seconds: 36000), "10:00:00")
    }

    /// Whole seconds, cut (not rounded): 59.9 s is still 0:59.
    func testElapsedTextCutsTheFraction() {
        XCTAssertEqual(CallElapsedText.format(seconds: 0.999), "0:00")
        XCTAssertEqual(CallElapsedText.format(seconds: 59.9), "0:59")
        XCTAssertEqual(CallElapsedText.format(seconds: 3599.99), "59:59")
    }

    func testElapsedTextNeverShowsANegativeOrBrokenTime() {
        XCTAssertEqual(CallElapsedText.format(seconds: -5), "0:00")
        XCTAssertEqual(CallElapsedText.format(seconds: -0.0), "0:00")
        XCTAssertEqual(CallElapsedText.format(seconds: .nan), "0:00")
        XCTAssertEqual(CallElapsedText.format(seconds: .infinity), "0:00")
        XCTAssertEqual(CallElapsedText.format(seconds: -.infinity), "0:00")
    }

    /// An absurd value is capped, never a crash.
    func testElapsedTextSurvivesAnAbsurdValue() {
        XCTAssertEqual(CallElapsedText.format(seconds: 1e30), "277777:46:40")
    }

    // MARK: - Reduce Motion

    func testNoAnimationWithReduceMotionOn() {
        XCTAssertNil(CallMinimizeAnimation.animation(reduceMotion: true))
        XCTAssertNotNil(CallMinimizeAnimation.animation(reduceMotion: false))
    }
}

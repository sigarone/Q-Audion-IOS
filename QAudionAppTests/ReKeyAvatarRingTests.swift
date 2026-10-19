import XCTest
@testable import QAudionApp

/// The re-key countdown drawn as a ring around the avatar of the call screen. The decisions live in
/// `ReKeyRingModel` as pure functions (seconds in, arc share and pill text out), so the clamping, the
/// "no timer" case and the text are pinned here without any UI.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the
/// `-only-testing` list of `.github/workflows/ios-app-tests.yml`.
final class ReKeyAvatarRingTests: XCTestCase {

    // MARK: - Arc share

    func testTheArcIsFullAtTheStartOfThePeriodAndEmptyAtZero() {
        XCTAssertEqual(ReKeyRingModel.state(remainingSeconds: 300, totalSeconds: 300, isReKeying: false).fraction, 1)
        XCTAssertEqual(ReKeyRingModel.state(remainingSeconds: 0, totalSeconds: 300, isReKeying: false).fraction, 0)
    }

    func testTheArcIsTheRemainingShareOfThePeriod() {
        let state = ReKeyRingModel.state(remainingSeconds: 117, totalSeconds: 300, isReKeying: false)
        XCTAssertEqual(state.fraction, 117.0 / 300.0, accuracy: 1e-9)
        // A shorter period (low confidence shrinks it) is a share of THAT period, not of five minutes.
        let shorter = ReKeyRingModel.state(remainingSeconds: 30, totalSeconds: 60, isReKeying: false)
        XCTAssertEqual(shorter.fraction, 0.5, accuracy: 1e-9)
    }

    func testTheArcOnlyEverShrinksAsTimePasses() {
        let shares = (0...5).reversed().map {
            ReKeyRingModel.state(remainingSeconds: $0 * 60, totalSeconds: 300, isReKeying: false).fraction
        }
        XCTAssertEqual(shares, shares.sorted(by: >), "less time left must never draw a longer arc")
        XCTAssertEqual(Set(shares).count, shares.count, "every second count draws a different arc")
    }

    func testAValueOutsideThePeriodIsClamped() {
        XCTAssertEqual(ReKeyRingModel.state(remainingSeconds: 450, totalSeconds: 300, isReKeying: false).fraction, 1)
        XCTAssertEqual(ReKeyRingModel.state(remainingSeconds: -12, totalSeconds: 300, isReKeying: false).fraction, 0)
        // The pill reads the clamped value too, never a number the ring cannot show.
        XCTAssertEqual(ReKeyRingModel.state(remainingSeconds: 450, totalSeconds: 300, isReKeying: false).secondsLeft, 300)
        XCTAssertEqual(ReKeyRingModel.state(remainingSeconds: -12, totalSeconds: 300, isReKeying: false).secondsLeft, 0)
    }

    // MARK: - Pill

    func testThePillReadsTheSecondsLeft() {
        XCTAssertEqual(ReKeyRingModel.state(remainingSeconds: 117, totalSeconds: 300, isReKeying: false).label, "RE-KEY 117s")
        XCTAssertEqual(ReKeyRingModel.state(remainingSeconds: 1, totalSeconds: 300, isReKeying: false).label, "RE-KEY 1s")
        XCTAssertEqual(ReKeyRingModel.state(remainingSeconds: 0, totalSeconds: 300, isReKeying: false).label, "RE-KEY 0s")
        XCTAssertEqual(ReKeyRingModel.state(remainingSeconds: 117, totalSeconds: 300, isReKeying: false).secondsLeft, 117)
    }

    func testWithoutATimerThereIsNoPillAndNoArc() {
        for total in [0, -1, -300] {
            let state = ReKeyRingModel.state(remainingSeconds: 117, totalSeconds: total, isReKeying: false)
            XCTAssertNil(state.label, "total \(total)")
            XCTAssertNil(state.secondsLeft, "total \(total)")
            XCTAssertEqual(state.fraction, 0, "total \(total)")
        }
        // Not connected: nothing to count down to, whatever else the call is doing.
        XCTAssertNil(ReKeyRingModel.state(remainingSeconds: 0, totalSeconds: 0, isReKeying: true).label)
    }

    // MARK: - Re-key in progress

    func testWhileAReKeyRunsTheRingIsFullWithAPlainPill() {
        let running = ReKeyRingModel.state(remainingSeconds: 3, totalSeconds: 300, isReKeying: true)
        XCTAssertEqual(running.fraction, 1)
        XCTAssertEqual(running.label, "RE-KEY")
        XCTAssertNil(running.secondsLeft, "no seconds are announced while the round is running")
        // The same inputs once the round is over go back to counting.
        let over = ReKeyRingModel.state(remainingSeconds: 3, totalSeconds: 300, isReKeying: false)
        XCTAssertEqual(over.label, "RE-KEY 3s")
        XCTAssertLessThan(over.fraction, 1)
    }

    // MARK: - Seconds from the scheduler's milliseconds

    func testMillisecondsAreRoundedUpToWholeSeconds() {
        XCTAssertEqual(ReKeyRingModel.wholeSeconds(milliseconds: 300_000), 300)
        XCTAssertEqual(ReKeyRingModel.wholeSeconds(milliseconds: 299_001), 300)
        XCTAssertEqual(ReKeyRingModel.wholeSeconds(milliseconds: 1_001), 2)
        XCTAssertEqual(ReKeyRingModel.wholeSeconds(milliseconds: 1_000), 1)
        // Time left never reads as "0s" until it really is zero.
        XCTAssertEqual(ReKeyRingModel.wholeSeconds(milliseconds: 1), 1)
        XCTAssertEqual(ReKeyRingModel.wholeSeconds(milliseconds: 0), 0)
        XCTAssertEqual(ReKeyRingModel.wholeSeconds(milliseconds: -250), 0)
    }
}

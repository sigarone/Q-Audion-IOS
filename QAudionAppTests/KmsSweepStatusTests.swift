import XCTest
@testable import QAudionApp

/// The status line of the KMS row in Key management (`KmsSweepStatus`): idle until a sweep finishes, running while
/// any sweep runs (the periodic one, the one a server event starts and the one "Aggiorna" starts can overlap), then
/// the outcome and the time of the last sweep.
///
/// Pure: no network and no Keychain. Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in
/// the `-only-testing` list of `.github/workflows/ios-app-tests.yml`.
@MainActor
final class KmsSweepStatusTests: XCTestCase {

    func testNothingHasRunYet() {
        let status = KmsSweepStatus()
        XCTAssertEqual(status.state, .idle)
        XCTAssertFalse(status.isRunning)
    }

    func testASweepIsRunningUntilItFinishesThenShowsItsOutcome() {
        let status = KmsSweepStatus()
        let finished = Date(timeIntervalSince1970: 1_000)

        status.sweepStarted()
        XCTAssertEqual(status.state, .running)
        XCTAssertTrue(status.isRunning)

        status.sweepFinished(succeeded: true, at: finished)
        XCTAssertEqual(status.state, .succeeded(at: finished))
        XCTAssertFalse(status.isRunning)
    }

    func testAFailedSweepShowsAsFailedWithItsTime() {
        let status = KmsSweepStatus()
        let finished = Date(timeIntervalSince1970: 2_000)

        status.sweepStarted()
        status.sweepFinished(succeeded: false, at: finished)
        XCTAssertEqual(status.state, .failed(at: finished))
    }

    func testOverlappingSweepsKeepTheStateRunningUntilTheLastOneEnds() {
        let status = KmsSweepStatus()
        let first = Date(timeIntervalSince1970: 3_000)
        let second = Date(timeIntervalSince1970: 3_005)

        status.sweepStarted()
        status.sweepStarted()
        status.sweepFinished(succeeded: true, at: first)
        XCTAssertEqual(status.state, .running, "one sweep is still running")

        status.sweepFinished(succeeded: false, at: second)
        XCTAssertEqual(status.state, .failed(at: second), "the last sweep to end decides")
    }

    func testAFinishWithoutAStartNeverLeavesTheStateRunning() {
        let status = KmsSweepStatus()
        let finished = Date(timeIntervalSince1970: 4_000)
        status.sweepFinished(succeeded: true, at: finished)
        XCTAssertFalse(status.isRunning)
        XCTAssertEqual(status.state, .succeeded(at: finished))
    }

    func testANewSweepShowsAsRunningAfterAnEarlierOutcome() {
        let status = KmsSweepStatus()
        status.sweepStarted()
        status.sweepFinished(succeeded: true, at: Date(timeIntervalSince1970: 5_000))
        status.sweepStarted()
        XCTAssertEqual(status.state, .running)
    }
}

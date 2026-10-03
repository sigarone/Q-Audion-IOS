import XCTest
@testable import QAudionEngine

/// The group call clock sat at 0:00 for the whole call (iPhone 1.0.1205): it was scheduled from
/// the manager's WebSocket thread, which has no running run loop, and restarted by every
/// `.active` roster update.
final class GroupCallElapsedTimerTests: XCTestCase {

    func testFormat() {
        XCTAssertEqual(GroupCallElapsedTimer.format(seconds: 0), "0:00")
        XCTAssertEqual(GroupCallElapsedTimer.format(seconds: 9), "0:09")
        XCTAssertEqual(GroupCallElapsedTimer.format(seconds: 61), "1:01")
        XCTAssertEqual(GroupCallElapsedTimer.format(seconds: 3_725), "62:05")
        XCTAssertEqual(GroupCallElapsedTimer.format(seconds: -4), "0:00")
    }

    /// The bug: started from a background thread, the clock never fired.
    func testStartedFromABackgroundThreadStillTicks() {
        let timer = GroupCallElapsedTimer()
        let ticked = expectation(description: "the clock moved past 0:00")
        ticked.assertForOverFulfill = false
        timer.onChange = { text in if text != "0:00" { ticked.fulfill() } }
        DispatchQueue.global(qos: .utility).async { timer.start() }
        wait(for: [ticked], timeout: 5)
        timer.stop()
    }

    /// Every `.active` roster update calls `start()` again: that must not restart the clock.
    func testARepeatedStartDoesNotRestartTheClock() {
        let timer = GroupCallElapsedTimer()
        let lock = NSLock()
        var seen: [String] = []
        let reachedTwo = expectation(description: "0:02 reached")
        reachedTwo.assertForOverFulfill = false
        timer.onChange = { text in
            lock.lock(); seen.append(text); lock.unlock()
            if text == "0:02" { reachedTwo.fulfill() }
        }
        timer.start()
        let again = expectation(description: "second start")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            DispatchQueue.global().async { timer.start() }
            again.fulfill()
        }
        wait(for: [again, reachedTwo], timeout: 6)
        timer.stop()
        lock.lock(); defer { lock.unlock() }
        // stop()'s own "0:00" is delivered after this test body returns (main queue), so any
        // "0:00" here would be a restart.
        XCTAssertFalse(seen.contains("0:00"), "a restart would show 0:00 again: \(seen)")
    }

    func testStopShowsZeroAndStartWorksAgain() {
        let timer = GroupCallElapsedTimer()
        let stopped = expectation(description: "stopped shows 0:00")
        stopped.assertForOverFulfill = false
        timer.onChange = { text in if text == "0:00" { stopped.fulfill() } }
        timer.start()
        timer.stop()
        wait(for: [stopped], timeout: 3)
        let runs = expectation(description: "running again")
        DispatchQueue.main.async {
            XCTAssertFalse(timer.isRunning)
            timer.start()
            DispatchQueue.main.async {
                XCTAssertTrue(timer.isRunning)
                timer.stop()
                runs.fulfill()
            }
        }
        wait(for: [runs], timeout: 3)
    }
}

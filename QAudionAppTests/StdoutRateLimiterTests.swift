import XCTest
@testable import QAudionApp

/// The stdout/stderr tee caps repeated native lines: one line per key and window, plus one summary per window.
final class StdoutRateLimiterTests: XCTestCase {

    private let glitch = "(audio_device_ios.mm:517): Possible playout audio glitch detected."

    func test_digitsDoNotMakeTwoLinesDifferentKeys() {
        XCTAssertEqual(StdoutTeeLines.RateLimiter.normalizedKey("Number of detected playout glitches: 17"),
                       StdoutTeeLines.RateLimiter.normalizedKey("Number of detected playout glitches: 4821"))
        XCTAssertNotEqual(StdoutTeeLines.RateLimiter.normalizedKey("glitches: 1"),
                          StdoutTeeLines.RateLimiter.normalizedKey("underruns: 1"))
    }

    func test_theLastNumberOfALine() {
        XCTAssertEqual(StdoutTeeLines.RateLimiter.lastNumber(in: "Time since last OnGetPlayoutData was 23 ms."), 23)
        XCTAssertEqual(StdoutTeeLines.RateLimiter.lastNumber(in: "glitches: 4821"), 4821)
        XCTAssertNil(StdoutTeeLines.RateLimiter.lastNumber(in: "no digits here"))
    }

    func test_aBurstOfTheSameLinePassesOnceAndIsSummarisedWhenTheWindowEnds() {
        let limiter = StdoutTeeLines.RateLimiter()
        var out: [String] = []
        for i in 0..<58 {
            out += limiter.admit("Time since last OnGetPlayoutData was \(20 + i % 7) ms.", now: 100 + Double(i) * 0.016)
        }
        XCTAssertEqual(out.count, 1, "only the first line of the window passes")
        let next = limiter.admit("Time since last OnGetPlayoutData was 9 ms.", now: 101.5)
        XCTAssertEqual(next.count, 2, "the summary of the closed window, then the first line of the new one")
        XCTAssertTrue(next[0].hasPrefix("[repeated x57]"), next[0])
        XCTAssertTrue(next[0].contains("max=26"), next[0])
        XCTAssertTrue(next[0].contains("Time since last OnGetPlayoutData was #"), next[0])
        XCTAssertEqual(next[1], "Time since last OnGetPlayoutData was 9 ms.")
    }

    func test_theSummaryOfAQuietKeyIsFlushedByAnyLaterLine() {
        let limiter = StdoutTeeLines.RateLimiter()
        _ = limiter.admit(glitch, now: 10)
        _ = limiter.admit(glitch, now: 10.2)
        let out = limiter.admit("something else entirely", now: 12)
        XCTAssertEqual(out.count, 2)
        XCTAssertTrue(out[0].hasPrefix("[repeated x1]"), out[0])
        XCTAssertEqual(out[1], "something else entirely")
    }

    func test_distinctLinesAreNeverCut() {
        let limiter = StdoutTeeLines.RateLimiter()
        let lines = ["alpha one", "beta two", "gamma three", "delta four"]
        let out = lines.flatMap { limiter.admit($0, now: 5) }
        XCTAssertEqual(out, lines)
    }

    func test_aTaggedAppLineAlwaysPasses() {
        let limiter = StdoutTeeLines.RateLimiter()
        let line = "[call] audiosrtp hb tx=10 rx=9"
        let out = (0..<20).flatMap { limiter.admit(line, now: 7 + Double($0) * 0.01) }
        XCTAssertEqual(out.count, 20)
    }

    func test_errorLinesDifferingOnlyInDigitsAreNeverCollapsed() {
        let limiter = StdoutTeeLines.RateLimiter()
        XCTAssertEqual(limiter.admit("ERROR something failed, code 5", now: 3), ["ERROR something failed, code 5"])
        XCTAssertEqual(limiter.admit("ERROR something failed, code 7", now: 3.1), ["ERROR something failed, code 7"])
    }

    func test_theNumberOfTrackedKeysIsBounded() {
        let limiter = StdoutTeeLines.RateLimiter()
        let maxKeys = StdoutTeeLines.RateLimiter.maxKeys
        func word(_ i: Int) -> String {
            // Distinct non-digit text so every line is its own key.
            String(UnicodeScalar(UInt8(65 + i % 26))) + String(repeating: "z", count: i / 26 + 1)
        }
        var passed = 0
        for i in 0..<(maxKeys + 40) {
            passed += limiter.admit(word(i), now: 1).count
        }
        XCTAssertEqual(passed, maxKeys + 40, "an untracked line is let through, never dropped")
        XCTAssertLessThanOrEqual(limiter.trackedKeyCount, maxKeys)
        // The table is full: a repeated line of a key that is NOT tracked passes every time ...
        let untracked = word(maxKeys + 10)
        XCTAssertEqual((0..<5).flatMap { limiter.admit(untracked, now: 1.1 + Double($0) * 0.01) }.count, 5)
        // ... while a repeated line of a tracked key is suppressed.
        let tracked = word(0)
        XCTAssertEqual((0..<5).flatMap { limiter.admit(tracked, now: 1.2 + Double($0) * 0.01) }.count, 0)
        XCTAssertLessThanOrEqual(limiter.trackedKeyCount, maxKeys)
    }

    func test_summariesEndingTogetherAreOrderedByTheirWindowStart() {
        let limiter = StdoutTeeLines.RateLimiter()
        _ = limiter.admit("zeta line", now: 10)
        _ = limiter.admit("alpha line", now: 10.3)
        _ = limiter.admit("zeta line", now: 10.4)
        _ = limiter.admit("alpha line", now: 10.5)
        let out = limiter.admit("something else", now: 12)
        XCTAssertEqual(out.count, 3)
        XCTAssertTrue(out[0].contains("zeta line"), out[0])
        XCTAssertTrue(out[1].contains("alpha line"), out[1])
    }

    func test_aPendingSummaryIsFlushedByTheTimerWhenNoLaterLineArrives() {
        let queue = DispatchQueue(label: "test.stdout-limiter")
        let flushed = expectation(description: "summary flushed")
        let lock = NSLock()
        var received: [String] = []
        let limiter = StdoutTeeLines.RateLimiter(queue: queue) { lines in
            lock.lock(); received += lines; lock.unlock()
            flushed.fulfill()
        }
        queue.sync {
            let now = ProcessInfo.processInfo.systemUptime
            _ = limiter.admit(glitch, now: now)
            _ = limiter.admit(glitch, now: now + 0.01)
        }
        wait(for: [flushed], timeout: 5)
        queue.sync { limiter.stop() }
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(received.count, 1)
        XCTAssertTrue(received.first?.hasPrefix("[repeated x1]") ?? false, received.first ?? "")
    }
}

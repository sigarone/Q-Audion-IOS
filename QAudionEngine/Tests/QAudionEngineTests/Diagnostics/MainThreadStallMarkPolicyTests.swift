import XCTest
@testable import QAudionEngine

final class MainThreadStallMarkPolicyTests: XCTestCase {

    func test_marksOnceTheUnansweredPingIsOldEnough() {
        XCTAssertFalse(MainThreadStallMarkPolicy.shouldMarkStart(pingAgeMs: 999, alreadyMarked: false, thresholdMs: 1000))
        XCTAssertTrue(MainThreadStallMarkPolicy.shouldMarkStart(pingAgeMs: 1000, alreadyMarked: false, thresholdMs: 1000))
        XCTAssertTrue(MainThreadStallMarkPolicy.shouldMarkStart(pingAgeMs: 30_000, alreadyMarked: false, thresholdMs: 1000))
    }

    func test_marksOncePerPing() {
        XCTAssertFalse(MainThreadStallMarkPolicy.shouldMarkStart(pingAgeMs: 5_000, alreadyMarked: true, thresholdMs: 1000))
    }
}

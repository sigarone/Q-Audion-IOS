import XCTest

/// Source invariant of `AudioCapture.fireVpioRetry` (the class cannot be built without an audio session): a fire that finds
/// the hardware not ready, or a group call on VP-IO, uses no attempt (the attempt counter moves after the skip check), has a
/// budget of its own, and stops re-arming once that budget is spent, writing the existing stop line once.
final class VpioRetrySkipWiringTests: XCTestCase {

    private func fireVpioRetryBody(file: StaticString = #filePath) throws -> String {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent("QAudionEngine/Sources/QAudionEngine/Audio/AudioCapture.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let raw = try String(contentsOf: candidate, encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n")
                let start = try XCTUnwrap(raw.range(of: "private func fireVpioRetry() {"))
                let rest = raw[start.upperBound...]
                let end = try XCTUnwrap(rest.range(of: "/// W574o"))
                return String(rest[rest.startIndex..<end.lowerBound])
            }
        }
        throw NSError(domain: "VpioRetrySkipWiringTests", code: 1)
    }

    func testTheAttemptIsCountedAfterTheSkipCheck() throws {
        let body = try fireVpioRetryBody()
        let skipCheck = try XCTUnwrap(body.range(of: "if !inputReady || isGroupCallActive?() == true {"))
        let increment = try XCTUnwrap(body.range(of: "vpioRetryAttempt += 1"))
        XCTAssertLessThan(skipCheck.lowerBound, increment.lowerBound, "a skip must not burn the retry budget")
        XCTAssertEqual(body.components(separatedBy: "vpioRetryAttempt += 1").count - 1, 1)
    }

    func testASkipHasABudgetAndTheStopLineIsWrittenOnce() throws {
        let body = try fireVpioRetryBody()
        let skipBlock = try XCTUnwrap(body.range(of: "vpioRetrySkips += 1"))
        let tail = String(body[skipBlock.lowerBound...])
        XCTAssertTrue(tail.contains("VpioRetryPolicy.hasSkipBudget(skipsMade: vpioRetrySkips)"))
        XCTAssertTrue(tail.contains("} else if !vpioRetryGaveUp {"), "the stop line only once")
        XCTAssertTrue(tail.contains("result: .stop"))
        // the re-arm sits under the budget check, never unconditionally
        let budget = try XCTUnwrap(tail.range(of: "hasSkipBudget"))
        let arm = try XCTUnwrap(tail.range(of: "armVpioRetryTimer()"))
        XCTAssertLessThan(budget.lowerBound, arm.lowerBound)
    }
}

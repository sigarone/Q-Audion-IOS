import XCTest
@testable import QAudionEngine

final class ConfidenceIndexTests: XCTestCase {
    func testInitialScore() {
        let ci = ConfidenceIndex()
        XCTAssertEqual(ci.currentScore, 0.5, accuracy: 0.01)
    }

    func testUpdateGreen() {
        let ci = ConfidenceIndex()
        for _ in 0..<50 { _ = ci.update(0.95) }
        XCTAssertEqual(ci.currentLevel, .green)
        XCTAssertGreaterThan(ci.currentScore, 0.8)
    }

    func testUpdateRed() {
        let ci = ConfidenceIndex()
        for _ in 0..<50 { _ = ci.update(0.1) }
        XCTAssertEqual(ci.currentLevel, .red)
        XCTAssertLessThan(ci.currentScore, 0.5)
    }

    func testReset() {
        let ci = ConfidenceIndex()
        for _ in 0..<10 { _ = ci.update(0.1) }
        ci.reset()
        XCTAssertEqual(ci.currentScore, 0.5, accuracy: 0.01)
        XCTAssertTrue(ci.scoreHistory.isEmpty)
    }

    func testHistory() {
        let ci = ConfidenceIndex()
        _ = ci.update(0.8)
        _ = ci.update(0.9)
        XCTAssertEqual(ci.scoreHistory.count, 2)
    }
}

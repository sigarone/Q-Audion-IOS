import XCTest
@testable import QAudionEngine

final class EngineStatsTests: XCTestCase {
    func testThreatLevel() {
        var stats = EngineStats()
        stats.avgDeepfakeConfidence = 0.9
        XCTAssertEqual(stats.threatLevel, .safe)
        stats.avgDeepfakeConfidence = 0.6
        XCTAssertEqual(stats.threatLevel, .uncertain)
        stats.avgDeepfakeConfidence = 0.4
        XCTAssertEqual(stats.threatLevel, .suspicious)
        stats.avgDeepfakeConfidence = 0.1
        XCTAssertEqual(stats.threatLevel, .critical)
    }

    func testFrameRate() {
        var stats = EngineStats()
        stats.framesTx = 500
        stats.sessionDurationMs = 10000  // 10 seconds
        XCTAssertEqual(stats.calculateFrameRate(), 50.0, accuracy: 0.1)
    }

    func testPerformanceHealthy() {
        var stats = EngineStats()
        stats.avgEncryptionMs = 1.0
        stats.avgDecryptionMs = 1.0
        XCTAssertTrue(stats.isPerformanceHealthy())
        stats.avgEncryptionMs = 10.0
        XCTAssertFalse(stats.isPerformanceHealthy())
    }
}

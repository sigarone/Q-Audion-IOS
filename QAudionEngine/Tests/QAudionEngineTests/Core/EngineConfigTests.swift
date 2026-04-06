import XCTest
@testable import QAudionEngine

final class EngineConfigTests: XCTestCase {
    func testProductionPreset() {
        let c = EngineConfig.production()
        XCTAssertTrue(c.enableOpusCodec)
        XCTAssertTrue(c.enableGuardianMode)
        XCTAssertEqual(c.sampleRate, 48000)
        XCTAssertEqual(c.opusBitrate, 32000)
        XCTAssertTrue(c.isValid())
    }
    func testDevelopmentPreset() {
        let c = EngineConfig.development()
        XCTAssertTrue(c.enableLogging)
        XCTAssertEqual(c.transportMode, .loopback)
    }
    func testValidation() {
        var c = EngineConfig()
        c.sampleRate = 44100
        XCTAssertFalse(c.isValid())
        XCTAssertTrue(c.getValidationErrors().contains("sampleRate must be 48000"))
    }
    func testBatteryOptimized() {
        let c = EngineConfig.batteryOptimized()
        XCTAssertFalse(c.enableGuardianMode)
        XCTAssertFalse(c.enableVoiceAnalysis)
    }
}

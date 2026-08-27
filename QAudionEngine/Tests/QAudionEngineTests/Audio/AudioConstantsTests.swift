import XCTest
@testable import QAudionEngine

final class AudioConstantsTests: XCTestCase {
    func testSampleRate() { XCTAssertEqual(AudioConstants.sampleRate, 48000) }
    func testFrameDuration() { XCTAssertEqual(AudioConstants.frameDurationMs, 20) }
    func testSamplesPerFrame() { XCTAssertEqual(AudioConstants.samplesPerFrame, 960) }
    func testBytesPerFrame() { XCTAssertEqual(AudioConstants.bytesPerFrame, 1920) }
    // W-OPUSHEADROOM (2026-08-27): raised 32000 -> 40000. See AudioProfileTests
    // for the clamp coverage that makes this safe against the long profile.
    func testOpusBitrate() { XCTAssertEqual(AudioConstants.opusBitrate, 40000) }
    func testJitterBufferCapacities() {
        XCTAssertEqual(AudioConstants.jitterBufferFramesP2P, 3)
        XCTAssertEqual(AudioConstants.jitterBufferFramesWsRelay, 8)
        XCTAssertEqual(AudioConstants.jitterBufferFramesSignalRelay, 150)
    }
}

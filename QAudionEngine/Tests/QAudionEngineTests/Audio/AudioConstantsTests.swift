import XCTest
@testable import QAudionEngine

final class AudioConstantsTests: XCTestCase {
    func testSampleRate() { XCTAssertEqual(AudioConstants.sampleRate, 48000) }
    func testFrameDuration() { XCTAssertEqual(AudioConstants.frameDurationMs, 20) }
    func testSamplesPerFrame() { XCTAssertEqual(AudioConstants.samplesPerFrame, 960) }
    func testBytesPerFrame() { XCTAssertEqual(AudioConstants.bytesPerFrame, 1920) }
    func testOpusBitrate() { XCTAssertEqual(AudioConstants.opusBitrate, 32000) }
    func testJitterBufferCapacities() {
        XCTAssertEqual(AudioConstants.jitterBufferFramesP2P, 3)
        XCTAssertEqual(AudioConstants.jitterBufferFramesWsRelay, 8)
        XCTAssertEqual(AudioConstants.jitterBufferFramesSignalRelay, 150)
    }
}

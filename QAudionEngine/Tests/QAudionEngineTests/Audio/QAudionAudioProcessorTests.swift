import XCTest
@testable import QAudionEngine

final class QAudionAudioProcessorTests: XCTestCase {
    func testProcessOutgoing() {
        let proc = QAudionAudioProcessor()
        let pcm = Data(repeating: 0x10, count: AudioConstants.bytesPerFrame)
        let encoded = proc.processOutgoing(pcmFrame: pcm)
        XCTAssertNotNil(encoded)
    }

    func testProcessIncoming() {
        let proc = QAudionAudioProcessor()
        let pcm = Data(repeating: 0x10, count: AudioConstants.bytesPerFrame)
        // Safe: pcm is fixed-size (bytesPerFrame) and proc is unmuted, so
        // processOutgoing() always returns non-nil (delegates to encode()).
        // swiftlint:disable:next force_unwrapping
        let encoded = proc.processOutgoing(pcmFrame: pcm)!
        let decoded = proc.processIncoming(opusFrame: encoded)
        XCTAssertNotNil(decoded)
    }

    func testMute() {
        let proc = QAudionAudioProcessor()
        proc.setMuted(true)
        XCTAssertTrue(proc.muted)
        let pcm = Data(repeating: 0x10, count: AudioConstants.bytesPerFrame)
        let encoded = proc.processOutgoing(pcmFrame: pcm)
        XCTAssertNotNil(encoded) // Should produce comfort noise
    }

    func testCallbacks() {
        let proc = QAudionAudioProcessor()
        var gotRawPcm = false
        var gotEncoded = false
        proc.onRawPcmFrame = { _ in gotRawPcm = true }
        proc.onEncodedFrame = { _ in gotEncoded = true }
        let pcm = Data(repeating: 0, count: AudioConstants.bytesPerFrame)
        _ = proc.processOutgoing(pcmFrame: pcm)
        XCTAssertTrue(gotRawPcm)
        XCTAssertTrue(gotEncoded)
    }
}

import XCTest
@testable import QAudionEngine

final class GuardianModeTests: XCTestCase {
    func testProcessFrame() {
        let guardian = GuardianMode()
        let pcm = Data(repeating: 0, count: AudioConstants.bytesPerFrame)
        // Should not crash
        for _ in 0..<20 { guardian.processFrame(pcm) }
    }

    func testDisable() {
        let guardian = GuardianMode()
        guardian.setEnabled(false)
        XCTAssertFalse(guardian.isEnabled)
    }

    func testConfidenceIndex() {
        let guardian = GuardianMode()
        let ci = guardian.getConfidenceIndex()
        XCTAssertEqual(ci.currentScore, 0.5, accuracy: 0.01)
    }
}

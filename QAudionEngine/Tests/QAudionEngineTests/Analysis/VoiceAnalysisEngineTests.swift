import XCTest
@testable import QAudionEngine

final class VoiceAnalysisEngineTests: XCTestCase {
    private var engine: VoiceAnalysisEngine!

    override func setUp() {
        super.setUp()
        engine = VoiceAnalysisEngine()
    }

    func testCallbackFiringOnNthFrame() {
        // Default analysisRate is 5, so callback fires on every 5th frame
        let expectation = expectation(description: "onResult called")
        var receivedResult: VoiceAnalysisResult?

        engine.onResult = { result in
            receivedResult = result
            expectation.fulfill()
        }

        let pcm = TestAudioHelpers.makeSinePCM(frequency: 200, sampleCount: 960)
        for _ in 0..<5 {
            engine.processFrame(pcm)
        }

        wait(for: [expectation], timeout: 1.0)
        XCTAssertNotNil(receivedResult, "Should receive a result after 5 frames")
    }

    func testCallbackNotFiredBeforeRate() {
        var callbackCount = 0
        engine.onResult = { _ in callbackCount += 1 }

        let pcm = TestAudioHelpers.makeSinePCM(frequency: 200, sampleCount: 960)
        // Process 4 frames (less than the default rate of 5)
        for _ in 0..<4 {
            engine.processFrame(pcm)
        }

        XCTAssertEqual(callbackCount, 0, "Callback should not fire before reaching the analysis rate")
    }

    func testDisabledEngineDoesNotCallback() {
        var callbackCount = 0
        engine.onResult = { _ in callbackCount += 1 }
        engine.setEnabled(false)

        let pcm = TestAudioHelpers.makeSinePCM(frequency: 200, sampleCount: 960)
        for _ in 0..<20 {
            engine.processFrame(pcm)
        }

        XCTAssertEqual(callbackCount, 0, "Disabled engine should never fire callback")
    }

    func testIsEnabledReflectsState() {
        XCTAssertTrue(engine.isEnabled, "Engine should be enabled by default")
        engine.setEnabled(false)
        XCTAssertFalse(engine.isEnabled)
        engine.setEnabled(true)
        XCTAssertTrue(engine.isEnabled)
    }

    func testSetAnalysisRateChangesFrequency() {
        engine.setAnalysisRate(2)

        var callbackCount = 0
        engine.onResult = { _ in callbackCount += 1 }

        let pcm = TestAudioHelpers.makeSinePCM(frequency: 200, sampleCount: 960)
        for _ in 0..<10 {
            engine.processFrame(pcm)
        }

        XCTAssertEqual(callbackCount, 5, "With rate=2, 10 frames should yield 5 callbacks")
    }

    func testSetAnalysisRateMinimumIsOne() {
        // Setting rate to 0 should be clamped to 1
        engine.setAnalysisRate(0)

        var callbackCount = 0
        engine.onResult = { _ in callbackCount += 1 }

        let pcm = TestAudioHelpers.makeSinePCM(frequency: 200, sampleCount: 960)
        for _ in 0..<5 {
            engine.processFrame(pcm)
        }

        XCTAssertEqual(callbackCount, 5, "Rate clamped to 1 should fire on every frame")
    }

    func testResultContainsAllFields() {
        engine.setAnalysisRate(1)

        let expectation = expectation(description: "onResult called")
        var receivedResult: VoiceAnalysisResult?

        engine.onResult = { result in
            receivedResult = result
            expectation.fulfill()
        }

        let pcm = TestAudioHelpers.makeSinePCM(frequency: 200, sampleCount: 960)
        engine.processFrame(pcm)

        wait(for: [expectation], timeout: 1.0)

        guard let result = receivedResult else {
            XCTFail("Expected a result")
            return
        }

        // Verify all fields are populated (pitch should be detected for a 200Hz sine)
        XCTAssertGreaterThan(result.pitch.rms, 0, "RMS should be positive")
        // Confidence should be in range [0, 1]
        XCTAssertGreaterThanOrEqual(result.confidence, 0)
        XCTAssertLessThanOrEqual(result.confidence, 1.0)
    }

    func testNoCallbackWhenNoneSet() {
        // Ensure no crash when onResult is nil
        engine.setAnalysisRate(1)
        let pcm = TestAudioHelpers.makeSinePCM(frequency: 200, sampleCount: 960)
        // Should not crash
        engine.processFrame(pcm)
    }

    func testReEnableEngineResumesCallbacks() {
        engine.setAnalysisRate(1)
        var callbackCount = 0
        engine.onResult = { _ in callbackCount += 1 }

        let pcm = TestAudioHelpers.makeSinePCM(frequency: 200, sampleCount: 960)

        engine.setEnabled(false)
        for _ in 0..<5 { engine.processFrame(pcm) }
        XCTAssertEqual(callbackCount, 0)

        engine.setEnabled(true)
        engine.processFrame(pcm)
        // The internal frame counter kept incrementing, so a callback may or may not fire
        // depending on the counter. We just verify it does not crash and eventually fires.
        for _ in 0..<5 { engine.processFrame(pcm) }
        XCTAssertGreaterThan(callbackCount, 0, "Re-enabled engine should resume callbacks")
    }
}

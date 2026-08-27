import XCTest
@testable import QAudionEngine

final class VoiceAnalysisEngineTests: XCTestCase {
    private var engine: VoiceAnalysisEngine!

    override func setUp() {
        super.setUp()
        engine = VoiceAnalysisEngine()
    }

    func testCallbackFiringOnNthFrame() {
        // Gate is time-based now (>= 100 ms of accumulated audio, see
        // VoiceAnalysisEngine.analysisIntervalMs): each frame here is 20 ms
        // (960 samples @ 48 kHz), so 5 frames = 100 ms is still the point
        // the callback fires — same real-world cadence as the old
        // `frameCount % 5` gate produced at this frame size.
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
        XCTAssertNotNil(receivedResult, "Should receive a result after 100ms of 20ms frames")
    }

    func testCallbackNotFiredBeforeRate() {
        var callbackCount = 0
        engine.onResult = { _ in callbackCount += 1 }

        let pcm = TestAudioHelpers.makeSinePCM(frequency: 200, sampleCount: 960)
        // 4 frames of 20ms = 80ms, short of the 100ms analysis budget
        for _ in 0..<4 {
            engine.processFrame(pcm)
        }

        XCTAssertEqual(callbackCount, 0, "Callback should not fire before reaching the analysis time budget")
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

    func testAnalysisRateNoLongerGatesStandardFrames() {
        // Post-fix: analysisRate only drives the frame-count FALLBACK path
        // (used when a frame's byte length isn't a whole number of ms — see
        // VoiceAnalysisEngine.processFrame). For standard whole-ms PCM like
        // this 20ms frame, the 100ms time budget is what decides cadence,
        // regardless of what analysisRate is set to. This replaces the old
        // testSetAnalysisRateChangesFrequency, which asserted a
        // frame-count-driven cadence that no longer exists for this input.
        engine.setAnalysisRate(2)

        var callbackCount = 0
        engine.onResult = { _ in callbackCount += 1 }

        let pcm = TestAudioHelpers.makeSinePCM(frequency: 200, sampleCount: 960) // 20ms
        for _ in 0..<10 {
            engine.processFrame(pcm)
        }

        // 10 frames * 20ms = 200ms of audio -> fires at the 100ms and 200ms
        // marks (frame 5 and frame 10), same as with the default rate of 5.
        XCTAssertEqual(callbackCount, 2, "Time budget, not analysisRate, governs cadence for whole-ms PCM")
    }

    func testAnalysisRateStillAppliesToFallbackPath() {
        // The frame-count fallback only engages when pcmFrame.count / 96 == 0,
        // i.e. a frame representing less than 1ms of 48kHz mono Int16 audio —
        // an edge case, but the analysisRate clamp-to-1 (rate=0 -> 1) still
        // has to work there since it's the only place it still matters.
        engine.setAnalysisRate(0)

        var callbackCount = 0
        engine.onResult = { _ in callbackCount += 1 }

        let tinyPcm = TestAudioHelpers.makeSinePCM(frequency: 200, sampleCount: 4) // 8 bytes, < 96
        for _ in 0..<5 {
            engine.processFrame(tinyPcm)
        }

        XCTAssertEqual(callbackCount, 5, "Rate clamped to 1 should fire on every frame in the fallback path")
    }

    func testAnalysisRateFallbackHonorsConfiguredRate() {
        engine.setAnalysisRate(3)

        var callbackCount = 0
        engine.onResult = { _ in callbackCount += 1 }

        let tinyPcm = TestAudioHelpers.makeSinePCM(frequency: 200, sampleCount: 4) // 8 bytes, < 96
        for _ in 0..<9 {
            engine.processFrame(tinyPcm)
        }

        XCTAssertEqual(callbackCount, 3, "With rate=3 in the fallback path, 9 frames should yield 3 callbacks")
    }

    func test60msProfileFiresNearTheSame100msTargetInsteadOf300ms() {
        // The bug this fix addresses: under the 60ms audio profile
        // (project default, see AUDIO_BANDWIDTH_OPTIMISATION_PLAN /
        // AudioProfileTests), the OLD frameCount % 5 gate did not fire until
        // the 5th frame - 300ms of real audio time, 3x slower than the
        // intended ~100ms cadence GuardianMode was fixed to restore for the
        // exact same input stream (QAudionCallIntegration.analyze feeds both
        // guardianMode and voiceAnalysis the same pcm).
        var callbackCount = 0
        engine.onResult = { _ in callbackCount += 1 }

        let pcm60ms = TestAudioHelpers.makeSinePCM(frequency: 200, sampleCount: 2880) // 60ms

        engine.processFrame(pcm60ms) // 60ms elapsed
        XCTAssertEqual(callbackCount, 0, "Single 60ms frame is short of the 100ms budget")

        engine.processFrame(pcm60ms) // 120ms elapsed - crosses the 100ms budget
        XCTAssertEqual(callbackCount, 1,
            "Fixed gate fires once cumulative audio time reaches 100ms (2nd 60ms frame), " +
            "not after 5 frames / 300ms like the old frame-count gate")
    }

    func testNativeSrtp10msChunksNoLongerFireTooFast() {
        // The native-SRTP audio tap (NativeAudioPcmTap -> QAudionCallIntegration
        // .analyze -> voiceAnalysis.processFrame) delivers ~10ms chunks. Under
        // the OLD frameCount % 5 gate that fired every 50ms of real audio -
        // 2x faster than the intended 100ms target, and 6x faster than the
        // 300ms cadence the 60ms-profile default was actually shipping
        // (300ms / 50ms = 6). The fixed gate must land on the same ~100ms
        // real-world cadence regardless of chunk size.
        var callbackCount = 0
        engine.onResult = { _ in callbackCount += 1 }

        let pcm10ms = TestAudioHelpers.makeSinePCM(frequency: 200, sampleCount: 480) // 10ms

        for _ in 0..<5 { engine.processFrame(pcm10ms) } // 50ms elapsed
        XCTAssertEqual(callbackCount, 0,
            "50ms of audio must not fire yet - the old gate would already have fired here (frame 5)")

        for _ in 0..<5 { engine.processFrame(pcm10ms) } // 100ms elapsed
        XCTAssertEqual(callbackCount, 1, "Fires once cumulative audio time reaches the 100ms budget")
    }

    func testResultContainsAllFields() {
        // NOTE: setAnalysisRate(1) alone no longer makes a single 20ms frame
        // fire immediately — the time budget requires 100ms of accumulated
        // audio regardless of analysisRate for standard whole-ms PCM (see
        // testAnalysisRateNoLongerGatesStandardFrames). 5 frames of 20ms
        // crosses that budget.
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
        // Ensure no crash when onResult is nil and the gate actually fires
        // (5 frames of 20ms = 100ms crosses the time-based analysis budget).
        let pcm = TestAudioHelpers.makeSinePCM(frequency: 200, sampleCount: 960)
        for _ in 0..<5 {
            engine.processFrame(pcm)
        }
        // Should not crash
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

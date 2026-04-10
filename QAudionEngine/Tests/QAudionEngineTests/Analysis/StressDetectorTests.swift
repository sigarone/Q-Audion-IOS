import XCTest
@testable import QAudionEngine

final class StressDetectorTests: XCTestCase {
    private var detector: StressDetector!

    override func setUp() {
        super.setUp()
        detector = StressDetector()
    }

    func testUnvoicedPitchReturnsZeroStress() {
        let pitch = VoiceAnalysisResult.Pitch(f0Hz: 0, voiced: false, rms: 0)
        let result = detector.analyze(pitch: pitch)
        XCTAssertEqual(result.score, 0)
        XCTAssertEqual(result.jitter, 0)
        XCTAssertEqual(result.shimmer, 0)
    }

    func testSingleVoicedPitchProducesResult() {
        let pitch = VoiceAnalysisResult.Pitch(f0Hz: 120, voiced: true, rms: 0.3)
        let result = detector.analyze(pitch: pitch)
        // With a single sample, jitter and shimmer should be zero
        XCTAssertEqual(result.jitter, 0)
        XCTAssertEqual(result.shimmer, 0)
        XCTAssertEqual(result.score, 0)
    }

    func testStableF0ProducesLowJitter() {
        // Feed several frames at the same pitch -- jitter should be near zero
        for _ in 0..<10 {
            let pitch = VoiceAnalysisResult.Pitch(f0Hz: 120, voiced: true, rms: 0.3)
            _ = detector.analyze(pitch: pitch)
        }
        let result = detector.analyze(pitch: VoiceAnalysisResult.Pitch(f0Hz: 120, voiced: true, rms: 0.3))
        XCTAssertLessThan(result.jitter, 0.01, "Constant pitch should yield near-zero jitter")
    }

    func testVaryingF0ProducesHigherJitter() {
        // Feed alternating high/low pitches to generate jitter
        for i in 0..<20 {
            let f0: Float = i % 2 == 0 ? 100 : 200
            let pitch = VoiceAnalysisResult.Pitch(f0Hz: f0, voiced: true, rms: 0.3)
            _ = detector.analyze(pitch: pitch)
        }
        let result = detector.analyze(pitch: VoiceAnalysisResult.Pitch(f0Hz: 100, voiced: true, rms: 0.3))
        XCTAssertGreaterThan(result.jitter, 0.1, "Alternating pitch should produce measurable jitter")
    }

    func testStableAmplitudeProducesLowShimmer() {
        for _ in 0..<10 {
            let pitch = VoiceAnalysisResult.Pitch(f0Hz: 150, voiced: true, rms: 0.5)
            _ = detector.analyze(pitch: pitch)
        }
        let result = detector.analyze(pitch: VoiceAnalysisResult.Pitch(f0Hz: 150, voiced: true, rms: 0.5))
        XCTAssertLessThan(result.shimmer, 0.01, "Constant amplitude should yield near-zero shimmer")
    }

    func testScoreClampedToOne() {
        // Feed wildly varying pitch/amplitude to push score high
        for i in 0..<30 {
            let f0: Float = i % 2 == 0 ? 80 : 400
            let rms: Float = i % 2 == 0 ? 0.1 : 0.9
            _ = detector.analyze(pitch: VoiceAnalysisResult.Pitch(f0Hz: f0, voiced: true, rms: rms))
        }
        let result = detector.analyze(pitch: VoiceAnalysisResult.Pitch(f0Hz: 80, voiced: true, rms: 0.1))
        XCTAssertLessThanOrEqual(result.score, 1.0, "Stress score must not exceed 1.0")
    }

    func testUnvoicedFrameDoesNotAccumulate() {
        // Feed voiced frames, then an unvoiced frame -- history should not grow from unvoiced
        for _ in 0..<5 {
            _ = detector.analyze(pitch: VoiceAnalysisResult.Pitch(f0Hz: 120, voiced: true, rms: 0.3))
        }
        let unvoicedResult = detector.analyze(pitch: VoiceAnalysisResult.Pitch(f0Hz: 0, voiced: false, rms: 0))
        XCTAssertEqual(unvoicedResult.score, 0, "Unvoiced frame should return zero stress")
    }
}

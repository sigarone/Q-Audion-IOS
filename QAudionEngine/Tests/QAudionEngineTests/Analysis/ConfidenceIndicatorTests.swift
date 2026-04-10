import XCTest
@testable import QAudionEngine

final class ConfidenceIndicatorTests: XCTestCase {
    private var indicator: ConfidenceIndicator!

    override func setUp() {
        super.setUp()
        indicator = ConfidenceIndicator()
    }

    func testUnvoicedPitchReturnsZeroConfidence() {
        let pitch = VoiceAnalysisResult.Pitch(f0Hz: 0, voiced: false, rms: 0)
        let stress = VoiceAnalysisResult.Stress(score: 0, jitter: 0, shimmer: 0)
        let health = VoiceAnalysisResult.VoiceHealth(hnr: 0, breathiness: 1.0)
        let rate = VoiceAnalysisResult.SpeechRate(syllablesPerSec: 0, pauseRatio: 1.0, isSpeaking: false)

        let confidence = indicator.analyze(pitch: pitch, stress: stress, health: health, speechRate: rate)
        XCTAssertEqual(confidence, 0, "Unvoiced pitch should produce zero confidence")
    }

    func testIdealParametersProduceHighConfidence() {
        // Ideal voice: moderate pitch, low stress, good HNR, normal speech rate
        let pitch = VoiceAnalysisResult.Pitch(f0Hz: 150, voiced: true, rms: 0.5)
        let stress = VoiceAnalysisResult.Stress(score: 0.1, jitter: 0.01, shimmer: 0.02)
        let health = VoiceAnalysisResult.VoiceHealth(hnr: 15, breathiness: 0.25)
        let rate = VoiceAnalysisResult.SpeechRate(syllablesPerSec: 4.0, pauseRatio: 0.3, isSpeaking: true)

        let confidence = indicator.analyze(pitch: pitch, stress: stress, health: health, speechRate: rate)
        XCTAssertGreaterThanOrEqual(confidence, 0.8, "Ideal voice parameters should yield high confidence")
    }

    func testConfidenceNeverExceedsOne() {
        let pitch = VoiceAnalysisResult.Pitch(f0Hz: 150, voiced: true, rms: 0.5)
        let stress = VoiceAnalysisResult.Stress(score: 0.0, jitter: 0.0, shimmer: 0.0)
        let health = VoiceAnalysisResult.VoiceHealth(hnr: 30, breathiness: 0)
        let rate = VoiceAnalysisResult.SpeechRate(syllablesPerSec: 5.0, pauseRatio: 0.2, isSpeaking: true)

        let confidence = indicator.analyze(pitch: pitch, stress: stress, health: health, speechRate: rate)
        XCTAssertLessThanOrEqual(confidence, 1.0, "Confidence must not exceed 1.0")
    }

    func testConfidenceRangeIsZeroToOne() {
        let pitch = VoiceAnalysisResult.Pitch(f0Hz: 200, voiced: true, rms: 0.4)
        let stress = VoiceAnalysisResult.Stress(score: 0.5, jitter: 0.1, shimmer: 0.2)
        let health = VoiceAnalysisResult.VoiceHealth(hnr: 5, breathiness: 0.75)
        let rate = VoiceAnalysisResult.SpeechRate(syllablesPerSec: 1.0, pauseRatio: 0.5, isSpeaking: true)

        let confidence = indicator.analyze(pitch: pitch, stress: stress, health: health, speechRate: rate)
        XCTAssertGreaterThanOrEqual(confidence, 0)
        XCTAssertLessThanOrEqual(confidence, 1.0)
    }

    func testHighStressReducesConfidence() {
        let pitch = VoiceAnalysisResult.Pitch(f0Hz: 150, voiced: true, rms: 0.5)
        let health = VoiceAnalysisResult.VoiceHealth(hnr: 15, breathiness: 0.25)
        let rate = VoiceAnalysisResult.SpeechRate(syllablesPerSec: 4.0, pauseRatio: 0.3, isSpeaking: true)

        let lowStress = VoiceAnalysisResult.Stress(score: 0.1, jitter: 0.01, shimmer: 0.02)
        let highStress = VoiceAnalysisResult.Stress(score: 0.9, jitter: 0.2, shimmer: 0.3)

        let confLow = indicator.analyze(pitch: pitch, stress: lowStress, health: health, speechRate: rate)
        let confHigh = indicator.analyze(pitch: pitch, stress: highStress, health: health, speechRate: rate)

        XCTAssertGreaterThan(confLow, confHigh, "Lower stress should produce higher confidence")
    }

    func testOutOfRangePitchReducesConfidence() {
        let health = VoiceAnalysisResult.VoiceHealth(hnr: 15, breathiness: 0.25)
        let stress = VoiceAnalysisResult.Stress(score: 0.1, jitter: 0.01, shimmer: 0.02)
        let rate = VoiceAnalysisResult.SpeechRate(syllablesPerSec: 4.0, pauseRatio: 0.3, isSpeaking: true)

        // Normal pitch range (80-400 Hz gets the bonus)
        let normalPitch = VoiceAnalysisResult.Pitch(f0Hz: 150, voiced: true, rms: 0.5)
        let confNormal = indicator.analyze(pitch: normalPitch, stress: stress, health: health, speechRate: rate)

        // Pitch out of the 80-400 range does not get the bonus
        let highPitch = VoiceAnalysisResult.Pitch(f0Hz: 500, voiced: true, rms: 0.5)
        let confHigh = indicator.analyze(pitch: highPitch, stress: stress, health: health, speechRate: rate)

        XCTAssertGreaterThan(confNormal, confHigh,
                             "Pitch within normal range should yield higher confidence")
    }

    func testBaselineConfidenceForVoiced() {
        // Minimal voiced input: no bonuses except base 0.5
        let pitch = VoiceAnalysisResult.Pitch(f0Hz: 50, voiced: true, rms: 0.03)
        let stress = VoiceAnalysisResult.Stress(score: 0.9, jitter: 0.2, shimmer: 0.3)
        let health = VoiceAnalysisResult.VoiceHealth(hnr: 2, breathiness: 0.9)
        let rate = VoiceAnalysisResult.SpeechRate(syllablesPerSec: 0.5, pauseRatio: 0.9, isSpeaking: false)

        let confidence = indicator.analyze(pitch: pitch, stress: stress, health: health, speechRate: rate)
        XCTAssertGreaterThanOrEqual(confidence, 0.5, "Voiced input should have at least base 0.5 confidence")
    }
}

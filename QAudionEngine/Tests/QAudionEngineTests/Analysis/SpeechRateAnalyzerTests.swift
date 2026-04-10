import XCTest
@testable import QAudionEngine

final class SpeechRateAnalyzerTests: XCTestCase {
    private var analyzer: SpeechRateAnalyzer!

    override func setUp() {
        super.setUp()
        analyzer = SpeechRateAnalyzer()
    }

    func testSilentFrameIsNotSpeaking() {
        let pcm = TestAudioHelpers.makeSilentPCM(sampleCount: 960)
        let pitch = VoiceAnalysisResult.Pitch(f0Hz: 0, voiced: false, rms: 0)
        let result = analyzer.analyze(pcmFrame: pcm, pitch: pitch)
        XCTAssertFalse(result.isSpeaking, "Silent frame should not be flagged as speaking")
    }

    func testVoicedFrameIsSpeaking() {
        let pcm = TestAudioHelpers.makeSinePCM(frequency: 200, sampleCount: 960)
        let pitch = VoiceAnalysisResult.Pitch(f0Hz: 200, voiced: true, rms: 0.5)
        let result = analyzer.analyze(pcmFrame: pcm, pitch: pitch)
        XCTAssertTrue(result.isSpeaking, "Voiced frame with sufficient RMS should be speaking")
    }

    func testSyllableCountFromVoicedUnvoicedTransitions() {
        // Simulate voiced -> unvoiced transitions to trigger syllable counting
        let voicedPitch = VoiceAnalysisResult.Pitch(f0Hz: 200, voiced: true, rms: 0.5)
        let unvoicedPitch = VoiceAnalysisResult.Pitch(f0Hz: 0, voiced: false, rms: 0.01)
        let pcm = TestAudioHelpers.makeSinePCM(frequency: 200, sampleCount: 960)
        let silentPCM = TestAudioHelpers.makeSilentPCM(sampleCount: 960)

        // Create 5 voiced->unvoiced transitions
        var lastResult = VoiceAnalysisResult.SpeechRate(syllablesPerSec: 0, pauseRatio: 0, isSpeaking: false)
        for _ in 0..<5 {
            // Voiced segment (3 frames)
            for _ in 0..<3 {
                lastResult = analyzer.analyze(pcmFrame: pcm, pitch: voicedPitch)
            }
            // Unvoiced segment (2 frames)
            for _ in 0..<2 {
                lastResult = analyzer.analyze(pcmFrame: silentPCM, pitch: unvoicedPitch)
            }
        }

        XCTAssertGreaterThan(lastResult.syllablesPerSec, 0, "Should detect syllables from voiced-unvoiced transitions")
    }

    func testPauseRatioAllSilence() {
        let silentPCM = TestAudioHelpers.makeSilentPCM(sampleCount: 960)
        let pitch = VoiceAnalysisResult.Pitch(f0Hz: 0, voiced: false, rms: 0)

        var result = VoiceAnalysisResult.SpeechRate(syllablesPerSec: 0, pauseRatio: 0, isSpeaking: false)
        for _ in 0..<10 {
            result = analyzer.analyze(pcmFrame: silentPCM, pitch: pitch)
        }
        XCTAssertEqual(result.pauseRatio, 1.0, "All silent frames should produce pause ratio of 1.0")
    }

    func testPauseRatioAllVoiced() {
        let pcm = TestAudioHelpers.makeSinePCM(frequency: 200, sampleCount: 960)
        let pitch = VoiceAnalysisResult.Pitch(f0Hz: 200, voiced: true, rms: 0.5)

        var result = VoiceAnalysisResult.SpeechRate(syllablesPerSec: 0, pauseRatio: 0, isSpeaking: false)
        for _ in 0..<10 {
            result = analyzer.analyze(pcmFrame: pcm, pitch: pitch)
        }
        XCTAssertEqual(result.pauseRatio, 0, "All voiced frames should produce pause ratio of 0")
    }

    func testResetClearsState() {
        let pcm = TestAudioHelpers.makeSinePCM(frequency: 200, sampleCount: 960)
        let pitch = VoiceAnalysisResult.Pitch(f0Hz: 200, voiced: true, rms: 0.5)

        // Feed some frames
        for _ in 0..<5 {
            _ = analyzer.analyze(pcmFrame: pcm, pitch: pitch)
        }

        analyzer.reset()

        // After reset, first frame should have zero syllable rate
        let silentPCM = TestAudioHelpers.makeSilentPCM(sampleCount: 960)
        let unvoicedPitch = VoiceAnalysisResult.Pitch(f0Hz: 0, voiced: false, rms: 0)
        let result = analyzer.analyze(pcmFrame: silentPCM, pitch: unvoicedPitch)
        XCTAssertEqual(result.syllablesPerSec, 0, "After reset, syllable rate should be zero")
    }

    func testLowRmsVoicedIsNotSpeaking() {
        let pcm = TestAudioHelpers.makeSinePCM(frequency: 200, sampleCount: 960, amplitude: 0.001)
        // voiced = true but rms below threshold (0.02)
        let pitch = VoiceAnalysisResult.Pitch(f0Hz: 200, voiced: true, rms: 0.01)
        let result = analyzer.analyze(pcmFrame: pcm, pitch: pitch)
        XCTAssertFalse(result.isSpeaking, "Voiced frame with low RMS should not be flagged as speaking")
    }
}

import XCTest
@testable import QAudionEngine

final class VoiceHealthMonitorTests: XCTestCase {
    private var monitor: VoiceHealthMonitor!

    override func setUp() {
        super.setUp()
        monitor = VoiceHealthMonitor()
    }

    func testUnvoicedPitchReturnsDefaultHealth() {
        let pitch = VoiceAnalysisResult.Pitch(f0Hz: 0, voiced: false, rms: 0)
        let pcm = TestAudioHelpers.makeSilentPCM(sampleCount: 960)
        let result = monitor.analyze(pitch: pitch, pcmFrame: pcm)
        XCTAssertEqual(result.hnr, 0, "HNR should be zero for unvoiced input")
        XCTAssertEqual(result.breathiness, 1.0, "Breathiness should be 1.0 for unvoiced input")
    }

    func testVoicedSineProducesPositiveHNR() {
        let pitch = VoiceAnalysisResult.Pitch(f0Hz: 200, voiced: true, rms: 0.5)
        let pcm = TestAudioHelpers.makeSinePCM(frequency: 200, sampleCount: 960)
        let result = monitor.analyze(pitch: pitch, pcmFrame: pcm)
        XCTAssertGreaterThan(result.hnr, 0, "A clean sine wave should have positive HNR")
    }

    func testBreathinessRange() {
        let pitch = VoiceAnalysisResult.Pitch(f0Hz: 150, voiced: true, rms: 0.4)
        let pcm = TestAudioHelpers.makeSinePCM(frequency: 150, sampleCount: 960)
        let result = monitor.analyze(pitch: pitch, pcmFrame: pcm)
        XCTAssertGreaterThanOrEqual(result.breathiness, 0, "Breathiness should be >= 0")
        XCTAssertLessThanOrEqual(result.breathiness, 1.0, "Breathiness should be <= 1.0")
    }

    func testNoiseInputHealth() {
        let pitch = VoiceAnalysisResult.Pitch(f0Hz: 120, voiced: true, rms: 0.3)
        let pcm = TestAudioHelpers.makeRandomPCM(sampleCount: 960)
        let result = monitor.analyze(pitch: pitch, pcmFrame: pcm)
        // Noise should have lower HNR than a clean sine
        XCTAssertGreaterThanOrEqual(result.breathiness, 0)
        XCTAssertLessThanOrEqual(result.breathiness, 1.0)
    }

    func testShortFrameWithVoicedPitch() {
        // Fewer than 100 samples should cause estimateHNR to return 0
        let pitch = VoiceAnalysisResult.Pitch(f0Hz: 200, voiced: true, rms: 0.5)
        let pcm = TestAudioHelpers.makeSinePCM(frequency: 200, sampleCount: 40)
        let result = monitor.analyze(pitch: pitch, pcmFrame: pcm)
        XCTAssertEqual(result.hnr, 0, "HNR should be zero for frames shorter than 100 samples")
        XCTAssertEqual(result.breathiness, 1.0, "Breathiness should be 1.0 when HNR is zero")
    }

    func testCleanSineLessBreathyThanNoise() {
        let voicedPitch = VoiceAnalysisResult.Pitch(f0Hz: 200, voiced: true, rms: 0.5)

        let sinePCM = TestAudioHelpers.makeSinePCM(frequency: 200, sampleCount: 960)
        let sineResult = monitor.analyze(pitch: voicedPitch, pcmFrame: sinePCM)

        let noisePCM = TestAudioHelpers.makeRandomPCM(sampleCount: 960)
        let noiseResult = monitor.analyze(pitch: voicedPitch, pcmFrame: noisePCM)

        XCTAssertLessThanOrEqual(sineResult.breathiness, noiseResult.breathiness,
                                 "A clean sine should be less breathy than random noise")
    }
}

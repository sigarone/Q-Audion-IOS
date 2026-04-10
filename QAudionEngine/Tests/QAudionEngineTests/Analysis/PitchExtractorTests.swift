import XCTest
@testable import QAudionEngine

final class PitchExtractorTests: XCTestCase {
    private var extractor: PitchExtractor!

    override func setUp() {
        super.setUp()
        extractor = PitchExtractor()
    }

    func testSineWave440HzDetectsVoiced() {
        let pcm = TestAudioHelpers.makeSinePCM(frequency: 440, sampleCount: 960)
        let result = extractor.extract(pcmFrame: pcm)
        XCTAssertTrue(result.voiced, "A 440Hz sine wave should be detected as voiced")
        XCTAssertGreaterThan(result.f0Hz, 400, "Detected pitch should be near 440Hz")
        XCTAssertLessThan(result.f0Hz, 500, "Detected pitch should be near 440Hz")
        XCTAssertGreaterThan(result.rms, 0, "RMS should be positive for non-silent audio")
    }

    func testSineWave200HzDetectsVoiced() {
        let pcm = TestAudioHelpers.makeSinePCM(frequency: 200, sampleCount: 960)
        let result = extractor.extract(pcmFrame: pcm)
        XCTAssertTrue(result.voiced, "A 200Hz sine wave should be detected as voiced")
        XCTAssertGreaterThan(result.f0Hz, 150)
        XCTAssertLessThan(result.f0Hz, 250)
    }

    func testSilentFrameReturnsUnvoiced() {
        let pcm = TestAudioHelpers.makeSilentPCM(sampleCount: 960)
        let result = extractor.extract(pcmFrame: pcm)
        XCTAssertFalse(result.voiced, "Silent audio should not be voiced")
        XCTAssertEqual(result.f0Hz, 0, "Pitch should be zero for silence")
    }

    func testShortFrameReturnsDefault() {
        // Less than 480 samples should return the default (unvoiced, zero pitch)
        let pcm = TestAudioHelpers.makeSinePCM(frequency: 440, sampleCount: 200)
        let result = extractor.extract(pcmFrame: pcm)
        XCTAssertFalse(result.voiced)
        XCTAssertEqual(result.f0Hz, 0)
        XCTAssertEqual(result.rms, 0)
    }

    func testEmptyDataReturnsDefault() {
        let result = extractor.extract(pcmFrame: Data())
        XCTAssertFalse(result.voiced)
        XCTAssertEqual(result.f0Hz, 0)
        XCTAssertEqual(result.rms, 0)
    }

    func testRmsIsPositiveForNonSilentAudio() {
        let pcm = TestAudioHelpers.makeSinePCM(frequency: 300, sampleCount: 960)
        let result = extractor.extract(pcmFrame: pcm)
        XCTAssertGreaterThan(result.rms, 0.01)
    }

    func testLowAmplitudeSineIsUnvoiced() {
        // Very low amplitude should fall below the RMS threshold
        let pcm = TestAudioHelpers.makeSinePCM(frequency: 440, sampleCount: 960, amplitude: 0.001)
        let result = extractor.extract(pcmFrame: pcm)
        XCTAssertFalse(result.voiced, "Very low amplitude should be treated as unvoiced")
    }
}

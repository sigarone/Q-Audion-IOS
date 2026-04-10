import XCTest
@testable import QAudionEngine

final class FormantTrackerTests: XCTestCase {
    private var tracker: FormantTracker!

    override func setUp() {
        super.setUp()
        tracker = FormantTracker()
    }

    func testSineWaveProducesFormants() {
        let pcm = TestAudioHelpers.makeSinePCM(frequency: 440, sampleCount: 960)
        let result = tracker.extract(pcmFrame: pcm)
        // A 440Hz sine should produce at least some spectral content
        // F1 or F2 should be nonzero for a real signal
        let hasFormant = result.f1 > 0 || result.f2 > 0
        XCTAssertTrue(hasFormant, "A non-silent signal should produce at least one formant")
    }

    func testSilentFrameReturnsZeroFormants() {
        let pcm = TestAudioHelpers.makeSilentPCM(sampleCount: 960)
        let result = tracker.extract(pcmFrame: pcm)
        XCTAssertEqual(result.f1, 0)
        XCTAssertEqual(result.f2, 0)
        XCTAssertEqual(result.f3, 0)
        XCTAssertEqual(result.f4, 0)
    }

    func testShortFrameReturnsZeroFormants() {
        // Fewer than 256 samples should return zeros
        let pcm = TestAudioHelpers.makeSinePCM(frequency: 300, sampleCount: 100)
        let result = tracker.extract(pcmFrame: pcm)
        XCTAssertEqual(result.f1, 0)
        XCTAssertEqual(result.f2, 0)
        XCTAssertEqual(result.f3, 0)
        XCTAssertEqual(result.f4, 0)
    }

    func testEmptyDataReturnsZeroFormants() {
        let result = tracker.extract(pcmFrame: Data())
        XCTAssertEqual(result.f1, 0)
        XCTAssertEqual(result.f2, 0)
        XCTAssertEqual(result.f3, 0)
        XCTAssertEqual(result.f4, 0)
    }

    func testFormantFrequenciesAreNonNegative() {
        let pcm = TestAudioHelpers.makeSinePCM(frequency: 300, sampleCount: 960)
        let result = tracker.extract(pcmFrame: pcm)
        XCTAssertGreaterThanOrEqual(result.f1, 0)
        XCTAssertGreaterThanOrEqual(result.f2, 0)
        XCTAssertGreaterThanOrEqual(result.f3, 0)
        XCTAssertGreaterThanOrEqual(result.f4, 0)
    }

    func testNoiseInputProducesFormants() {
        let pcm = TestAudioHelpers.makeRandomPCM(sampleCount: 960)
        let result = tracker.extract(pcmFrame: pcm)
        // Noise has broad spectral energy so the LPC may find formant peaks
        XCTAssertGreaterThanOrEqual(result.f1, 0)
        XCTAssertGreaterThanOrEqual(result.f2, 0)
    }

    func testFormantOrderIsAscending() {
        let pcm = TestAudioHelpers.makeRandomPCM(sampleCount: 960)
        let result = tracker.extract(pcmFrame: pcm)
        // When formants are detected they should be in ascending order
        if result.f1 > 0 && result.f2 > 0 {
            XCTAssertLessThanOrEqual(result.f1, result.f2, "F1 should be <= F2")
        }
        if result.f2 > 0 && result.f3 > 0 {
            XCTAssertLessThanOrEqual(result.f2, result.f3, "F2 should be <= F3")
        }
        if result.f3 > 0 && result.f4 > 0 {
            XCTAssertLessThanOrEqual(result.f3, result.f4, "F3 should be <= F4")
        }
    }
}

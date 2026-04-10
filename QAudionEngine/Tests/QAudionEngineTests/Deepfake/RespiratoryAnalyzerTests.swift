import XCTest
@testable import QAudionEngine

final class RespiratoryAnalyzerTests: XCTestCase {

    // MARK: - Default Score with Insufficient Data

    func testAnalyzeWithInsufficientDataReturnsDefault() {
        let analyzer = RespiratoryAnalyzer()
        // Feed fewer than 50 frames -- should return the default 0.5
        let frame = TestAudioHelpers.makeSinePCM(frequency: 200, sampleCount: AudioConstants.samplesPerFrame)
        var lastScore: Float = -1
        for _ in 0..<10 {
            lastScore = analyzer.analyze(pcmFrame: frame)
        }
        XCTAssertEqual(lastScore, 0.5, accuracy: 0.01, "Should return 0.5 default with < 50 frames")
    }

    // MARK: - Score Range

    func testAnalyzeReturnScoreInUnitRange() {
        let analyzer = RespiratoryAnalyzer()
        let frame = TestAudioHelpers.makeSinePCM(frequency: 300, sampleCount: AudioConstants.samplesPerFrame)
        var lastScore: Float = 0
        // Feed enough frames to trigger periodicity analysis
        for _ in 0..<60 {
            lastScore = analyzer.analyze(pcmFrame: frame)
        }
        XCTAssertGreaterThanOrEqual(lastScore, 0, "Score should be >= 0")
        XCTAssertLessThanOrEqual(lastScore, 1, "Score should be <= 1")
    }

    func testAnalyzeWithRandomNoiseStaysInRange() {
        let analyzer = RespiratoryAnalyzer()
        for _ in 0..<80 {
            let frame = TestAudioHelpers.makeRandomPCM(sampleCount: AudioConstants.samplesPerFrame)
            let score = analyzer.analyze(pcmFrame: frame)
            XCTAssertGreaterThanOrEqual(score, 0, "Score should be >= 0")
            XCTAssertLessThanOrEqual(score, 1, "Score should be <= 1")
        }
    }

    // MARK: - Reset

    func testResetClearsHistory() {
        let analyzer = RespiratoryAnalyzer()
        let frame = TestAudioHelpers.makeSinePCM(frequency: 200, sampleCount: AudioConstants.samplesPerFrame)
        // Build up history beyond 50 frames
        for _ in 0..<60 {
            _ = analyzer.analyze(pcmFrame: frame)
        }
        analyzer.reset()
        // After reset, insufficient data means default 0.5
        let score = analyzer.analyze(pcmFrame: frame)
        XCTAssertEqual(score, 0.5, accuracy: 0.01, "After reset, first frame should return 0.5 default")
    }

    // MARK: - Window Capping

    func testHistoryDoesNotExceedWindowSize() {
        let analyzer = RespiratoryAnalyzer()
        let frame = TestAudioHelpers.makeSinePCM(frequency: 440, sampleCount: AudioConstants.samplesPerFrame)
        // Feed more than windowSize (250) frames -- should not crash
        for _ in 0..<300 {
            let score = analyzer.analyze(pcmFrame: frame)
            XCTAssertGreaterThanOrEqual(score, 0)
            XCTAssertLessThanOrEqual(score, 1)
        }
    }

    // MARK: - Silent Input

    func testAnalyzeSilentInput() {
        let analyzer = RespiratoryAnalyzer()
        let silent = TestAudioHelpers.makeSilentPCM(sampleCount: AudioConstants.samplesPerFrame)
        var lastScore: Float = -1
        for _ in 0..<60 {
            lastScore = analyzer.analyze(pcmFrame: silent)
        }
        // Silent data has zero energy and zero variance, so periodicity returns 0.5 default
        XCTAssertGreaterThanOrEqual(lastScore, 0)
        XCTAssertLessThanOrEqual(lastScore, 1)
    }

    // MARK: - Empty Frame

    func testAnalyzeEmptyFrame() {
        let analyzer = RespiratoryAnalyzer()
        let score = analyzer.analyze(pcmFrame: Data())
        // Empty data produces zero energy; with < 50 frames returns 0.5
        XCTAssertEqual(score, 0.5, accuracy: 0.01)
    }
}

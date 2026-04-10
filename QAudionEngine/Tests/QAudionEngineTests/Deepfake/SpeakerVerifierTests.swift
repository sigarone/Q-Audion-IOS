import XCTest
@testable import QAudionEngine

final class SpeakerVerifierTests: XCTestCase {

    // MARK: - Initial State

    func testInitialStateIsIdle() {
        let verifier = SpeakerVerifier()
        if case .idle = verifier.getState() {} else {
            XCTFail("Expected idle state")
        }
    }

    // MARK: - Enrollment Flow

    func testStartEnrollmentTransitionsToEnrolling() {
        let verifier = SpeakerVerifier()
        verifier.startEnrollment()
        if case .enrolling = verifier.getState() {} else {
            XCTFail("Expected enrolling state after startEnrollment")
        }
    }

    func testFinishEnrollmentWithTooFewFramesFails() {
        let verifier = SpeakerVerifier()
        verifier.startEnrollment()
        // Feed only 10 frames -- well below the 150 minimum
        let frame = TestAudioHelpers.makeSinePCM(frequency: 440, sampleCount: AudioConstants.samplesPerFrame)
        for _ in 0..<10 {
            verifier.processEnrollmentFrame(frame)
        }
        let success = verifier.finishEnrollment()
        XCTAssertFalse(success, "Enrollment should fail with fewer than 150 frames")
        // State should remain enrolling since enrollment did not succeed
        if case .enrolling = verifier.getState() {} else {
            XCTFail("Expected enrolling state after failed finish")
        }
    }

    func testFinishEnrollmentWithEnoughFramesSucceeds() {
        let verifier = SpeakerVerifier()
        verifier.startEnrollment()
        let frame = TestAudioHelpers.makeSinePCM(frequency: 440, sampleCount: AudioConstants.samplesPerFrame)
        for _ in 0..<160 {
            verifier.processEnrollmentFrame(frame)
        }
        let success = verifier.finishEnrollment()
        XCTAssertTrue(success, "Enrollment should succeed with >= 150 frames")
        if case .ready = verifier.getState() {} else {
            XCTFail("Expected ready state after successful enrollment")
        }
    }

    func testProcessFrameIgnoredWhenNotEnrolling() {
        let verifier = SpeakerVerifier()
        // State is idle -- processEnrollmentFrame should be ignored
        let frame = TestAudioHelpers.makeSinePCM(frequency: 440, sampleCount: AudioConstants.samplesPerFrame)
        verifier.processEnrollmentFrame(frame)
        // Should still be idle and finishEnrollment should fail
        if case .idle = verifier.getState() {} else {
            XCTFail("Expected idle state")
        }
    }

    // MARK: - Verification

    func testVerifyReturnsZeroWhenNotReady() {
        let verifier = SpeakerVerifier()
        let frame = TestAudioHelpers.makeSinePCM(frequency: 440, sampleCount: AudioConstants.samplesPerFrame)
        let score = verifier.verify(pcmFrame: frame)
        XCTAssertEqual(score, 0, "verify should return 0 when not in ready state")
    }

    func testVerifyAfterEnrollmentReturnsSimilarityScore() {
        let verifier = SpeakerVerifier()
        let frame = TestAudioHelpers.makeSinePCM(frequency: 440, sampleCount: AudioConstants.samplesPerFrame)

        verifier.startEnrollment()
        for _ in 0..<160 {
            verifier.processEnrollmentFrame(frame)
        }
        XCTAssertTrue(verifier.finishEnrollment())

        // Verify with the same waveform should produce a high similarity score
        let score = verifier.verify(pcmFrame: frame)
        XCTAssertGreaterThan(score, 0, "Similarity score should be positive for matching audio")
        XCTAssertLessThanOrEqual(score, 1.0, "Cosine similarity should not exceed 1.0")
    }

    func testVerifyWithEmptyDataReturnsZero() {
        let verifier = enrolledVerifier()
        let score = verifier.verify(pcmFrame: Data())
        XCTAssertEqual(score, 0, "verify with empty data should return 0")
    }

    func testVerifyWithTinyDataReturnsZero() {
        let verifier = enrolledVerifier()
        // Data too small for LfccExtractor to produce features
        let score = verifier.verify(pcmFrame: Data(repeating: 0, count: 4))
        XCTAssertEqual(score, 0, "verify with tiny data should return 0")
    }

    // MARK: - Re-enrollment

    func testReEnrollmentResetsState() {
        let verifier = enrolledVerifier()
        if case .ready = verifier.getState() {} else {
            XCTFail("Expected ready state")
        }
        // Start new enrollment -- should go back to enrolling
        verifier.startEnrollment()
        if case .enrolling = verifier.getState() {} else {
            XCTFail("Expected enrolling state after re-starting enrollment")
        }
    }

    // MARK: - Helpers

    private func enrolledVerifier() -> SpeakerVerifier {
        let verifier = SpeakerVerifier()
        let frame = TestAudioHelpers.makeSinePCM(frequency: 440, sampleCount: AudioConstants.samplesPerFrame)
        verifier.startEnrollment()
        for _ in 0..<160 {
            verifier.processEnrollmentFrame(frame)
        }
        _ = verifier.finishEnrollment()
        return verifier
    }
}

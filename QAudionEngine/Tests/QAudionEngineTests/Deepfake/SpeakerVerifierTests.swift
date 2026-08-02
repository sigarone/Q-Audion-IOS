import XCTest
@testable import QAudionEngine

/// Deterministic stand-in for the CAM++ ONNX embedder.
///
/// The real one is compiled out on a simulator
/// (`CamPlusSpeakerEmbedder.loadModel` is
/// `#if !targetEnvironment(simulator) … #else return false #endif`), so
/// every embedding throws `.runtimeUnavailable` there and the three cases
/// that need a real vector could never pass in CI — which is exactly why
/// this suite sat red for 40+ consecutive runs. Skipping them would have
/// hidden the state machine these tests exist to pin; this exercises it
/// instead, on the production code path, with only the backend swapped.
///
/// Behaviour that matters to `SpeakerVerifier`: identical audio yields an
/// identical vector (so a verify against the enrolled template scores ~1),
/// different audio yields a different one, and the vector is L2-normalised
/// like the real embedder's output.
final class DeterministicTestEmbedder: SpeakerEmbedding {

    static let embeddingDimension = 512

    /// Bounded autocorrelation, then L2-normalised.
    ///
    /// The property that matters: the result must not depend on how MUCH
    /// audio was passed. Enrollment accumulates 160 frames while `verify`
    /// embeds a single one, and the tests assert that verifying the SAME
    /// tone against the enrolled template scores positively — so a
    /// signature that shifted with input length (a per-index bucket mean,
    /// say) would make that assertion depend on phase alignment rather
    /// than on the state machine under test. Autocorrelation of a periodic
    /// signal is the same curve regardless of duration, and differs for a
    /// different frequency, which is exactly the pair of properties needed.
    func embed(pcm16kMono: [Float]) throws -> [Float] {
        guard !pcm16kMono.isEmpty else {
            throw CamPlusSpeakerEmbedder.CamPlusError.inferenceFailed("empty input")
        }
        let dim = Self.embeddingDimension
        // Bounded so a 160-frame enrollment does not cost 78M multiplies.
        let window = min(pcm16kMono.count, 8192)
        var out = [Float](repeating: 0, count: dim)
        for lag in 0..<dim {
            var sum: Float = 0
            var n = 0
            var i = 0
            while i + lag < window {
                sum += pcm16kMono[i] * pcm16kMono[i + lag]
                n += 1
                i += 1
            }
            out[lag] = n > 0 ? sum / Float(n) : 0
        }
        var sumSq: Float = 0
        for x in out { sumSq += x * x }
        let norm = sumSq.squareRoot()
        guard norm > 1e-9 else {
            // Silence or DC carries no speaker information; the real
            // embedder would not produce a usable vector either.
            throw CamPlusSpeakerEmbedder.CamPlusError.inferenceFailed("degenerate input")
        }
        return out.map { $0 / norm }
    }
}

final class SpeakerVerifierTests: XCTestCase {

    // MARK: - Initial State

    func testInitialStateIsIdle() {
        let verifier = SpeakerVerifier(embedder: DeterministicTestEmbedder())
        if case .idle = verifier.getState() {} else {
            XCTFail("Expected idle state")
        }
    }

    // MARK: - Enrollment Flow

    func testStartEnrollmentTransitionsToEnrolling() {
        let verifier = SpeakerVerifier(embedder: DeterministicTestEmbedder())
        verifier.startEnrollment()
        if case .enrolling = verifier.getState() {} else {
            XCTFail("Expected enrolling state after startEnrollment")
        }
    }

    func testFinishEnrollmentWithTooFewFramesFails() {
        let verifier = SpeakerVerifier(embedder: DeterministicTestEmbedder())
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
        let verifier = SpeakerVerifier(embedder: DeterministicTestEmbedder())
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
        let verifier = SpeakerVerifier(embedder: DeterministicTestEmbedder())
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
        let verifier = SpeakerVerifier(embedder: DeterministicTestEmbedder())
        let frame = TestAudioHelpers.makeSinePCM(frequency: 440, sampleCount: AudioConstants.samplesPerFrame)
        let score = verifier.verify(pcmFrame: frame)
        XCTAssertEqual(score, 0, "verify should return 0 when not in ready state")
    }

    func testVerifyAfterEnrollmentReturnsSimilarityScore() {
        let verifier = SpeakerVerifier(embedder: DeterministicTestEmbedder())
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
        // Data too small for KaldiFbankExtractor to produce features
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
        let verifier = SpeakerVerifier(embedder: DeterministicTestEmbedder())
        let frame = TestAudioHelpers.makeSinePCM(frequency: 440, sampleCount: AudioConstants.samplesPerFrame)
        verifier.startEnrollment()
        for _ in 0..<160 {
            verifier.processEnrollmentFrame(frame)
        }
        _ = verifier.finishEnrollment()
        return verifier
    }
}

import XCTest
@testable import QAudionEngine

final class VoiceLearningSessionTests: XCTestCase {

    private func makeSession() -> (VoiceLearningSession, VoiceprintBacking) {
        let backing = InMemoryVoiceprintBacking()
        let store = VoiceprintStore(backing: backing)
        let verifier = SpeakerVerifier(embedder: DeterministicTestEmbedder())
        let session = VoiceLearningSession(verifier: verifier, store: store)
        return (session, backing)
    }

    // MARK: - Initial State

    func testInitialStateIsIdle() {
        let (session, _) = makeSession()
        XCTAssertEqual(session.state, .idle)
    }

    // MARK: - Enrollment Flow

    func testStartTransitionsToInProgress() {
        let (session, _) = makeSession()
        session.start(contactId: "test-contact")

        XCTAssertEqual(session.state, .inProgress(progress: 0.0))
    }

    func testProcessRxFrameIgnoredWhenNotInProgress() {
        let (session, _) = makeSession()
        let frame = TestAudioHelpers.makeSinePCM(frequency: 440, sampleCount: AudioConstants.samplesPerFrame)
        session.processRxFrame(frame)

        XCTAssertEqual(session.state, .idle)
    }

    func testProcessRxFrameUpdatesProgress() {
        let (session, _) = makeSession()
        session.start(contactId: "test-contact")
        let frame = TestAudioHelpers.makeSinePCM(frequency: 440, sampleCount: AudioConstants.samplesPerFrame)

        session.processRxFrame(frame)

        if case .inProgress(let progress) = session.state {
            XCTAssertGreaterThan(progress, 0.0)
            XCTAssertLessThan(progress, 1.0)
        } else {
            XCTFail("Expected inProgress state, got \(session.state)")
        }
    }

    func testSuccessfulEnrollmentTransitionsToCompletedAndSaves() {
        let (session, backing) = makeSession()
        let contactId = "test-contact"
        session.start(contactId: contactId)

        let frame = TestAudioHelpers.makeSinePCM(frequency: 440, sampleCount: AudioConstants.samplesPerFrame)

        // requiredFrames is 150
        for _ in 0..<150 {
            session.processRxFrame(frame)
        }

        XCTAssertEqual(session.state, .completed(contactId: contactId))

        // Verify it was saved
        XCTAssertNotNil(backing.load(contactId: contactId), "Expected template to be saved in store")
    }

    func testFailedEnrollmentTransitionsToFailed() {
        let (session, backing) = makeSession()
        let contactId = "test-contact"
        session.start(contactId: contactId)

        // Use silence to trigger an embedder failure (norm < 1e-9 in DeterministicTestEmbedder)
        let silenceFrame = TestAudioHelpers.makeSinePCM(frequency: 440, sampleCount: AudioConstants.samplesPerFrame, amplitude: 0.0)

        for _ in 0..<150 {
            session.processRxFrame(silenceFrame)
        }

        XCTAssertEqual(session.state, .failed)

        // Verify it was NOT saved
        XCTAssertNil(backing.load(contactId: contactId), "Expected template to not be saved on failure")
    }

    // MARK: - Edge Cases

    func testCancelMidEnrollmentResetsToIdle() {
        let (session, _) = makeSession()
        session.start(contactId: "test-contact")
        let frame = TestAudioHelpers.makeSinePCM(frequency: 440, sampleCount: AudioConstants.samplesPerFrame)

        for _ in 0..<50 {
            session.processRxFrame(frame)
        }

        session.cancel()

        XCTAssertEqual(session.state, .idle)

        // Verify that feeding frames now does nothing
        session.processRxFrame(frame)
        XCTAssertEqual(session.state, .idle)
    }

    func testMultipleStartsResetSession() {
        let (session, _) = makeSession()
        session.start(contactId: "contact-1")

        let frame = TestAudioHelpers.makeSinePCM(frequency: 440, sampleCount: AudioConstants.samplesPerFrame)
        for _ in 0..<50 {
            session.processRxFrame(frame)
        }

        // Start again
        session.start(contactId: "contact-2")

        XCTAssertEqual(session.state, .inProgress(progress: 0.0))

        // Finish the second enrollment
        for _ in 0..<150 {
            session.processRxFrame(frame)
        }

        XCTAssertEqual(session.state, .completed(contactId: "contact-2"))
    }
}

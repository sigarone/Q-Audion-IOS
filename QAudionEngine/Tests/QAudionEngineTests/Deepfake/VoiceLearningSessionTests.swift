import XCTest
@testable import QAudionEngine

final class VoiceLearningSessionTests: XCTestCase {

    private func makeSession() -> (VoiceLearningSession, InMemoryVoiceprintBacking) {
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

    // MARK: - What is never saved, and what is never overwritten

    private func makeSession(embedder: any SpeakerEmbedding) -> (VoiceLearningSession, InMemoryVoiceprintBacking) {
        let backing = InMemoryVoiceprintBacking()
        let store = VoiceprintStore(backing: backing)
        let verifier = SpeakerVerifier(embedder: embedder)
        return (VoiceLearningSession(verifier: verifier, store: store), backing)
    }

    private func learn(_ session: VoiceLearningSession, contactId: String) {
        session.start(contactId: contactId)
        let frame = TestAudioHelpers.makeSinePCM(frequency: 440, sampleCount: AudioConstants.samplesPerFrame)
        for _ in 0..<150 {
            session.processRxFrame(frame)
        }
    }

    /// An embedder that answers with a vector that says nothing is a failed
    /// learning: nothing is saved, so the next call can learn again.
    func testAnEmbeddingThatSaysNothingIsNotSaved() {
        let unusable: [[Float]] = [
            [Float](repeating: 0, count: 512),
            [Float](repeating: .nan, count: 512),
            [],
        ]
        for vector in unusable {
            let (session, backing) = makeSession(embedder: FixedVectorEmbedder(vector))
            learn(session, contactId: "kim")
            XCTAssertEqual(session.state, .failed, "\(vector.prefix(1))")
            XCTAssertEqual(backing.lookup(contactId: "kim"), .absent)
            XCTAssertTrue(backing.listContacts().isEmpty)
        }
    }

    /// The learning that did not work leaves the profile that was there.
    func testAFailedLearningLeavesTheStoredProfileAsItWas() {
        let (session, backing) = makeSession(embedder: FixedVectorEmbedder([Float](repeating: 0, count: 512)))
        let before: [Float] = [0.6, 0.8]
        backing.save(contactId: "lee", template: before)
        learn(session, contactId: "lee")
        XCTAssertEqual(session.state, .failed)
        XCTAssertEqual(backing.lookup(contactId: "lee"), .present(before))
    }

    /// A store that cannot be read holds something unknown: the learning does
    /// not write over it, and does not report a saved voice.
    func testAnUnreadableProfileIsNotWrittenOver() {
        let (session, backing) = makeSession()
        let before: [Float] = [0.6, 0.8]
        backing.save(contactId: "max", template: before)
        backing.failReads = true
        learn(session, contactId: "max")
        XCTAssertEqual(session.state, .failed)
        backing.failReads = false
        XCTAssertEqual(backing.lookup(contactId: "max"), .present(before), "the profile was not touched")
    }

    /// A refused write is not a saved voice: no "learned" confirmation, and
    /// nothing is stored.
    func testARefusedWriteIsNotReportedAsLearned() {
        let (session, backing) = makeSession()
        backing.failWrites = true
        learn(session, contactId: "ned")
        XCTAssertEqual(session.state, .failed)
        backing.failWrites = false
        XCTAssertEqual(backing.lookup(contactId: "ned"), .absent)
    }

    /// A learning that works is still saved, and reported, as before.
    func testAUsableEmbeddingIsStillSavedAndReported() {
        let template = [Float](repeating: 0.5, count: 512)
        let (session, backing) = makeSession(embedder: FixedVectorEmbedder(template))
        learn(session, contactId: "ola")
        XCTAssertEqual(session.state, .completed(contactId: "ola"))
        XCTAssertEqual(backing.lookup(contactId: "ola"), .present(template))
    }
}

/// An embedder that answers every window with the same vector, whatever the
/// audio: the way to hand the learning a zero or a NaN vector.
private final class FixedVectorEmbedder: SpeakerEmbedding, @unchecked Sendable {
    static let embeddingDimension = 512
    private let vector: [Float]
    init(_ vector: [Float]) { self.vector = vector }
    func embed(pcm16kMono: [Float]) throws -> [Float] { vector }
}

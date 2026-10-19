import XCTest
@testable import QAudionEngine

private final class VerifierCount: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// Two rules of the per-contact check, on the real verifier with the
/// deterministic stand-in for the neural model:
///  - a profile that cannot be read is neither learned again nor written over;
///  - a change of media path starts the in-call reference over.
final class ContactVoiceVerifierProfileAndPathTests: XCTestCase {

    private let flag = AppBackgroundFlag()

    private func tone() -> [Float] {
        (0..<16_000).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / 16_000)) }
    }

    private func makeVerifier(store: VoiceprintStore) -> ContactVoiceVerifier {
        let noTimer: BackgroundAwareTimer.Arm = { _, _, _, _ in {} }
        return ContactVoiceVerifier(
            embedder: DeterministicTestEmbedder(), store: store, cohortNormalizer: nil, backgroundFlag: flag,
            foregroundIntervalSeconds: 3, backgroundIntervalSeconds: 10, armTimer: noTimer)
    }

    private func feedSpeech(_ verifier: ContactVoiceVerifier, frames: Int) {
        for _ in 0..<frames {
            verifier.feedContinuous(TestAudioHelpers.makeSinePCM(frequency: 440, sampleCount: AudioConstants.samplesPerFrame))
        }
    }

    /// Runs one scoring tick and waits until its score has been delivered.
    private func runTick(_ verifier: ContactVoiceVerifier, delivered: VerifierCount) {
        let before = delivered.value
        verifier.runTickForTesting()
        let deadline = Date().addingTimeInterval(10)
        while delivered.value == before && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        verifier.drainForTesting()
    }

    // MARK: - A profile that cannot be read

    /// The store refuses the read: the check still runs for this call (the
    /// voice at the start of the call serves as its template, in memory), and
    /// the profile that could not be read is not written over.
    func testAnUnreadableProfileIsNotWrittenOverByTheCheck() throws {
        let backing = InMemoryVoiceprintBacking()
        let store = VoiceprintStore(backing: backing)
        let profile = try DeterministicTestEmbedder().embed(pcm16kMono: tone())
        XCTAssertTrue(store.save(contactId: "alice", template: profile))

        backing.failReads = true
        let verifier = makeVerifier(store: store)
        verifier.setActiveContact("alice")
        feedSpeech(verifier, frames: 160)
        verifier.deactivate()

        backing.failReads = false
        XCTAssertEqual(backing.lookup(contactId: "alice"), .present(profile), "the profile is as it was")
        XCTAssertEqual(backing.listContacts(), ["alice"])
    }

    /// With no profile at all the check learns in memory only: it never writes
    /// the store. Saving belongs to the learning session, which the app starts
    /// only for a contact the store reports as absent.
    func testTheCheckNeverWritesTheStore() {
        let backing = InMemoryVoiceprintBacking()
        let verifier = makeVerifier(store: VoiceprintStore(backing: backing))
        verifier.setActiveContact("bob")
        feedSpeech(verifier, frames: 160)
        verifier.deactivate()
        XCTAssertTrue(backing.listContacts().isEmpty)
        XCTAssertEqual(backing.lookup(contactId: "bob"), .absent)
    }

    // MARK: - A change of media path

    /// `acousticPathChanged()` discards the detector's reference: a steady
    /// verdict goes back to unknown while the reference is rebuilt, so a
    /// network event is not reported as a person walking in.
    func testAPathChangeStartsTheInCallReferenceOver() throws {
        let backing = InMemoryVoiceprintBacking()
        let store = VoiceprintStore(backing: backing)
        XCTAssertTrue(store.save(contactId: "alice", template: try DeterministicTestEmbedder().embed(pcm16kMono: tone())))
        let verifier = makeVerifier(store: store)
        let delivered = VerifierCount()
        verifier.onScoreUpdated = { _ in delivered.bump() }
        verifier.setActiveContact("alice")
        feedSpeech(verifier, frames: 60)

        // The detector needs six scores for its reference, then one more to be steady.
        for _ in 0..<8 { runTick(verifier, delivered: delivered) }
        XCTAssertEqual(verifier.speakerChangeVerdict.level, .steady)

        verifier.acousticPathChanged()
        runTick(verifier, delivered: delivered)
        XCTAssertEqual(verifier.speakerChangeVerdict.level, .unknown, "the reference is being rebuilt")
    }
}

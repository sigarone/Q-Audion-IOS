import XCTest
@testable import QAudionEngine

private final class PdCount: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// While protected data is unavailable the voice check runs no tick; it picks up again once data is readable.
final class ProtectedDataGateTests: XCTestCase {

    private func makeVerifier(protectedData: ProtectedDataFlag) throws -> ContactVoiceVerifier {
        let noTimer: BackgroundAwareTimer.Arm = { _, _, _, _ in {} }
        let embedder = DeterministicTestEmbedder()
        let tone: [Float] = (0..<16_000).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / 16_000)) }
        let store = VoiceprintStore(backing: InMemoryVoiceprintBacking())
        store.save(contactId: "alice", template: try embedder.embed(pcm16kMono: tone))
        let verifier = ContactVoiceVerifier(
            embedder: embedder, store: store, cohortNormalizer: nil, backgroundFlag: AppBackgroundFlag(),
            protectedData: protectedData, foregroundIntervalSeconds: 3, backgroundIntervalSeconds: 10,
            armTimer: noTimer)
        verifier.setActiveContact("alice")
        for _ in 0..<60 {
            verifier.feedContinuous(TestAudioHelpers.makeSinePCM(frequency: 440, sampleCount: AudioConstants.samplesPerFrame))
        }
        return verifier
    }

    func testFlagReportsChangesOnly() {
        let flag = ProtectedDataFlag()
        XCTAssertTrue(flag.isAvailable)
        XCTAssertFalse(flag.set(isAvailable: true))
        XCTAssertTrue(flag.set(isAvailable: false))
        XCTAssertFalse(flag.isAvailable)
        XCTAssertTrue(flag.set(isAvailable: true))
    }

    func testNoTickWhileLockedAndResumesAfterUnlock() throws {
        let flag = ProtectedDataFlag()
        let verifier = try makeVerifier(protectedData: flag)
        let delivered = PdCount()
        verifier.onScoreUpdated = { _ in delivered.bump() }

        flag.set(isAvailable: false)
        for _ in 0..<3 { verifier.runTickForTesting() }
        verifier.drainForTesting()
        XCTAssertEqual(delivered.value, 0, "no inference while protected data is unavailable")

        flag.set(isAvailable: true)
        verifier.runTickForTesting()
        let deadline = Date().addingTimeInterval(10)
        while delivered.value == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        verifier.drainForTesting()
        XCTAssertEqual(delivered.value, 1, "the next tick after the unlock runs")
    }
}

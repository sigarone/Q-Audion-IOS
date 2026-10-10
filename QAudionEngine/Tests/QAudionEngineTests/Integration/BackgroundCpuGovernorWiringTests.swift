import XCTest
@testable import QAudionEngine

private final class GovCount: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

private final class GovGuardianClock: @unchecked Sendable {
    var ms: Int64 = 0
}

/// A held tick delivers nothing: the last score stays, no result is added to or taken from a run of results, no
/// alert can come out of it. In the foreground the governor is not there at all.
final class BackgroundCpuGovernorWiringTests: XCTestCase {

    private let flag = AppBackgroundFlag()
    private let world = GovWorld()

    /// Brings `governor` to "holding back", with the last tick that ran at t = 10 and now t = 20.
    private func holdBack(_ governor: BackgroundCpuGovernor) {
        flag.set(isInBackground: true)
        _ = governor.decide()                       // t = 0 runs
        world.advance(10, cores: 0.9)
        _ = governor.decide()                       // t = 10 runs
        world.advance(10, cores: 0.9)
        XCTAssertFalse(governor.decide().run)       // t = 20: judged, held back
        XCTAssertTrue(governor.isHoldingBack)
    }

    // MARK: Tier 2 (ContactVoiceVerifier)

    private func makeTier2(governor: BackgroundCpuGovernor) throws -> ContactVoiceVerifier {
        let noTimer: BackgroundAwareTimer.Arm = { _, _, _, _ in {} }
        let embedder = DeterministicTestEmbedder()
        let tone: [Float] = (0..<16_000).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / 16_000)) }
        let store = VoiceprintStore(backing: InMemoryVoiceprintBacking())
        let template = try embedder.embed(pcm16kMono: tone)
        store.save(contactId: "alice", template: template)
        let verifier = ContactVoiceVerifier(
            embedder: embedder, store: store, cohortNormalizer: nil, backgroundFlag: flag,
            foregroundIntervalSeconds: 3, backgroundIntervalSeconds: 10, armTimer: noTimer, governor: governor)
        verifier.setActiveContact("alice")
        for _ in 0..<60 {
            verifier.feedContinuous(TestAudioHelpers.makeSinePCM(frequency: 440, sampleCount: AudioConstants.samplesPerFrame))
        }
        return verifier
    }

    /// Runs one tick and waits for its score to be delivered.
    private func runTick(_ verifier: ContactVoiceVerifier, delivered: GovCount) {
        let before = delivered.value
        verifier.runTickForTesting()
        let deadline = Date().addingTimeInterval(10)
        while delivered.value == before && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        verifier.drainForTesting()
    }

    func testAHeldTier2TickDeliversNothingAndLeavesEveryResultAsItWas() throws {
        let governor = world.governor(flag: flag)
        let verifier = try makeTier2(governor: governor)
        let delivered = GovCount()
        verifier.onScoreUpdated = { _ in delivered.bump() }
        let breakdowns = GovCount()
        verifier.onScoreBreakdown = { _, _, _, _ in breakdowns.bump() }

        // One tick in the foreground: the governor is out of the picture and the tick runs.
        runTick(verifier, delivered: delivered)
        XCTAssertEqual(delivered.value, 1)
        let levelBefore = verifier.level
        let verdictBefore = verifier.speakerChangeVerdict
        XCTAssertEqual(governor.totals, BackgroundCpuGovernor.Totals(), "the foreground must not be counted")

        holdBack(governor)
        let skippedBefore = governor.totals.skipped
        world.advance(5, cores: 0.9)   // t = 25: 15 s after the last tick that ran, under the 30 s floor
        for _ in 0..<3 { verifier.runTickForTesting() }
        verifier.drainForTesting()

        XCTAssertEqual(governor.totals.skipped, skippedBefore + 3, "the governor was asked and held every tick back")
        XCTAssertEqual(delivered.value, 1, "no score for a held tick")
        XCTAssertEqual(breakdowns.value, 1)
        XCTAssertEqual(verifier.level, levelBefore, "the voiceprint run of results is untouched")
        XCTAssertEqual(verifier.speakerChangeVerdict, verdictBefore)
    }

    func testTheFloorLetsATier2TickThroughAfterThirtySeconds() throws {
        let governor = world.governor(flag: flag)
        let verifier = try makeTier2(governor: governor)
        let delivered = GovCount()
        verifier.onScoreUpdated = { _ in delivered.bump() }

        holdBack(governor)                // last tick that ran: t = 10, now t = 20
        world.advance(20, cores: 0.9)     // t = 40: 30 s after t = 10
        runTick(verifier, delivered: delivered)
        XCTAssertEqual(delivered.value, 1, "one tick per 30 s still runs while holding back")
    }

    func testTier2RunsAgainAfterTheLoadComesDown() throws {
        let governor = world.governor(flag: flag)
        let verifier = try makeTier2(governor: governor)
        let delivered = GovCount()
        verifier.onScoreUpdated = { _ in delivered.bump() }

        holdBack(governor)
        var tickAt = 20
        while governor.isHoldingBack && tickAt < 200 {
            world.advance(10, cores: 0.05)
            tickAt += 10
            _ = governor.decide()
        }
        XCTAssertFalse(governor.isHoldingBack)
        world.advance(10, cores: 0.05)
        runTick(verifier, delivered: delivered)
        XCTAssertEqual(delivered.value, 1)
    }

    func testTier2NeverHoldsATickBackInTheForeground() throws {
        let meterReads = GovCount()
        let world = self.world
        let governor = BackgroundCpuGovernor(
            config: .standard, flag: flag, clock: { world.time },
            cpuSeconds: { meterReads.bump(); return 1e9 })
        let verifier = try makeTier2(governor: governor)
        let delivered = GovCount()
        verifier.onScoreUpdated = { _ in delivered.bump() }
        for _ in 0..<3 {
            world.advance(3, cores: 50)
            runTick(verifier, delivered: delivered)
        }
        XCTAssertEqual(delivered.value, 3)
        XCTAssertEqual(meterReads.value, 0)
    }

    // MARK: Tier 1 (GuardianMode)

    private func voiced(samples: Int) -> Data {
        let bits = UInt16(bitPattern: 4000)
        var bytes = [UInt8](repeating: 0, count: samples * 2)
        for i in 0..<samples {
            bytes[2 * i] = UInt8(bits & 0xFF)
            bytes[2 * i + 1] = UInt8(bits >> 8)
        }
        return Data(bytes)
    }

    private func makeTier1(
        governor: BackgroundCpuGovernor, scored: GovCount, clock: GovGuardianClock = GovGuardianClock()
    ) -> GuardianMode {
        GuardianMode(
            scorer: { _ in scored.bump(); return 0.95 },
            executor: { job in job() },
            nowMs: { clock.ms },
            governor: governor)
    }

    /// One whole 4.04 s window of voiced audio.
    private func feedWindow(_ guardian: GuardianMode) {
        guardian.processFrame(voiced(samples: GuardianWindowAccumulator.defaultWindowSamples))
    }

    func testAHeldTier1WindowIsNotScoredAndChangesNothing() {
        let governor = world.governor(flag: flag)
        let scored = GovCount()
        let guardian = makeTier1(governor: governor, scored: scored)
        var alerts = 0
        guardian.onAlert = { _, _ in alerts += 1 }
        let scoreBefore = guardian.getConfidenceIndex().currentScore
        let historyBefore = guardian.getConfidenceIndex().scoreHistory

        holdBack(governor)               // last tick that ran: t = 10, now t = 20
        world.advance(5, cores: 0.9)     // t = 25
        feedWindow(guardian)             // window 1: held (15 s since the last tick that ran)
        world.advance(10, cores: 0.9)    // t = 35
        feedWindow(guardian)             // window 2: held (25 s)

        XCTAssertEqual(scored.value, 0, "a held window is not scored")
        XCTAssertEqual(guardian.tier1Stats.windowsHeld, 2)
        XCTAssertEqual(guardian.tier1Stats.inferences, 0)
        XCTAssertEqual(guardian.tier1Stats.windowsSkipped, 0,
                       "held is not the 8 s spacing: the schedule was not advanced by a window nobody scored")
        XCTAssertEqual(guardian.getConfidenceIndex().currentScore, scoreBefore)
        XCTAssertEqual(guardian.getConfidenceIndex().scoreHistory, historyBefore)
        XCTAssertEqual(alerts, 0)

        world.advance(10, cores: 0.9)    // t = 45: 35 s after the last tick that ran, past the floor
        feedWindow(guardian)             // window 3: runs, and is scored right away
        XCTAssertEqual(scored.value, 1)
        XCTAssertEqual(guardian.tier1Stats.windowsHeld, 2)
        XCTAssertEqual(guardian.tier1Stats.inferences, 1)
        XCTAssertEqual(guardian.tier1Stats.windowsSkipped, 0)
        XCTAssertEqual(alerts, 0)
    }

    func testTier1KeepsItsOwnSpacingOnceItRuns() {
        // After a window was scored the usual 8 s of voice between two inferences applies, held back or not.
        let governor = world.governor(flag: flag)
        let scored = GovCount()
        let guardian = makeTier1(governor: governor, scored: scored)
        flag.set(isInBackground: true)
        feedWindow(guardian)             // window 1: scored
        feedWindow(guardian)             // window 2: under 8 s after it: spacing, not the governor
        XCTAssertEqual(scored.value, 1)
        XCTAssertEqual(guardian.tier1Stats.windowsSkipped, 1)
        XCTAssertEqual(guardian.tier1Stats.windowsHeld, 0)
        feedWindow(guardian)             // window 3: eligible again
        XCTAssertEqual(scored.value, 2)
    }

    func testTier1NeverHoldsAWindowBackInTheForeground() {
        let meterReads = GovCount()
        let world = self.world
        let governor = BackgroundCpuGovernor(
            config: .standard, flag: flag, clock: { world.time },
            cpuSeconds: { meterReads.bump(); return 1e9 })
        let scored = GovCount()
        let guardian = makeTier1(governor: governor, scored: scored)
        for _ in 0..<5 {
            world.advance(4, cores: 50)
            feedWindow(guardian)
        }
        // Windows 1, 3 and 5 are scored (one in two); none is held.
        XCTAssertEqual(scored.value, 3)
        XCTAssertEqual(guardian.tier1Stats.windowsHeld, 0)
        XCTAssertEqual(meterReads.value, 0)
    }

    func testTier1WithoutAGovernorIsUnchanged() {
        let scored = GovCount()
        let guardian = GuardianMode(scorer: { _ in scored.bump(); return 0.95 }, executor: { job in job() }, nowMs: { 0 })
        flag.set(isInBackground: true)
        for _ in 0..<3 { feedWindow(guardian) }
        XCTAssertEqual(scored.value, 2)
        XCTAssertEqual(guardian.tier1Stats.windowsHeld, 0)
    }
}

import XCTest
@testable import QAudionEngine

/// W-GUARDIAN1CONTIG (2026-10-07) — Tier 1 (`GuardianMode`) gets every voiced chunk, contiguous, at any chunk
/// length, scores non-overlapping 4.04 s windows with one inference in flight and no backlog, and keeps the
/// alarm semantics (5 s of sustained red, 30 s cooldown, no score invented, silence ignored).
///
/// Deterministic: the scorer, the executor and the clock are injected; no model, no queue, no device. The
/// expected numbers are worked out in the comments, not recomputed with the code under test.
///
/// On the previous main these could not pass: `GuardianMode` forwarded ONE chunk per 100 ms of audio to
/// `VoiceprintAnalyzer` (600 of 6 000 chunks of 10 ms), whose window kept 50% overlap, so a 10 ms chunk stream
/// needed ~40 s of voiced audio for the first score; the model and the clock could not be injected at all.
final class GuardianTier1ContiguityTests: XCTestCase {

    // MARK: - fixtures

    private let window = GuardianWindowAccumulator.defaultWindowSamples   // 64 600 * 3 = 193 800

    /// Sample `g` of a voiced test stream: alternating sign, magnitude 1000...5999, so RMS > 0.03 (the VAD
    /// threshold is 360/32768 = 0.011) and every position is identifiable.
    private func value(_ g: Int) -> Int16 {
        let magnitude = 1000 + g % 5000
        return Int16(g % 2 == 0 ? magnitude : -magnitude)
    }

    private func expected(_ g: Int) -> Float { Float(value(g)) / 32_768.0 }

    /// Little-endian Int16 bytes of stream samples `start ..< start + samples`.
    private func chunk(from start: Int, samples: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: samples * 2)
        for i in 0..<samples {
            let bits = UInt16(bitPattern: value(start + i))
            bytes[2 * i] = UInt8(bits & 0xFF)
            bytes[2 * i + 1] = UInt8(bits >> 8)
        }
        return Data(bytes)
    }

    private func constantChunk(_ v: Int16, samples: Int) -> Data {
        let bits = UInt16(bitPattern: v)
        var bytes = [UInt8](repeating: 0, count: samples * 2)
        for i in 0..<samples {
            bytes[2 * i] = UInt8(bits & 0xFF)
            bytes[2 * i + 1] = UInt8(bits >> 8)
        }
        return Data(bytes)
    }

    private final class ManualExecutor: @unchecked Sendable {
        var jobs: [@Sendable () -> Void] = []
        var maxPending = 0
        func submit(_ job: @escaping @Sendable () -> Void) {
            jobs.append(job)
            maxPending = max(maxPending, jobs.count)
        }
        func runNext() { jobs.removeFirst()() }
    }

    private final class ScorerProbe: @unchecked Sendable {
        var lengths: [Int] = []
        var firstSamples: [Float] = []
        var next: Float? = 0.97
    }

    private final class TestClock: @unchecked Sendable {
        var ms: Int64 = 0
    }

    private func makeGuardian(
        probe: ScorerProbe, clock: TestClock = TestClock(), executor: ManualExecutor? = nil
    ) -> GuardianMode {
        let exec: GuardianMode.Executor
        if let executor {
            exec = { job in executor.submit(job) }
        } else {
            exec = { job in job() }
        }
        return GuardianMode(
            scorer: { w in
                probe.lengths.append(w.count)
                probe.firstSamples.append(w[0])
                return probe.next
            },
            executor: exec,
            nowMs: { clock.ms }
        )
    }

    // MARK: - the accumulator: contiguous, every chunk length, silence ignored

    /// 10 ms native-SRTP chunks (480 samples): 403 chunks are 193 440 samples, short of the 193 800 window; the
    /// 404th completes it with 360 of its samples and carries the other 120. The window is exactly samples
    /// 0...193 799 of the stream, in order, and the next one starts at 193 800.
    func testTenMsChunksReachTheWindowWholeAndInOrder() {
        var acc = GuardianWindowAccumulator()
        var g = 0
        for _ in 0..<403 {
            XCTAssertTrue(acc.append(int16LE: chunk(from: g, samples: 480)).isEmpty)
            g += 480
        }
        XCTAssertEqual(acc.pendingSamples, 193_440)

        let first = acc.append(int16LE: chunk(from: g, samples: 480))
        g += 480
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].count, window)
        var mismatches = 0
        for k in 0..<window where first[0][k] != expected(k) { mismatches += 1 }
        XCTAssertEqual(mismatches, 0, "every sample of the stream, in order, no gap")
        XCTAssertEqual(acc.pendingSamples, 120, "the crossing chunk's remainder is carried, not dropped")

        var second: [[Float]] = []
        while second.isEmpty {
            second = acc.append(int16LE: chunk(from: g, samples: 480))
            g += 480
        }
        XCTAssertEqual(second[0][0], expected(window), "no overlap: the next window starts where the last ended")
        XCTAssertEqual(second[0][window - 1], expected(2 * window - 1))
    }

    /// 60 s of voiced audio is 2 880 000 samples = 14 windows + 166 800 pending, at 10, 20 and 60 ms chunks
    /// alike: one window per 4.0375 s of voiced audio whatever the transport.
    func testWindowCadenceIsTheSameForTenTwentyAndSixtyMsChunks() {
        for chunkSamples in [480, 960, 2880] {
            var acc = GuardianWindowAccumulator()
            var windows = 0
            var g = 0
            while g < 60 * 48_000 {
                windows += acc.append(int16LE: chunk(from: g, samples: chunkSamples)).count
                g += chunkSamples
            }
            XCTAssertEqual(windows, 14, "chunk of \(chunkSamples) samples")
            XCTAssertEqual(acc.pendingSamples, 166_800, "chunk of \(chunkSamples) samples")
            XCTAssertEqual(acc.voicedChunks, 60 * 48_000 / chunkSamples)
        }
    }

    /// Silent chunks (all zero, and a steady level just under the gate: 300/32768 = 0.0092 < 0.0110) add
    /// nothing; the window holds the voiced samples only, back to back.
    func testSilenceNeitherFeedsTheWindowNorCountsTowardIt() {
        var acc = GuardianWindowAccumulator()
        var g = 0
        var produced: [[Float]] = []
        var silentFed = 0
        while produced.isEmpty {
            XCTAssertTrue(acc.append(int16LE: constantChunk(0, samples: 480)).isEmpty)
            XCTAssertTrue(acc.append(int16LE: constantChunk(300, samples: 480)).isEmpty)
            silentFed += 2
            produced = acc.append(int16LE: chunk(from: g, samples: 480))
            g += 480
        }
        XCTAssertEqual(g, 404 * 480, "only voiced samples count toward the window")
        XCTAssertEqual(acc.silentChunks, silentFed)
        XCTAssertEqual(produced[0][0], expected(0))
        XCTAssertEqual(produced[0][window - 1], expected(window - 1))
        // Just over the gate (400/32768 = 0.0122) is voice.
        XCTAssertTrue(acc.append(int16LE: constantChunk(400, samples: 480)).isEmpty)
        XCTAssertEqual(acc.silentChunks, silentFed)
    }

    // MARK: - GuardianMode: first inference, one in flight, no backlog

    func testFirstInferenceAfterExactlyOneWindowOfVoicedTenMsAudio() {
        let probe = ScorerProbe()
        let guardian = makeGuardian(probe: probe)
        var g = 0
        for _ in 0..<403 {
            guardian.processFrame(chunk(from: g, samples: 480))
            g += 480
        }
        XCTAssertTrue(probe.lengths.isEmpty, "no inference before a full window (4.0375 s of voiced audio)")
        guardian.processFrame(chunk(from: g, samples: 480))
        XCTAssertEqual(probe.lengths, [window])
        XCTAssertEqual(guardian.getConfidenceIndex().scoreHistory.count, 1)
        XCTAssertEqual(guardian.tier1Stats.inferences, 1)
    }

    /// Three windows complete while the first inference is still running: one job is submitted, the two later
    /// windows are dropped (not queued), and the next job after it finishes scores FRESH audio.
    func testOneInferenceInFlightAndNoBacklog() {
        let probe = ScorerProbe()
        let executor = ManualExecutor()
        let guardian = makeGuardian(probe: probe, executor: executor)
        var g = 0
        for _ in 0..<1212 {                       // 1212 * 480 = 581 760 >= 3 * 193 800
            guardian.processFrame(chunk(from: g, samples: 480))
            g += 480
        }
        XCTAssertEqual(executor.jobs.count, 1)
        XCTAssertEqual(executor.maxPending, 1)
        var s = guardian.tier1Stats
        XCTAssertEqual(s.windowsReady, 3)
        XCTAssertEqual(s.windowsDropped, 2)
        XCTAssertTrue(s.inferenceInFlight)

        executor.runNext()
        s = guardian.tier1Stats
        XCTAssertFalse(s.inferenceInFlight)
        XCTAssertEqual(s.inferences, 1)
        XCTAssertEqual(probe.firstSamples, [expected(0)])

        while executor.jobs.isEmpty {             // the 4th window
            guardian.processFrame(chunk(from: g, samples: 480))
            g += 480
        }
        XCTAssertEqual(executor.maxPending, 1)
        executor.runNext()
        XCTAssertEqual(probe.firstSamples, [expected(0), expected(3 * window)], "the 4th window, not a stale one")
        XCTAssertEqual(guardian.tier1Stats.inferences, 2)
    }

    /// No real score (model not loaded, inference error): nothing enters the EMA or the wave, and the next
    /// window is still accepted.
    func testNilScoreLeavesTheIndexUntouched() {
        let probe = ScorerProbe()
        probe.next = nil
        let guardian = makeGuardian(probe: probe)
        var g = 0
        while probe.lengths.count < 2 {
            guardian.processFrame(chunk(from: g, samples: 480))
            g += 480
        }
        let ci = guardian.getConfidenceIndex()
        XCTAssertEqual(ci.currentScore, 0.5)
        XCTAssertTrue(ci.scoreHistory.isEmpty)
        XCTAssertEqual(guardian.tier1Stats.nilScores, 2)
        XCTAssertFalse(guardian.tier1Stats.inferenceInFlight)
    }

    func testDisabledGuardianTakesNoAudio() {
        let probe = ScorerProbe()
        let guardian = makeGuardian(probe: probe)
        guardian.setEnabled(false)
        var g = 0
        for _ in 0..<500 {
            guardian.processFrame(chunk(from: g, samples: 480))
            g += 480
        }
        XCTAssertTrue(probe.lengths.isEmpty)
        XCTAssertEqual(guardian.tier1Stats.pendingSamples, 0)
    }

    // MARK: - alarm semantics: 5 s of sustained red, 30 s cooldown

    /// Score 0.0 on every window, one window per 4 038 ms. EMA (alpha 0.1, seed 0.5) = 0.5 * 0.9^n: 0.2657 at
    /// n = 6 (yellow, >= 0.25), 0.2391 at n = 7 (red; run starts at t = 6 * 4038 = 24 228). Alert when the run
    /// is >= 5 s old: n = 8 is 4 038 ms in (no), n = 9 is 8 076 ms in (alert at t = 32 304). Next alert needs
    /// 30 s since that one: t >= 62 304, first reached at n = 17 (t = 64 608).
    func testSustainedRedAlarmAfterFiveSecondsThenThirtySecondCooldown() {
        let probe = ScorerProbe()
        probe.next = 0.0
        let clock = TestClock()
        let guardian = makeGuardian(probe: probe, clock: clock)
        var alertsAt: [Int] = []
        guardian.onAlert = { level, _ in
            XCTAssertEqual(level, .red)
            alertsAt.append(probe.lengths.count)
        }
        var g = 0
        for n in 1...20 {
            clock.ms = Int64(n - 1) * 4038
            while probe.lengths.count < n {
                guardian.processFrame(chunk(from: g, samples: 2880))   // 60 ms chunks: cadence is not under test here
                g += 2880
            }
        }
        XCTAssertEqual(alertsAt, [9, 17])
    }

    /// A non-red update ends the run. Scores 0.0 except 0.6 / 0.7 / 0.8 / 0.9 at n = 9 / 12 / 15 / 18, one
    /// window per 4 038 ms. EMA: red at n = 7, 8 (0.2391, 0.2152), yellow at n = 9 (0.2537), red at 10, 11,
    /// yellow at 12 (0.2550), red at 13, 14, yellow at 15, red at 16, 17, yellow at 18, 19. Every red run is two
    /// updates = 4 038 ms < 5 s: no alert. If a yellow update did NOT restart the run, the run begun at n = 7
    /// would be 12 114 ms old at n = 10 and alert there.
    func testNonRedUpdateRestartsTheFiveSecondRun() {
        let probe = ScorerProbe()
        let clock = TestClock()
        let guardian = makeGuardian(probe: probe, clock: clock)
        var alerts = 0
        guardian.onAlert = { _, _ in alerts += 1 }
        var g = 0
        let recoveries: [Int: Float] = [9: 0.6, 12: 0.7, 15: 0.8, 18: 0.9]
        for n in 1...19 {
            clock.ms = Int64(n - 1) * 4038
            probe.next = recoveries[n] ?? 0.0
            while probe.lengths.count < n {
                guardian.processFrame(chunk(from: g, samples: 2880))   // 60 ms chunks: cadence is not under test here
                g += 2880
            }
        }
        XCTAssertEqual(alerts, 0)
    }
}

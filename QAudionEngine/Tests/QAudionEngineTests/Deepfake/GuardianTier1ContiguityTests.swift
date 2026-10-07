import XCTest
@testable import QAudionEngine

/// W-GUARDIAN1CONTIG (2026-10-07) — Tier 1 (`GuardianMode`) gets every voiced chunk, contiguous, at any chunk
/// length, builds non-overlapping 4.04 s windows, scores at most one window per 8 s of voiced audio
/// (`minVoicedMsBetweenInferences`) with one inference in flight and no backlog, and keeps the alarm semantics
/// (5 s of sustained red, 30 s cooldown, no score invented, silence ignored).
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
        probe: ScorerProbe, clock: TestClock = TestClock(), executor: ManualExecutor? = nil,
        scorerAvailable: Bool = true
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
            scorerAvailable: scorerAvailable,
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

    // MARK: - GuardianMode: first inference, 8 s interval, one in flight, no backlog

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

    /// 60 s of voiced 10 ms audio completes 14 windows (see the cadence test). The interval is 8 000 ms =
    /// 384 000 samples; windows end every 193 800 samples, so after a scored window the next one (193 800 later)
    /// is skipped and the one after (387 600 later, 8.075 s) is scored: windows 1, 3, 5, 7, 9, 11, 13, i.e. 7
    /// inferences and 7 skipped. Each scored window starts at sample (k - 1) * 193 800.
    func testInferencesAreAtLeastEightSecondsOfVoicedAudioApart() {
        XCTAssertEqual(GuardianMode.minVoicedMsBetweenInferences, 8_000)
        let probe = ScorerProbe()
        let guardian = makeGuardian(probe: probe)
        var g = 0
        while g < 60 * 48_000 {
            guardian.processFrame(chunk(from: g, samples: 480))
            g += 480
        }
        let s = guardian.tier1Stats
        XCTAssertEqual(s.windowsReady, 14)
        XCTAssertEqual(s.inferences, 7)
        XCTAssertEqual(s.windowsSkipped, 7)
        XCTAssertEqual(s.windowsDropped, 0)
        XCTAssertEqual(probe.firstSamples, [1, 3, 5, 7, 9, 11, 13].map { expected(($0 - 1) * window) })
    }

    /// The first inference is still running when window 3 (the next eligible one) completes: it is dropped,
    /// not queued (window 2 was already skipped by the interval). Once the job finishes, window 4 (3 * 193 800
    /// samples after window 1 ended, past the interval) is scored: FRESH audio, never a stale window.
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
        XCTAssertEqual(s.windowsSkipped, 1)
        XCTAssertEqual(s.windowsDropped, 1)
        XCTAssertTrue(s.inferenceInFlight)

        executor.runNext()
        s = guardian.tier1Stats
        XCTAssertFalse(s.inferenceInFlight)
        XCTAssertEqual(s.inferences, 1)
        XCTAssertEqual(probe.firstSamples, [expected(0)])

        while executor.jobs.isEmpty {             // window 4
            guardian.processFrame(chunk(from: g, samples: 480))
            g += 480
        }
        XCTAssertEqual(executor.maxPending, 1)
        executor.runNext()
        XCTAssertEqual(probe.firstSamples, [expected(0), expected(3 * window)], "window 4, not a stale one")
        XCTAssertEqual(guardian.tier1Stats.inferences, 2)
    }

    /// No real score (model not loaded, inference error): nothing enters the EMA or the wave, and the next
    /// eligible window is still accepted.
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

    // MARK: - alarm semantics with one score per 8 s: 5 s of sustained red, 30 s cooldown

    /// Score 0.0 on every inference, one inference per 8 075 ms (one window in two). EMA (alpha 0.1, seed 0.5)
    /// = 0.5 * 0.9^n: 0.2657 at n = 6 (yellow, >= 0.25), 0.2391 at n = 7 (red: the first red opens the run at
    /// t = 6 * 8075 = 48 450). The next red, n = 8 at t = 56 525, is 8 075 ms in, >= 5 s: it closes the run and
    /// the alarm fires there. Next alert needs 30 s since that one (t >= 86 525): n = 11 is t = 80 750 (no),
    /// n = 12 is t = 88 825 (alert). So alerts at n = 8, 12, 16, 20.
    func testSustainedRedAlarmFiresOnTheSecondRedScoreEightSecondsLaterThenCooldown() {
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
            clock.ms = Int64(n - 1) * 8075
            while probe.lengths.count < n {
                guardian.processFrame(chunk(from: g, samples: 2880))   // 60 ms chunks: cadence is not under test here
                g += 2880
            }
        }
        XCTAssertEqual(alertsAt, [8, 12, 16, 20])
    }

    /// A non-red update ends the run. Scores 0.0 for n = 1...7, then 0.5 on even n and 0.0 on odd n, one
    /// inference per 8 075 ms. EMA: red at n = 7 (0.2391), yellow at 8 (0.2652), red at 9 (0.2387), yellow at 10
    /// (0.2648), and so on to n = 16 (0.2641): never two red scores in a row, no alert. If a yellow update did
    /// NOT restart the run, the run opened at n = 7 would be 16 150 ms old at n = 9 and alert there.
    func testNonRedUpdateRestartsTheFiveSecondRun() {
        let probe = ScorerProbe()
        let clock = TestClock()
        let guardian = makeGuardian(probe: probe, clock: clock)
        var alerts = 0
        guardian.onAlert = { _, _ in alerts += 1 }
        var g = 0
        for n in 1...16 {
            clock.ms = Int64(n - 1) * 8075
            probe.next = (n > 7 && n % 2 == 0) ? 0.5 : 0.0
            while probe.lengths.count < n {
                guardian.processFrame(chunk(from: g, samples: 2880))   // 60 ms chunks: cadence is not under test here
                g += 2880
            }
        }
        XCTAssertEqual(alerts, 0)
        XCTAssertEqual(guardian.getConfidenceIndex().scoreHistory.count, 16)
    }

    // MARK: - no model, diagnostic line

    /// Without a model (always on the Simulator) the scorer can never score: `processFrame` does no per-chunk
    /// work at all, no VAD, no copy, no hand-off, as before W-GUARDIAN1CONTIG.
    func testNoModelMeansNoPerChunkWork() {
        let probe = ScorerProbe()
        let guardian = makeGuardian(probe: probe, scorerAvailable: false)
        var g = 0
        for _ in 0..<1000 {                        // 480 000 voiced samples, more than two windows
            guardian.processFrame(chunk(from: g, samples: 480))
            g += 480
        }
        XCTAssertTrue(probe.lengths.isEmpty)
        XCTAssertEqual(guardian.tier1Stats, GuardianMode.Tier1Stats())
    }

    /// Exact text of the diagnostic line; `scripts/test_ship_ios_guardian_vocab.py` checks that this shape goes
    /// through the phone-log shipper verbatim (keep both in sync).
    func testDiagnosticLineShape() {
        var s = GuardianMode.Tier1Stats()
        s.inferences = 10
        s.windowsReady = 19
        s.windowsSkipped = 9
        s.windowsDropped = 0
        s.nilScores = 0
        XCTAssertEqual(GuardianMode.diagnosticLine(s, ms: 412),
                       "[Guardian] count=10 ms=412 windows=19 skipped=9 dropped=0 nil=0")
        s.inferences = 0
        s.nilScores = 1
        XCTAssertEqual(GuardianMode.diagnosticLine(s, ms: 3),
                       "[Guardian] count=0 ms=3 windows=19 skipped=9 dropped=0 nil=1")
    }

    /// First occurrence, then every 10th; the nil path uses the same rule on its own counter.
    func testDiagnosticThrottle() {
        XCTAssertEqual((0...31).filter(GuardianMode.isLogged), [1, 10, 20, 30])
    }
}

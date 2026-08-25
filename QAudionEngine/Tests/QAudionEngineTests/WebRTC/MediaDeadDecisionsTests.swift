import XCTest
@testable import QAudionEngine

/// W-MEDIADEAD (2026-08-25) — the written, per-platform test of the Fase B
/// invariant: "a Connected call whose inbound audio has been COMPLETELY
/// absent for 90 s ends itself". Constants and tick semantics are pinned
/// against Android's `CallController` watchdog (poll 15 s, timeout 90 s,
/// freshness window 2× poll on the real-decode stamp).
final class MediaDeadDecisionsTests: XCTestCase {

    private let poll = MediaDeadDecisions.pollMs
    private let timeout = MediaDeadDecisions.timeoutMs

    func test_constants_matchAndroid() {
        XCTAssertEqual(MediaDeadDecisions.pollMs, 15_000)
        XCTAssertEqual(MediaDeadDecisions.timeoutMs, 90_000)
    }

    /// The timeout must sit ABOVE the server's 60 s disconnect-grace ceiling
    /// and the client's 45 s hangup-park budget — the backstop may only fire
    /// after every genuine recovery mechanism has had its full window.
    func test_timeout_sitsAboveEveryRecoveryBudget() {
        XCTAssertGreaterThan(MediaDeadDecisions.timeoutMs, 60_000)
        XCTAssertGreaterThan(MediaDeadDecisions.timeoutMs, 45_000)
    }

    func test_alive_whenRecentRealDecode() {
        let now: Int64 = 1_000_000
        XCTAssertEqual(
            MediaDeadDecisions.evaluate(nowMs: now,
                                        lastAliveAtMs: now - timeout,  // stale baseline —
                                        lastRealDecodeAtMs: now - poll),  // fresh decode wins
            .alive)
    }

    /// The liveness window is exactly 2× the poll: a decode 29 999 ms old is
    /// alive, one 30 000 ms old is not (Android's `< MEDIA_DEAD_POLL_MS * 2`).
    func test_freshnessWindow_boundary() {
        let now: Int64 = 1_000_000
        XCTAssertEqual(
            MediaDeadDecisions.evaluate(nowMs: now, lastAliveAtMs: now - 40_000,
                                        lastRealDecodeAtMs: now - (poll * 2 - 1)),
            .alive)
        XCTAssertEqual(
            MediaDeadDecisions.evaluate(nowMs: now, lastAliveAtMs: now - 40_000,
                                        lastRealDecodeAtMs: now - poll * 2),
            .counting)
    }

    /// A decode stamp of 0 means "never decoded this call" — it must NOT
    /// count as liveness (a call that never produced audio still dies).
    func test_zeroStamp_neverAlive() {
        let now: Int64 = 60_000  // small clock: 0 would be "recent" if compared naively
        XCTAssertEqual(
            MediaDeadDecisions.evaluate(nowMs: now, lastAliveAtMs: now - 10_000,
                                        lastRealDecodeAtMs: 0),
            .counting)
    }

    func test_counting_untilThreshold_dead_atThreshold() {
        let now: Int64 = 10_000_000
        XCTAssertEqual(
            MediaDeadDecisions.evaluate(nowMs: now, lastAliveAtMs: now - (timeout - 1),
                                        lastRealDecodeAtMs: now - 200_000),
            .counting)
        XCTAssertEqual(
            MediaDeadDecisions.evaluate(nowMs: now, lastAliveAtMs: now - timeout,
                                        lastRealDecodeAtMs: now - 200_000),
            .dead)
    }

    /// Concealment must never feed liveness: the contract is enforced at the
    /// write site (the stamp sits behind the AEAD open + Opus decode), and
    /// here by construction — with a stale stamp the verdict decays to dead
    /// no matter how many ticks "produced audio" via PLC.
    func test_staleStamp_decaysToDead() {
        var lastAlive: Int64 = 0
        let decodeAt: Int64 = 0  // never
        var verdictAtEnd: MediaDeadDecisions.Verdict = .counting
        var now: Int64 = 0
        // Simulate the watchdog loop: baseline set at arm (t=0), then ticks.
        for tick in 1...7 {
            now = Int64(tick) * poll
            let v = MediaDeadDecisions.evaluate(nowMs: now, lastAliveAtMs: lastAlive,
                                                lastRealDecodeAtMs: decodeAt)
            if v == .alive { lastAlive = now }
            verdictAtEnd = v
        }
        // 7 ticks × 15 s = 105 s silent ≥ 90 s → dead.
        XCTAssertEqual(verdictAtEnd, .dead)
    }
}

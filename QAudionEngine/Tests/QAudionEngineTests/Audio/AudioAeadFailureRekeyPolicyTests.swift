import XCTest
@testable import QAudionEngine

/// W-AUDIOAEADREKEY (2026-09-02) — B3: unit coverage for the pure burst/
/// cooldown decision logic that gates a mid-call audio re-key request on
/// persistent AEAD decrypt failures. No WebRTC, no clock, no I/O — every
/// case below drives the meter with hand-picked `nowMs` values, same style
/// as `ReKeySchedulerTests`' pure-state-machine coverage.
final class AudioAeadFailureRekeyPolicyTests: XCTestCase {

    // MARK: - AudioAeadFailureRekeyPolicy.isFailureBurst (pure predicate)

    func testIsFailureBurstFalseBelowCount() {
        let times: [Int64] = [0, 100, 200, 300] // one short of failureBurstCount (5)
        XCTAssertFalse(AudioAeadFailureRekeyPolicy.isFailureBurst(failureTimesMs: times, nowMs: 300))
    }

    func testIsFailureBurstTrueWhenFiveLandInsideWindow() {
        let times: [Int64] = [0, 100, 200, 300, 400]
        XCTAssertTrue(AudioAeadFailureRekeyPolicy.isFailureBurst(failureTimesMs: times, nowMs: 400))
    }

    func testIsFailureBurstFalseWhenSpreadPastWindow() {
        // Oldest of the last 5 is 5000ms before nowMs — past the 4000ms window.
        let times: [Int64] = [0, 1000, 2000, 4000, 5000]
        XCTAssertFalse(AudioAeadFailureRekeyPolicy.isFailureBurst(failureTimesMs: times, nowMs: 5000))
    }

    // MARK: - AudioAeadFailureRekeyMeter (mutable ring + cooldown)

    func testNoTriggerForIsolatedFailures() {
        let meter = AudioAeadFailureRekeyMeter()
        // Four failures, each a full second apart — never a burst.
        XCTAssertFalse(meter.noteFailure(nowMs: 0))
        XCTAssertFalse(meter.noteFailure(nowMs: 1000))
        XCTAssertFalse(meter.noteFailure(nowMs: 2000))
        XCTAssertFalse(meter.noteFailure(nowMs: 3000))
    }

    func testTriggersOnFifthFailureWithinBurstWindow() {
        let meter = AudioAeadFailureRekeyMeter()
        XCTAssertFalse(meter.noteFailure(nowMs: 0))
        XCTAssertFalse(meter.noteFailure(nowMs: 50))
        XCTAssertFalse(meter.noteFailure(nowMs: 100))
        XCTAssertFalse(meter.noteFailure(nowMs: 150))
        // 5th failure at 200ms — all five land within the 4s window.
        XCTAssertTrue(meter.noteFailure(nowMs: 200))
    }

    func testCooldownSuppressesImmediateRetrigger() {
        let meter = AudioAeadFailureRekeyMeter()
        for i: Int64 in 0..<4 { _ = meter.noteFailure(nowMs: i * 10) }
        XCTAssertTrue(meter.noteFailure(nowMs: 40)) // first burst fires, ring cleared, cooldown armed

        // A second full burst arrives right away (well under the 10s
        // cooldown). Its shape alone would qualify as a burst, but the
        // cooldown must still suppress the trigger.
        for i: Int64 in 0..<4 { XCTAssertFalse(meter.noteFailure(nowMs: 50 + i * 10)) }
        XCTAssertFalse(meter.noteFailure(nowMs: 90))
    }

    func testTriggersAgainAfterCooldownElapsesWithFreshBurst() {
        let meter = AudioAeadFailureRekeyMeter()
        for i: Int64 in 0..<4 { _ = meter.noteFailure(nowMs: i * 10) }
        XCTAssertTrue(meter.noteFailure(nowMs: 40)) // first burst fires at t=40ms

        // 10s+ later, a fresh burst should fire again.
        let base: Int64 = 40 + AudioAeadFailureRekeyPolicy.retriggerCooldownMs
        for i: Int64 in 0..<4 { XCTAssertFalse(meter.noteFailure(nowMs: base + i * 10)) }
        XCTAssertTrue(meter.noteFailure(nowMs: base + 40))
    }

    func testResetClearsHistoryAndCooldown() {
        let meter = AudioAeadFailureRekeyMeter()
        for i: Int64 in 0..<4 { _ = meter.noteFailure(nowMs: i * 10) }
        XCTAssertTrue(meter.noteFailure(nowMs: 40))

        meter.reset()

        // Immediately after reset, a fresh burst can fire again even though
        // the cooldown window from the pre-reset trigger has not elapsed —
        // reset() means "this is a new call", not "wait out the old clock".
        for i: Int64 in 0..<4 { XCTAssertFalse(meter.noteFailure(nowMs: 50 + i * 10)) }
        XCTAssertTrue(meter.noteFailure(nowMs: 90))
    }
}

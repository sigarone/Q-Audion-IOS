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

    /// W-AUDIOAEADREKEY (2026-09-05) — calibration: `triggerEnabled` was
    /// flipped on with no live-device verification available this session
    /// (see that flag's own doc). This is the one half of that risk this
    /// suite CAN close without a device: ordinary, scattered transient
    /// decrypt noise on an otherwise-healthy call — the kind any real call
    /// sees occasionally (see `CallService`'s own RX catch-block comments) —
    /// must never accumulate to a spurious trigger. Simulates 60 isolated
    /// failures spread every 5s across a 5-minute call. Any gap strictly
    /// greater than `failureBurstWindowMs` (4s) on its own already rules
    /// out a burst for the 2 failures either side of it, so this is a
    /// generous margin on top of the CI-caught arithmetic mistake in an
    /// earlier draft of this test (700ms spacing: 4 gaps of 700ms span only
    /// 2800ms, WELL inside the 4s window — that draft was asserting the
    /// production code must ignore what its own documented threshold
    /// correctly calls a burst, and CI's real XCTest run caught it).
    func testScatteredTransientFailuresNeverSpuriouslyTrigger() {
        let meter = AudioAeadFailureRekeyMeter()
        var t: Int64 = 0
        for _ in 0..<60 {
            XCTAssertFalse(meter.noteFailure(nowMs: t), "spurious trigger at t=\(t)ms from scattered, non-bursty noise")
            t += 5000
        }
    }

    /// The other side of the same calibration: failures spaced just OUTSIDE
    /// the burst window (4001ms apart) individually never qualify even
    /// though there are more than `failureBurstCount` of them in the call's
    /// lifetime — the window, not a lifetime count, is what defines a burst.
    func testFailuresJustOutsideTheBurstWindowNeverAccumulateAcrossACall() {
        let meter = AudioAeadFailureRekeyMeter()
        var t: Int64 = 0
        for _ in 0..<20 {
            XCTAssertFalse(meter.noteFailure(nowMs: t))
            t += AudioAeadFailureRekeyPolicy.failureBurstWindowMs + 1
        }
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

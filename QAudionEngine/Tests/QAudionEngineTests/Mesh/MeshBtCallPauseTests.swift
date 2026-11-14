import XCTest
@testable import QAudionEngine

/// docs/mesh/MESH_LINK_SPEC.md section 2.1: discovery is suspended exactly while a call is active AND its audio uses a
/// Bluetooth device, resumes at once when either stops being true, and is restarted at most once per 5 s when the
/// route flips back and forth. The decision is pure, so every case here is a timeline of (call, route, time).
final class MeshBtCallPauseTests: XCTestCase {

    private typealias Pause = MeshBtCallPause

    private func keep(_ recheckInMs: Int64? = nil) -> Pause.Decision {
        Pause.Decision(action: .keep, recheckInMs: recheckInMs)
    }

    private func resume(_ reason: Pause.ResumeReason, pausedMs: Int64) -> Pause.Decision {
        Pause.Decision(action: .resume(reason: reason, pausedMs: pausedMs))
    }

    // MARK: - Constants and tokens

    func testConstantsAndTokensFollowTheSpecification() {
        XCTAssertEqual(Pause.restartMinIntervalMs, 5_000)
        XCTAssertEqual(Pause.resumeWithinMs, 2_000)
        XCTAssertEqual(Pause.pauseReason, "bt_call_route")
        XCTAssertEqual(Pause.ResumeReason.callEnded.rawValue, "call_ended")
        XCTAssertEqual(Pause.ResumeReason.routeChanged.rawValue, "route_changed")
    }

    // MARK: - When it pauses

    func testNeitherFactAloneEverPauses() {
        var p = Pause()
        XCTAssertEqual(p.evaluate(callActive: false, btRoute: false, nowMs: 0), keep())
        // Bluetooth headphones playing music, no call.
        XCTAssertEqual(p.evaluate(callActive: false, btRoute: true, nowMs: 1_000), keep())
        // A call on the earpiece or the speaker.
        XCTAssertEqual(p.evaluate(callActive: true, btRoute: false, nowMs: 2_000), keep())
        XCTAssertFalse(p.isPaused)
    }

    func testACallOnABluetoothRoutePausesAtOnce() {
        var p = Pause()
        XCTAssertEqual(p.evaluate(callActive: true, btRoute: true, nowMs: 5_000), Pause.Decision(action: .pause))
        XCTAssertTrue(p.isPaused)
    }

    func testTheOrderOfTheTwoFactsDoesNotMatter() {
        // The call starts first, the route follows (the usual order: the audio session comes up after the call).
        var a = Pause()
        XCTAssertEqual(a.evaluate(callActive: true, btRoute: false, nowMs: 0), keep())
        XCTAssertEqual(a.evaluate(callActive: true, btRoute: true, nowMs: 300), Pause.Decision(action: .pause))
        // The headset is already the route when the call starts.
        var b = Pause()
        XCTAssertEqual(b.evaluate(callActive: false, btRoute: true, nowMs: 0), keep())
        XCTAssertEqual(b.evaluate(callActive: true, btRoute: true, nowMs: 300), Pause.Decision(action: .pause))
    }

    func testRepeatedEvaluationsWhilePausedChangeNothing() {
        var p = Pause()
        _ = p.evaluate(callActive: true, btRoute: true, nowMs: 0)
        XCTAssertEqual(p.evaluate(callActive: true, btRoute: true, nowMs: 100), keep())
        XCTAssertEqual(p.evaluate(callActive: true, btRoute: true, nowMs: 60_000), keep())
        XCTAssertTrue(p.isPaused)
    }

    // MARK: - When it resumes

    func testTheCallEndingResumesAtOnceAndSaysSo() {
        var p = Pause()
        _ = p.evaluate(callActive: true, btRoute: true, nowMs: 1_000)
        // The route is still Bluetooth after the hang-up (the stereo profile): the call ending is enough.
        XCTAssertEqual(p.evaluate(callActive: false, btRoute: true, nowMs: 45_000), resume(.callEnded, pausedMs: 44_000))
        XCTAssertFalse(p.isPaused)
    }

    func testTheRouteLeavingBluetoothDuringTheCallResumesAndSaysSo() {
        var p = Pause()
        _ = p.evaluate(callActive: true, btRoute: true, nowMs: 0)
        XCTAssertEqual(p.evaluate(callActive: true, btRoute: false, nowMs: 12_345), resume(.routeChanged, pausedMs: 12_345))
        XCTAssertFalse(p.isPaused)
    }

    func testBothEndingTogetherIsTheCallEnding() {
        var p = Pause()
        _ = p.evaluate(callActive: true, btRoute: true, nowMs: 0)
        XCTAssertEqual(p.evaluate(callActive: false, btRoute: false, nowMs: 30_000), resume(.callEnded, pausedMs: 30_000))
    }

    func testNothingToResumeWhenNeverPaused() {
        var p = Pause()
        XCTAssertEqual(p.evaluate(callActive: false, btRoute: false, nowMs: 0), keep())
        XCTAssertEqual(p.evaluate(callActive: false, btRoute: true, nowMs: 10), keep())
    }

    func testTheFirstResumeIsNeverHeldBack() {
        // Even a pause that lasted a fraction of a second resumes the moment the facts change: the rate limit is
        // about restarts, and there was none before.
        var p = Pause()
        _ = p.evaluate(callActive: true, btRoute: true, nowMs: 100)
        XCTAssertEqual(p.evaluate(callActive: false, btRoute: true, nowMs: 101), resume(.callEnded, pausedMs: 1))
    }

    func testAResumeAfterALongQuietSpellIsImmediate() {
        var p = Pause()
        _ = p.evaluate(callActive: true, btRoute: true, nowMs: 0)
        _ = p.evaluate(callActive: false, btRoute: false, nowMs: 10_000)     // restart at 10 s
        _ = p.evaluate(callActive: true, btRoute: true, nowMs: 60_000)       // a second call, a minute later
        XCTAssertEqual(p.evaluate(callActive: true, btRoute: false, nowMs: 60_200),
                       resume(.routeChanged, pausedMs: 200), "50 s since the last restart: no waiting")
    }

    // MARK: - A route that flips back and forth

    func testFlippingBackAndForthRestartsDiscoveryAtMostOncePerFiveSeconds() {
        var p = Pause()
        XCTAssertEqual(p.evaluate(callActive: true, btRoute: true, nowMs: 0), Pause.Decision(action: .pause))
        // The route leaves Bluetooth: discovery restarts at 1.0 s.
        XCTAssertEqual(p.evaluate(callActive: true, btRoute: false, nowMs: 1_000), resume(.routeChanged, pausedMs: 1_000))
        // It comes back at 1.5 s: pausing is never rate limited.
        XCTAssertEqual(p.evaluate(callActive: true, btRoute: true, nowMs: 1_500), Pause.Decision(action: .pause))
        // It leaves again at 2.0 s: the previous restart was 1 s ago, so the resume waits 4 s more.
        XCTAssertEqual(p.evaluate(callActive: true, btRoute: false, nowMs: 2_000), keep(4_000))
        XCTAssertTrue(p.isPaused)
        // Asked again early, it keeps waiting for the rest of the interval.
        XCTAssertEqual(p.evaluate(callActive: true, btRoute: false, nowMs: 5_999), keep(1))
        // Exactly 5 s after the previous restart it goes, with the time the pause really lasted.
        XCTAssertEqual(p.evaluate(callActive: true, btRoute: false, nowMs: 6_000), resume(.routeChanged, pausedMs: 4_500))
        XCTAssertFalse(p.isPaused)
    }

    func testTheDeferredResumeUsesTheFactsOfTheMomentItIsDue() {
        var p = Pause()
        _ = p.evaluate(callActive: true, btRoute: true, nowMs: 0)
        _ = p.evaluate(callActive: true, btRoute: false, nowMs: 500)         // restart at 0.5 s
        _ = p.evaluate(callActive: true, btRoute: true, nowMs: 800)          // pause
        XCTAssertEqual(p.evaluate(callActive: true, btRoute: false, nowMs: 1_000), keep(4_500))
        // By the time it is due the route is Bluetooth again: nothing resumes, nothing is asked again.
        XCTAssertEqual(p.evaluate(callActive: true, btRoute: true, nowMs: 5_500), keep())
        XCTAssertTrue(p.isPaused)
        // And the call ending later resumes, with the right reason.
        XCTAssertEqual(p.evaluate(callActive: false, btRoute: true, nowMs: 20_000), resume(.callEnded, pausedMs: 19_200))
    }

    func testTheCallEndingWhileARestartIsRateLimitedWaitsToo() {
        var p = Pause()
        _ = p.evaluate(callActive: true, btRoute: true, nowMs: 0)
        _ = p.evaluate(callActive: true, btRoute: false, nowMs: 1_000)       // restart at 1 s
        _ = p.evaluate(callActive: true, btRoute: true, nowMs: 1_200)        // pause
        XCTAssertEqual(p.evaluate(callActive: false, btRoute: true, nowMs: 3_000), keep(3_000))
        XCTAssertEqual(p.evaluate(callActive: false, btRoute: true, nowMs: 6_000), resume(.callEnded, pausedMs: 4_800))
    }

    // MARK: - Antenna off

    func testResetForgetsThePauseAndTheRestartHistory() {
        var p = Pause()
        _ = p.evaluate(callActive: true, btRoute: true, nowMs: 0)
        _ = p.evaluate(callActive: false, btRoute: false, nowMs: 100)        // a restart just now
        _ = p.evaluate(callActive: true, btRoute: true, nowMs: 200)          // paused again
        p.reset()
        XCTAssertFalse(p.isPaused)
        XCTAssertEqual(p, Pause())
        // After the antenna comes back the same facts pause again, and the old restart (at 100 ms) no longer delays
        // the resume.
        XCTAssertEqual(p.evaluate(callActive: true, btRoute: true, nowMs: 300), Pause.Decision(action: .pause))
        XCTAssertEqual(p.evaluate(callActive: false, btRoute: true, nowMs: 400), resume(.callEnded, pausedMs: 100))
    }

    func testAnUnpausedStateNeverResumesByItself() {
        // What keeps an antenna that is off (consent, kill switch, the user's choice) off: with nothing paused no
        // evaluation, however often and whatever the facts, ever asks for a resume.
        var p = Pause()
        for t in stride(from: Int64(0), to: 600_000, by: 7_000) {
            for (call, bt) in [(false, false), (false, true), (true, false)] {
                XCTAssertEqual(p.evaluate(callActive: call, btRoute: bt, nowMs: t), keep())
            }
        }
    }
}

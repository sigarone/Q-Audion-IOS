import XCTest
@testable import QAudionEngine

/// IOS-C4b / W-SRTPFALLBACK — pins the pure fallback-engage/recover logic,
/// same style as `RestartIceDecisionsTests` / Android's
/// `SrtpFallbackTxGateTest.kt`.
final class SrtpFallbackDecisionsTests: XCTestCase {

    private let debounce = SrtpFallbackDecisions.fallbackEngageDebounceMs
    private let edgeAt: Int64 = 100_000

    func test_engages_whenTheOutageHeldForTheWholeDebounce() {
        XCTAssertTrue(SrtpFallbackDecisions.shouldEngageFallback(
            usingNativeAudioSrtp: true,
            iceBad: true,
            iceBadSinceMs: edgeAt,
            nowMs: edgeAt + debounce,
            fallbackAlreadyEngaged: false
        ))
    }

    /// THE fence: a blip that cleared during the debounce must not open a
    /// second capture path.
    func test_doesNotEngage_whenIceRecoveredBeforeTheDebounceExpired() {
        XCTAssertFalse(SrtpFallbackDecisions.shouldEngageFallback(
            usingNativeAudioSrtp: true,
            iceBad: false,
            iceBadSinceMs: edgeAt,
            nowMs: edgeAt + debounce,
            fallbackAlreadyEngaged: false
        ))
    }

    func test_doesNotEngage_beforeTheDebounceHasGenuinelyElapsed() {
        XCTAssertFalse(SrtpFallbackDecisions.shouldEngageFallback(
            usingNativeAudioSrtp: true,
            iceBad: true,
            iceBadSinceMs: edgeAt,
            nowMs: edgeAt + debounce - 1,
            fallbackAlreadyEngaged: false
        ))
    }

    /// Never a second concurrent fallback capture path.
    func test_doesNotDoubleEngage_whileAlreadyEngaged() {
        XCTAssertFalse(SrtpFallbackDecisions.shouldEngageFallback(
            usingNativeAudioSrtp: true,
            iceBad: true,
            iceBadSinceMs: edgeAt,
            nowMs: edgeAt + 10 * debounce,
            fallbackAlreadyEngaged: true
        ))
    }

    func test_doesNotEngage_onACallThatDidNotNegotiateAudioSrtp() {
        // A DataChannel/WS-relay call never bypassed the manual capture
        // path in the first place — nothing to fall back FROM.
        XCTAssertFalse(SrtpFallbackDecisions.shouldEngageFallback(
            usingNativeAudioSrtp: false,
            iceBad: true,
            iceBadSinceMs: edgeAt,
            nowMs: edgeAt + debounce,
            fallbackAlreadyEngaged: false
        ))
    }

    func test_doesNotEngage_whenIceBadSinceIsNil() {
        XCTAssertFalse(SrtpFallbackDecisions.shouldEngageFallback(
            usingNativeAudioSrtp: true,
            iceBad: true,
            iceBadSinceMs: nil,
            nowMs: edgeAt + debounce,
            fallbackAlreadyEngaged: false
        ))
    }

    func test_recovers_whenEngagedAndIceIsNoLongerBad() {
        XCTAssertTrue(SrtpFallbackDecisions.shouldRecoverFromFallback(fallbackEngaged: true, iceBad: false))
    }

    func test_doesNotRecover_whenNotEngaged() {
        XCTAssertFalse(SrtpFallbackDecisions.shouldRecoverFromFallback(fallbackEngaged: false, iceBad: false))
    }

    func test_doesNotRecover_whileIceIsStillBad() {
        XCTAssertFalse(SrtpFallbackDecisions.shouldRecoverFromFallback(fallbackEngaged: true, iceBad: true))
    }

    /// The agreed contract is >= 1 s of continuous degradation before a
    /// second capture path.
    func test_theProductionDebounceIsAtLeastOneSecond() {
        XCTAssertTrue(
            debounce >= 1_000,
            "fallbackEngageDebounceMs must stay >= 1000 ms or a sub-second ICE blip can spin up a second capture path"
        )
    }

    // MARK: - W-SRTPFALLBACKRETRY (2026-08-30)

    /// The live gap: a `.checking` reading at the 1 s mark consumed the
    /// one-shot's only evaluation and the whole outage passed with no
    /// fallback TX. While the streak is alive and nothing has engaged, the
    /// loop must keep evaluating.
    func test_keepsWaitingWhileTheStreakIsAliveAndNothingEngaged() {
        XCTAssertTrue(SrtpFallbackDecisions.shouldKeepWaitingToEngage(streakAlive: true, fallbackAlreadyEngaged: false))
    }

    /// Genuine recovery clears the streak (disarm nils `iceBadSinceMs`) —
    /// the loop must exit rather than idle for the rest of the call.
    func test_stopsWaitingOnceTheStreakIsCleared() {
        XCTAssertFalse(SrtpFallbackDecisions.shouldKeepWaitingToEngage(streakAlive: false, fallbackAlreadyEngaged: false))
    }

    /// After an engage the loop has done its job; a second engage for the
    /// same outage must be impossible from this path.
    func test_stopsWaitingOnceEngaged() {
        XCTAssertFalse(SrtpFallbackDecisions.shouldKeepWaitingToEngage(streakAlive: true, fallbackAlreadyEngaged: true))
        XCTAssertFalse(SrtpFallbackDecisions.shouldKeepWaitingToEngage(streakAlive: false, fallbackAlreadyEngaged: true))
    }
}

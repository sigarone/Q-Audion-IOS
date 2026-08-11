import XCTest
@testable import QAudionEngine

/// W-LONGAUDIO / W-IOSAUDIOSTARVE — the playout depth, which had no test at any
/// frame duration until it shipped a defect to a device.
///
/// Build 1.0.958 was the first long-profile call on a real iPhone, and it came
/// back with interruptions and a metallic timbre. Both traced to one expression:
/// `framesForMs(80, frameDurationMs: 60)` is `max(1, (80 + 30) / 60)` = 1, so
/// the player node held exactly ONE buffer with nothing queued behind the one
/// being rendered. Any late pump left it with nothing to play — literal silence
/// that `PlayoutJitterBuffer` never even counts, because `pop()` is not reached
/// — and the repeat-last-frame concealment that covers it is three times as
/// audible when the frame is 60 ms instead of 20.
///
/// The arithmetic was reviewed twice before that build and read as correct both
/// times, because as a DURATION it is correct: 80 ms is 80 ms. What no one
/// asked was whether one buffer can be pipelined, and the answer does not
/// depend on duration at all. Hence a floor in buffers, and hence this file.
final class PlayoutInFlightTargetTests: XCTestCase {

    /// The regression itself, named so a failure here says what broke.
    func test_atSixtyMs_theTargetIsNotOne() {
        XCTAssertGreaterThanOrEqual(
            AudioCapture.playoutInFlightTarget(forFrameDurationMs: 60), 2,
            "one in-flight buffer cannot be pipelined: the node renders it and " +
            "has nothing queued, so any late pump is an audible dropout")
    }

    /// The floor is a floor, not a replacement: at 20 ms the duration budget is
    /// larger and must keep winning, or this 'fix' would have quietly halved
    /// the hitch absorption W-IOSAUDIOSTARVE bought at 2 → 4.
    func test_atTwentyMs_theDurationBudgetStillWins() {
        XCTAssertEqual(AudioCapture.playoutInFlightTarget(forFrameDurationMs: 20), 4,
                       "80 ms at 20 ms frames is 4 buffers, unchanged since W-IOSAUDIOSTARVE")
    }

    /// Every duration the receive path can actually observe, including the ones
    /// no profile mints today: the guarantee is about the player node, so it
    /// cannot be conditional on which profile was negotiated.
    func test_everySupportedDuration_canBePipelined() {
        for ms in [10, 20, 40, 60] {
            XCTAssertGreaterThanOrEqual(
                AudioCapture.playoutInFlightTarget(forFrameDurationMs: ms), 2,
                "frame duration \(ms) ms leaves the node unable to pipeline")
        }
    }

    /// The floor must not become the answer everywhere — that would be 4× the
    /// standing latency at 10 ms for nothing. A test that only checked the floor
    /// would pass on a target hardcoded to 2.
    func test_theTargetStillTracksDuration() {
        let atTen = AudioCapture.playoutInFlightTarget(forFrameDurationMs: 10)
        let atSixty = AudioCapture.playoutInFlightTarget(forFrameDurationMs: 60)
        XCTAssertGreaterThan(atTen, atSixty,
                             "shorter frames must still buy more buffers for the same " +
                             "millisecond budget; a constant target would pass the floor " +
                             "tests above and be wrong")
    }

    /// And the cost is bounded: the whole point of holding the budget as a
    /// duration was to avoid 240 ms of standing latency on a long-profile call.
    /// The floor spends 120 ms, and that must stay true.
    func test_theFloorDoesNotReintroduceTheLatencyItAvoided() {
        let buffers = AudioCapture.playoutInFlightTarget(forFrameDurationMs: 60)
        XCTAssertLessThanOrEqual(buffers * 60, 120,
                                 "a count-based target would have cost 240 ms here; the " +
                                 "floor exists to buy pipelining, not depth")
    }
}

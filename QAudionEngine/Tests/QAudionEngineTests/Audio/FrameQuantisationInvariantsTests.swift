import XCTest
@testable import QAudionEngine

/// The millisecond→frame quantisation invariants, asserted at EVERY frame
/// duration the receive path can observe rather than at the two a profile
/// happens to mint today.
///
/// Why this file exists. Every audio threshold in this engine is stated in
/// milliseconds and converted to a frame count at the point of use. That is the
/// right way round — the audible quantity is the duration — but the conversion
/// is lossy, and how it loses depends on the constant's ROLE:
///
///   - a CEILING ("never excise more than 60 ms") must never round UP, or the
///     code is authorised to exceed the guarantee its own comment states;
///   - a DEPTH TARGET ("leave at least this much queued") must not collapse to
///     a value with no headroom, or the tier that enforces it starves the queue
///     it is protecting;
///   - a TIER BOUNDARY must stay distinct from its neighbours, or a tier
///     silently ceases to exist and no test notices, because nothing fails.
///
/// The 60 ms profile made all three reachable at once, and two of them shipped:
/// an in-flight target of one buffer (fixed, `PlayoutInFlightTargetTests`) and a
/// silence tier that could empty the queue by itself. Both were found on a
/// device by ear, not here, which is the reason this file asserts PROPERTIES
/// over the whole reachable set instead of pinning numbers at 20 and 60.
///
/// 40 ms is in that set and had never been evaluated by anything. It is
/// reachable without any new profile: `AudioCapture.noteInboundFrameDuration`
/// accepts any duration whose PCM length divides evenly and is at most
/// `maxFrameDurationMs`, and `setInboundFrameDurationMs` admits the same range.
/// A peer, a future profile, or a partially-upgraded fleet can put a 40 ms frame
/// on this receiver today.
final class FrameQuantisationInvariantsTests: XCTestCase {

    /// Every frame duration this receiver can be driven at, not just the ones a
    /// negotiated profile currently produces.
    private let reachableDurations = [5, 10, 20, 40, 60]

    // MARK: - The conversion rules themselves

    /// A ceiling may never resolve to more time than it states. This is the
    /// property truncation buys and round-to-nearest breaks.
    func test_boundedConversion_neverExceedsItsMillisecondBudget() {
        for ms in [40, 60, 120, 160, 600] {
            for d in reachableDurations {
                let frames = AudioConstants.boundedFramesForMs(ms, frameDurationMs: d)
                XCTAssertLessThanOrEqual(
                    frames * d, max(ms, d),
                    "a \(ms) ms ceiling resolved to \(frames) frames of \(d) ms = \(frames * d) ms, " +
                    "which is more than it promised; the one permitted exception is a budget " +
                    "smaller than a single frame, where one frame is the smallest honest answer")
            }
        }
    }

    /// ...and may never resolve to nothing, which would disable the operation it
    /// exists to limit rather than limiting it.
    func test_boundedConversion_isNeverZero() {
        for d in reachableDurations {
            XCTAssertGreaterThanOrEqual(AudioConstants.boundedFramesForMs(10, frameDurationMs: d), 1)
        }
    }

    /// The regression that motivated the split: at 40 ms the old rule turned the
    /// 60 ms excision ceiling into 2 frames, i.e. 80 ms.
    func test_theOldRoundingWouldHaveOvershotAtFortyMs() {
        XCTAssertEqual(AudioConstants.framesForMs(60, frameDurationMs: 40), 2,
                       "round-to-nearest still overshoots — this asserts the reason the split exists")
        XCTAssertEqual(AudioConstants.boundedFramesForMs(60, frameDurationMs: 40), 1,
                       "the bounded rule must not")
    }

    /// Nothing already in the field moves: at 20 ms every constant in this
    /// engine divides exactly, so both rules agree.
    func test_atTwentyMs_bothRulesAgree() {
        for ms in [40, 60, 80, 120, 140, 160, 200, 300, 600] {
            XCTAssertEqual(AudioConstants.framesForMs(ms, frameDurationMs: 20),
                           AudioConstants.boundedFramesForMs(ms, frameDurationMs: 20),
                           "\(ms) ms must be unchanged at the shipping cadence")
        }
    }

    // MARK: - The jitter-buffer ladder

    /// Every tier boundary must stay strictly ordered and strictly distinct at
    /// every reachable duration. A tier that ties with its neighbour has an
    /// empty band and can never fire; nothing fails when that happens, which is
    /// why it needs asserting rather than reviewing.
    func test_theTierLadderStaysOrderedAndDistinct() {
        for d in reachableDurations {
            let buf = PlayoutJitterBuffer()
            buf.setInboundFrameDurationMs(d)
            let g = buf.tierGeometryForTesting

            XCTAssertLessThan(g.nominal, g.trim,
                              "nominal and trim tie at \(d) ms — the catch-up entry band is empty")
            XCTAssertLessThan(g.trim, g.high,
                              "trim and high tie at \(d) ms — tier 1 has no band and can never fire")
            XCTAssertLessThan(g.high, g.emergency,
                              "high and emergency tie at \(d) ms — tier 2 has no band")
            XCTAssertLessThan(g.emergency, g.capacity,
                              "emergency and capacity tie at \(d) ms — tier 3 cannot arm before overrun")
        }
    }

    /// W-TRIMFLOOR's invariant, stated as an invariant instead of as the four
    /// numbers that happen to satisfy it at 20 ms: a full tier-2 firing must not
    /// be able to take the queue below the floor it is required to leave.
    func test_aFullCatchupFiringCannotBreachTheFloor() {
        for d in reachableDurations {
            let buf = PlayoutJitterBuffer()
            buf.setInboundFrameDurationMs(d)
            let g = buf.tierGeometryForTesting
            XCTAssertGreaterThanOrEqual(
                g.trim - g.highDropBudget, g.nominal,
                "at \(d) ms a tier-2 firing entered at the trim threshold can drop " +
                "\(g.highDropBudget) frames and leave \(g.trim - g.highDropBudget), below the " +
                "floor of \(g.nominal) it must never breach")
        }
    }

    /// The emergency drain must stop holding SOMETHING. Its residual is measured
    /// after the delivery that releases the latch, which is where it used to
    /// lose its last frame.
    func test_theEmergencyDrainNeverTargetsAnEmptyQueue() {
        for d in reachableDurations {
            let buf = PlayoutJitterBuffer()
            buf.setInboundFrameDurationMs(d)
            XCTAssertGreaterThanOrEqual(
                buf.tierGeometryForTesting.drainTarget, 1,
                "at \(d) ms tier 3 drains to nothing and hands the next pop an underrun")
        }
    }

    /// A ceiling that resolves to the whole queue is not a ceiling. Guards
    /// against a future ms value that quietly lets one firing excise everything.
    func test_noSingleFiringMayExciseTheWholeQueue() {
        for d in reachableDurations {
            let buf = PlayoutJitterBuffer()
            buf.setInboundFrameDurationMs(d)
            let g = buf.tierGeometryForTesting
            XCTAssertLessThan(g.maxDropsPerPop, g.capacity,
                              "at \(d) ms one emergency pop may drop the entire queue")
            XCTAssertLessThan(g.highDropBudget, g.capacity,
                              "at \(d) ms one tier-2 pop may drop the entire queue")
        }
    }
}

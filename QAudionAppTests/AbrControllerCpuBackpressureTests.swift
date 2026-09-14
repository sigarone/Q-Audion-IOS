import XCTest
@testable import QAudionApp

/// W-BACKPRESSURE-RES (2026-08-26) — coverage for `AbrController`'s two
/// pure ceiling functions (`resolutionCeiling(forCpuBackpressureSteps:)`,
/// `fpsCeiling(forCpuBackpressureSteps:)`), the mapping from
/// `QAudionWebRtcCallController`'s CPU-overuse step count onto the
/// resolution/fps ceiling `applyCpuBackpressure(steps:)` applies. Before
/// this change, sustained CPU overuse only tightened the RTP sender's
/// bitrate ceiling — the encoder kept doing the same per-frame work at the
/// same source resolution/fps regardless of how CPU-limited the device was.
///
/// NOTE (not yet wired into a build target): same gap `TokenVaultTests
/// .swift`/`DisplayNameTests.swift`/`PeerTrustEvaluatorTests.swift` already
/// document — no `QAudionAppTests` XCTest target is wired in
/// `QAudionApp/project.yml` today, and no Xcode/Swift toolchain is
/// available in this session (Windows, no macOS/Xcode) to compile or run
/// this file. Written against that gap rather than left unwritten —
/// UNVERIFIED BY COMPILATION, reviewed carefully by hand instead. Both
/// functions under test are pure `Int -> X` mappings with no
/// `VideoCallPipeline`/`TelemetryService` dependency, so they need no
/// mocking to test in isolation once this target IS wired in.
final class AbrControllerCpuBackpressureTests: XCTestCase {

    // MARK: - resolutionCeiling

    func testResolutionCeiling_noBackpressure_isUnconstrained() {
        XCTAssertEqual(AbrController.resolutionCeiling(forCpuBackpressureSteps: 0), .hd720)
    }

    func testResolutionCeiling_negativeSteps_isTreatedAsZero() {
        // Defensive clamp — `applyCpuBackpressure` itself also clamps to
        // `max(0, steps)` before storing, but the pure function must not
        // assume a non-negative caller either.
        XCTAssertEqual(AbrController.resolutionCeiling(forCpuBackpressureSteps: -1), .hd720)
    }

    func testResolutionCeiling_stepOne_capsAtSd480() {
        XCTAssertEqual(AbrController.resolutionCeiling(forCpuBackpressureSteps: 1), .sd480)
    }

    /// `backpressureMaxSteps` on the 1:1 controller is 3 — one more level
    /// than this controller has resolution tiers for. Steps 2 and 3 must
    /// both hold at the floor rather than having nowhere to go (no crash,
    /// no out-of-range case).
    func testResolutionCeiling_stepTwoAndBeyond_holdsAtTheFloor() {
        XCTAssertEqual(AbrController.resolutionCeiling(forCpuBackpressureSteps: 2), .low360)
        XCTAssertEqual(AbrController.resolutionCeiling(forCpuBackpressureSteps: 3), .low360)
        XCTAssertEqual(AbrController.resolutionCeiling(forCpuBackpressureSteps: 100), .low360)
    }

    /// The ceiling must never get LESS restrictive as steps increase —
    /// this is the whole "backpressure ladder" property.
    func testResolutionCeiling_isMonotonicallyNonIncreasingInQualityAsStepsGrow() {
        var previous = AbrController.resolutionCeiling(forCpuBackpressureSteps: 0)
        for steps in 1...5 {
            let current = AbrController.resolutionCeiling(forCpuBackpressureSteps: steps)
            XCTAssertGreaterThanOrEqual(
                current.rawValue, previous.rawValue,
                "rawValue must never DECREASE (i.e. quality must never improve) as steps increases")
            previous = current
        }
    }

    // MARK: - fpsCeiling

    func testFpsCeiling_noBackpressure_isDefaultFps() {
        XCTAssertEqual(AbrController.fpsCeiling(forCpuBackpressureSteps: 0), VideoConstants.defaultVideoFps)
    }

    func testFpsCeiling_negativeSteps_isTreatedAsZero() {
        XCTAssertEqual(AbrController.fpsCeiling(forCpuBackpressureSteps: -1), VideoConstants.defaultVideoFps)
    }

    func testFpsCeiling_stepOne_capsAt15() {
        XCTAssertEqual(AbrController.fpsCeiling(forCpuBackpressureSteps: 1), 15)
    }

    func testFpsCeiling_stepTwoAndBeyond_holdsAt10() {
        XCTAssertEqual(AbrController.fpsCeiling(forCpuBackpressureSteps: 2), 10)
        XCTAssertEqual(AbrController.fpsCeiling(forCpuBackpressureSteps: 3), 10)
    }

    func testFpsCeiling_isMonotonicallyNonIncreasingAsStepsGrow() {
        var previous = AbrController.fpsCeiling(forCpuBackpressureSteps: 0)
        for steps in 1...5 {
            let current = AbrController.fpsCeiling(forCpuBackpressureSteps: steps)
            XCTAssertLessThanOrEqual(current, previous, "fps ceiling must never INCREASE as steps increases")
            previous = current
        }
    }

    /// Mirrors this controller's OWN network-driven fps ladder in `tick()`
    /// (10 / 15 / `defaultVideoFps`) — the CPU ceiling reuses those exact
    /// same numbers rather than inventing new thresholds.
    func testFpsCeiling_reusesTheSameThreeValuesAsTheNetworkDrivenLadder() {
        let ceilingValues = Set([0, 1, 2].map { AbrController.fpsCeiling(forCpuBackpressureSteps: $0) })
        XCTAssertEqual(ceilingValues, Set([VideoConstants.defaultVideoFps, 15, 10]))
    }
}

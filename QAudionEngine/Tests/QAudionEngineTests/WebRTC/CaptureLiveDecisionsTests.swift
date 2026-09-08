import XCTest
@testable import QAudionEngine

/// W-CAPTURELIVE-SIGNAL (2026-09-08) — pins the pure decisions behind the
/// native-mic liveness check, same style as `SrtpFallbackDecisionsTests`.
final class CaptureLiveDecisionsTests: XCTestCase {

    // MARK: - packetsProveLive

    /// No outbound-rtp row at arm time and still none: not live.
    func test_noOutboundRow_isNotLive() {
        XCTAssertFalse(CaptureLiveDecisions.packetsProveLive(packetsAtArm: -1, packetsNow: -1))
    }

    /// Row appeared but nothing was ever sent: not live.
    func test_zeroPackets_isNotLive() {
        XCTAssertFalse(CaptureLiveDecisions.packetsProveLive(packetsAtArm: -1, packetsNow: 0))
        XCTAssertFalse(CaptureLiveDecisions.packetsProveLive(packetsAtArm: 0, packetsNow: 0))
    }

    /// The first packet after arming is proof of life (the row may not have
    /// existed at arm time — the callee's stats sampler starts at the answer).
    func test_firstPacketAfterArm_isLive() {
        XCTAssertTrue(CaptureLiveDecisions.packetsProveLive(packetsAtArm: -1, packetsNow: 1))
        XCTAssertTrue(CaptureLiveDecisions.packetsProveLive(packetsAtArm: 0, packetsNow: 1))
    }

    /// Growth from a non-zero baseline is live (the caller's row often exists
    /// before the gate opens).
    func test_growthFromBaseline_isLive() {
        XCTAssertTrue(CaptureLiveDecisions.packetsProveLive(packetsAtArm: 15, packetsNow: 42))
    }

    /// THE fence: a frozen non-zero count is the dead-sender shape, never live.
    func test_frozenCount_isNotLive() {
        XCTAssertFalse(CaptureLiveDecisions.packetsProveLive(packetsAtArm: 42, packetsNow: 42))
    }

    /// A count that went DOWN (stats row rebuilt on a renegotiation) is not
    /// treated as growth.
    func test_countWentDown_isNotLive() {
        XCTAssertFalse(CaptureLiveDecisions.packetsProveLive(packetsAtArm: 42, packetsNow: 7))
    }

    // MARK: - gateOpen

    func test_gate_requiresBothSessionActiveAndPeerAnswered() {
        XCTAssertTrue(CaptureLiveDecisions.gateOpen(audioSessionActive: true, peerAnswered: true))
        XCTAssertFalse(CaptureLiveDecisions.gateOpen(audioSessionActive: true, peerAnswered: false))
        XCTAssertFalse(CaptureLiveDecisions.gateOpen(audioSessionActive: false, peerAnswered: true))
        XCTAssertFalse(CaptureLiveDecisions.gateOpen(audioSessionActive: false, peerAnswered: false))
    }

    // MARK: - Constants (a silent retune here changes live-call behaviour)

    func test_windows_areTheDocumentedValues() {
        XCTAssertEqual(CaptureLiveDecisions.gatePollIntervalMs, 250)
        XCTAssertEqual(CaptureLiveDecisions.gateWaitCapMs, 120_000)
        XCTAssertEqual(CaptureLiveDecisions.growthPollIntervalMs, 500)
        XCTAssertEqual(CaptureLiveDecisions.growthWindowMs, 3_000)
        XCTAssertEqual(CaptureLiveDecisions.afterNudgeWindowMs, 1_500)
    }
}

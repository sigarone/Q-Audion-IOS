import XCTest
@testable import QAudionEngine

/// D6 (2026-09-28, TURN-stuck-on-P2P fix) — pins `P2pProbeDecisions
/// .shouldProbe`'s gating rule against Android's real, shipped values
/// (`P2pProbeGate.kt` / `P2pProbeGateTest.kt`), same style as
/// `RestartIceDecisionsTests`.
final class P2pProbeDecisionsTests: XCTestCase {

    private func baseline(
        isInitiator: Bool = true,
        pairKind: RouteTier = .relay,
        relayPairSinceMs: Int64? = 0,
        nowMs: Int64 = P2pProbeDecisions.minConnectedOnRelayMs,
        peerSentNonRelayCandidate: Bool = true,
        lastDisconnectOrFailedAtMs: Int64? = nil,
        transportForcesTurn: Bool = false,
        transportForcesWs: Bool = false,
        renegotiationInProgress: Bool = false,
        callActive: Bool = true,
        alreadyProbedThisCall: Bool = false,
        killSwitchActive: Bool = false
    ) -> P2pProbeDecisions.Input {
        P2pProbeDecisions.Input(
            isInitiator: isInitiator,
            pairKind: pairKind,
            relayPairSinceMs: relayPairSinceMs,
            nowMs: nowMs,
            peerSentNonRelayCandidate: peerSentNonRelayCandidate,
            lastDisconnectOrFailedAtMs: lastDisconnectOrFailedAtMs,
            transportForcesTurn: transportForcesTurn,
            transportForcesWs: transportForcesWs,
            renegotiationInProgress: renegotiationInProgress,
            callActive: callActive,
            alreadyProbedThisCall: alreadyProbedThisCall,
            killSwitchActive: killSwitchActive
        )
    }

    func test_allPreconditionsSatisfiedAtExactly8sBoundary_probes() {
        XCTAssertTrue(P2pProbeDecisions.shouldProbe(baseline()))
    }

    func test_justUnder8sConnectedOnRelay_doesNotProbe() {
        let input = baseline(nowMs: P2pProbeDecisions.minConnectedOnRelayMs - 1)
        XCTAssertFalse(P2pProbeDecisions.shouldProbe(input))
    }

    func test_wellPastTheMinimum_stillProbes() {
        let input = baseline(nowMs: P2pProbeDecisions.minConnectedOnRelayMs + 60_000)
        XCTAssertTrue(P2pProbeDecisions.shouldProbe(input))
    }

    func test_theAnswererNeverProbes() {
        let input = baseline(isInitiator: false)
        XCTAssertFalse(P2pProbeDecisions.shouldProbe(input))
    }

    func test_alreadyOnADirectPair_isANoOp() {
        let input = baseline(pairKind: .direct)
        XCTAssertFalse(P2pProbeDecisions.shouldProbe(input))
    }

    func test_unknownPairKind_doesNotProbe() {
        let input = baseline(pairKind: .unknown)
        XCTAssertFalse(P2pProbeDecisions.shouldProbe(input))
    }

    func test_peerThatNeverSentANonRelayCandidate_blocksTheProbe() {
        let input = baseline(peerSentNonRelayCandidate: false)
        XCTAssertFalse(P2pProbeDecisions.shouldProbe(input))
    }

    func test_disconnect19sAgo_blocksTheProbe() {
        let input = baseline(nowMs: 100_000, relayPairSinceMs: 0, lastDisconnectOrFailedAtMs: 100_000 - 19_000)
        XCTAssertFalse(P2pProbeDecisions.shouldProbe(input))
    }

    func test_disconnectExactly20sAgo_noLongerBlocksTheProbe() {
        let input = baseline(nowMs: 100_000, relayPairSinceMs: 0, lastDisconnectOrFailedAtMs: 100_000 - 20_000)
        XCTAssertTrue(P2pProbeDecisions.shouldProbe(input))
    }

    func test_forceTurnTransportPreference_blocksTheProbe() {
        let input = baseline(transportForcesTurn: true)
        XCTAssertFalse(P2pProbeDecisions.shouldProbe(input))
    }

    func test_forceWsTransportPreference_blocksTheProbe() {
        let input = baseline(transportForcesWs: true)
        XCTAssertFalse(P2pProbeDecisions.shouldProbe(input))
    }

    func test_renegotiationOrRestartAlreadyInFlight_blocksTheProbe() {
        let input = baseline(renegotiationInProgress: true)
        XCTAssertFalse(P2pProbeDecisions.shouldProbe(input))
    }

    func test_tornDownCall_neverProbes() {
        let input = baseline(callActive: false)
        XCTAssertFalse(P2pProbeDecisions.shouldProbe(input))
    }

    func test_callThatAlreadyProbedOnce_neverProbesAgain() {
        let input = baseline(alreadyProbedThisCall: true)
        XCTAssertFalse(P2pProbeDecisions.shouldProbe(input))
    }

    func test_remoteKillSwitch_disablesTheProbeUnconditionally() {
        let input = baseline(killSwitchActive: true)
        XCTAssertFalse(P2pProbeDecisions.shouldProbe(input))
    }

    func test_pairNeverClassifiedAsRelay_nilTimestamp_doesNotProbe() {
        let input = baseline(relayPairSinceMs: nil)
        XCTAssertFalse(P2pProbeDecisions.shouldProbe(input))
    }
}

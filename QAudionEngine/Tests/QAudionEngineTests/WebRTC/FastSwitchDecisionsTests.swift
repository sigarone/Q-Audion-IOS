import XCTest
@testable import QAudionEngine

/// Faster media switch on a network change (flag `calls.ice_fastswitch`) and the selected-pair
/// route tier. Pure decisions only; the wiring is pinned by `FastSwitchWiringTests`.
final class FastSwitchDecisionsTests: XCTestCase {

    // MARK: - Signalling socket on a path edge

    private func action(flagOn: Bool = true, inCall: Bool = true, live: Bool = false,
                        typeChanged: Bool = false,
                        since: TimeInterval = 100, kicks: Int = 0) -> FastSwitchDecisions.PathEdgeAction {
        FastSwitchDecisions.pathEdgeAction(flagOn: flagOn, inActiveCall: inCall, hasLiveAuthenticatedTask: live,
                                           interfaceTypeChanged: typeChanged,
                                           sinceLastKickSec: since, legacyDebounceSec: 15, recentKicks: kicks)
    }

    func testAnInterfaceTypeChangeOverridesTheLiveSocketCheckInACall() {
        XCTAssertEqual(action(live: true, typeChanged: true), .reconnectNow, "a socket bound to the old interface is dead")
        XCTAssertEqual(action(live: true, typeChanged: false), .ignore, "same interface type: live socket left alone")
        XCTAssertEqual(action(flagOn: false, live: true, typeChanged: true), .ignore)
        XCTAssertEqual(action(inCall: false, live: true, typeChanged: true), .ignore)
    }

    func testAnInterfaceTypeChangeKeepsTheDebounceAndTheCap() {
        XCTAssertEqual(action(live: true, typeChanged: true, since: 2.0), .ignore)
        XCTAssertEqual(action(live: true, typeChanged: true, kicks: FastSwitchDecisions.socketKickMaxPerWindow),
                       .adaptiveTimingOnly)
    }

    func testReconnectsOnPathEdgeOnlyInACallWithTheFlagOn() {
        XCTAssertEqual(action(), .reconnectNow)
        XCTAssertEqual(action(flagOn: false), .adaptiveTimingOnly, "flag off keeps the legacy behaviour")
        XCTAssertEqual(action(inCall: false), .adaptiveTimingOnly, "outside a call nothing changes")
    }

    func testALiveAuthenticatedSocketIsLeftAlone() {
        XCTAssertEqual(action(live: true), .ignore)
        XCTAssertEqual(action(flagOn: false, live: true), .ignore)
    }

    func testFastDebounceIsThreeSecondsLegacyStaysFifteen() {
        XCTAssertEqual(action(since: 2.9), .ignore)
        XCTAssertEqual(action(since: 3.0), .reconnectNow)
        XCTAssertEqual(action(flagOn: false, since: 14.9), .ignore)
        XCTAssertEqual(action(flagOn: false, since: 15.0), .adaptiveTimingOnly)
    }

    func testAFlappingPathCannotStormReconnects() {
        XCTAssertEqual(action(kicks: FastSwitchDecisions.socketKickMaxPerWindow - 1), .reconnectNow)
        XCTAssertEqual(action(kicks: FastSwitchDecisions.socketKickMaxPerWindow), .adaptiveTimingOnly)
    }

    // MARK: - ICE restart servers and priming

    func testCachedServersOnlyForAnInterfaceChangeRestartWithTheFlagOn() {
        let reason = FastSwitchDecisions.interfaceChangeReason
        XCTAssertEqual(reason, "interface-change")
        XCTAssertTrue(FastSwitchDecisions.usesCachedServersForRestart(flagOn: true, reason: reason))
        XCTAssertFalse(FastSwitchDecisions.usesCachedServersForRestart(flagOn: false, reason: reason))
        for other in ["ice-failed-recovery-watchdog", "p2p-probe", "relay-fleet-changed", ""] {
            XCTAssertFalse(FastSwitchDecisions.usesCachedServersForRestart(flagOn: true, reason: other), other)
        }
        XCTAssertTrue(FastSwitchDecisions.usesCachedServersForRestart(
            flagOn: true, reason: reason + RestartIceDecisions.parkedResendReasonSuffix),
                      "the parked resend of the interface-change restart is the same attempt")
        XCTAssertFalse(FastSwitchDecisions.usesCachedServersForRestart(
            flagOn: false, reason: reason + RestartIceDecisions.parkedResendReasonSuffix))
        XCTAssertFalse(FastSwitchDecisions.usesCachedServersForRestart(
            flagOn: true, reason: "p2p-probe" + RestartIceDecisions.parkedResendReasonSuffix))
    }

    func testAParkedResendOnTheFastPathMintsNoSecondOffer() {
        XCTAssertFalse(FastSwitchDecisions.parkedResendMintsNewOffer(cachedServers: true))
        XCTAssertTrue(FastSwitchDecisions.parkedResendMintsNewOffer(cachedServers: false), "legacy behaviour unchanged")
    }

    func testProbeFallbackWhenNoAudioArrivesOnTheNewPair() {
        XCTAssertTrue(FastSwitchDecisions.needsProbeFallback(fast: true, baselinePackets: 100, packetsNow: 100))
        XCTAssertTrue(FastSwitchDecisions.needsProbeFallback(fast: true, baselinePackets: 100, packetsNow: nil))
        XCTAssertFalse(FastSwitchDecisions.needsProbeFallback(fast: true, baselinePackets: 100, packetsNow: 101))
        XCTAssertFalse(FastSwitchDecisions.needsProbeFallback(fast: true, baselinePackets: nil, packetsNow: 5),
                       "no inbound RTP row: nothing to judge")
        XCTAssertFalse(FastSwitchDecisions.needsProbeFallback(fast: false, baselinePackets: 100, packetsNow: 100))
        XCTAssertEqual(FastSwitchDecisions.probeFallbackAfterSec, 4.0)
    }

    func testTheFallbackSkipsWhenAudioResumedOrAPeerRestartWasApplied() {
        XCTAssertFalse(FastSwitchDecisions.needsProbeFallback(fast: true, baselinePackets: 100, packetsNow: 250))
        XCTAssertFalse(FastSwitchDecisions.needsProbeFallback(fast: true, baselinePackets: 100, packetsNow: 100,
                                                              peerRestartApplied: true),
                       "a peer-initiated restart is converging: no overlapping restart")
        XCTAssertTrue(FastSwitchDecisions.needsProbeFallback(fast: true, baselinePackets: 100, packetsNow: 100,
                                                             peerRestartApplied: false))
    }

    func testTheFallbackRestartTakesTheNormalPathAndSkipsTheGates() {
        let reason = FastSwitchDecisions.fallbackReason
        XCTAssertFalse(FastSwitchDecisions.usesCachedServersForRestart(flagOn: true, reason: reason, forceProbe: true),
                       "the explicit fallback marker, not the reason text, forces the UDP re-probe and bridge decision")
        XCTAssertFalse(FastSwitchDecisions.usesCachedServersForRestart(
            flagOn: true, reason: FastSwitchDecisions.interfaceChangeReason, forceProbe: true))
        XCTAssertTrue(reason.hasSuffix(RestartIceDecisions.parkedResendReasonSuffix),
                      "so the debounce and the single-flight gate let it through")
    }

    func testTheGateStartsOffAndFollowsSet() {
        let gate = CallFastSwitchGate()
        XCTAssertFalse(gate.isEnabled)
        gate.set(true)
        XCTAssertTrue(gate.isEnabled)
        gate.set(false)
        XCTAssertFalse(gate.isEnabled)
    }

    // MARK: - Route tier from the selected pair

    private func pair(_ id: String, _ local: String, _ remote: String,
                      state: String = "succeeded", nominated: Bool = false) -> IcePairSnapshot {
        IcePairSnapshot(id: id, state: state, nominated: nominated, localType: local, remoteType: remote)
    }

    func testASelectedSrflxPairIsDirectEvenWithAnOldRelayPairStillSucceeded() {
        let pairs = [pair("A", "relay", "relay"), pair("B", "srflx", "srflx", nominated: true)]
        XCTAssertEqual(SelectedPairResolver.tier(selectedPairId: "B", pairs: pairs), .direct)
        XCTAssertEqual(SelectedPairResolver.tier(selectedPairId: "A", pairs: pairs), .relay)
    }

    func testHostAndPrflxPairsAreDirect() {
        XCTAssertEqual(SelectedPairResolver.tier(selectedPairId: "H", pairs: [pair("H", "host", "host")]), .direct)
        XCTAssertEqual(SelectedPairResolver.tier(selectedPairId: "P", pairs: [pair("P", "prflx", "srflx")]), .direct)
    }

    func testARelayOnEitherSideIsRelay() {
        XCTAssertEqual(SelectedPairResolver.tier(selectedPairId: "R", pairs: [pair("R", "srflx", "relay")]), .relay)
    }

    func testWithoutASelectedIdTheNominatedSucceededPairWins() {
        let pairs = [pair("A", "relay", "relay"), pair("B", "srflx", "srflx", nominated: true)]
        XCTAssertEqual(SelectedPairResolver.tier(selectedPairId: nil, pairs: pairs), .direct)
    }

    func testAnAmbiguousMixIsUnknownNotRelay() {
        let nominatedMix = [pair("A", "relay", "relay", nominated: true), pair("B", "srflx", "srflx", nominated: true)]
        XCTAssertEqual(SelectedPairResolver.tier(selectedPairId: nil, pairs: nominatedMix), .unknown)
        let succeededMix = [pair("A", "relay", "relay"), pair("B", "srflx", "srflx")]
        XCTAssertEqual(SelectedPairResolver.tier(selectedPairId: nil, pairs: succeededMix), .unknown)
    }

    func testAnUnknownOrAmbiguousSelectionNeverMakesTheProbeSkip() {
        // Unknown never reads as direct, so a committed relay still probes.
        XCTAssertEqual(P2pProbeDecisions.effectivePairKind(committed: .relay, latestSelected: .unknown), .relay)
        let ambiguous = [pair("A", "relay", "relay"), pair("B", "srflx", "srflx")]
        XCTAssertEqual(SelectedPairResolver.tier(selectedPairId: nil, pairs: ambiguous), .unknown)
        XCTAssertNil(SelectedPairResolver.select(selectedPairId: nil, pairs: ambiguous))
    }

    func testNoSucceededPairIsUnknown() {
        XCTAssertEqual(SelectedPairResolver.tier(selectedPairId: nil, pairs: [pair("A", "srflx", "srflx", state: "in-progress")]),
                       .unknown)
        XCTAssertEqual(SelectedPairResolver.tier(selectedPairId: nil, pairs: []), .unknown)
    }

    // MARK: - P2P probe never restarts a call already on a direct pair

    func testTheProbePairKindIsDirectWhenTheSelectedPairIsDirect() {
        XCTAssertEqual(P2pProbeDecisions.effectivePairKind(committed: .relay, latestSelected: .direct), .direct)
        XCTAssertEqual(P2pProbeDecisions.effectivePairKind(committed: .relay, latestSelected: .relay), .relay)
        XCTAssertEqual(P2pProbeDecisions.effectivePairKind(committed: .relay, latestSelected: .unknown), .relay)
        XCTAssertEqual(P2pProbeDecisions.effectivePairKind(committed: .direct, latestSelected: .relay), .direct)
    }
}

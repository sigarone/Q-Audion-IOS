import XCTest
@testable import QAudionEngine

/// W-SILENTPATHDEATH + W-OFFERGLARE + W-RESTARTOFFERPARK (2026-08-25) —
/// parity plan Fase E3. Pins the pure decision logic against Android's real
/// values/branches (`PeerConnectionHolder.kt` / `CallController.kt`), same
/// style as `GlareDecisionsTests` / `MediaDeadDecisionsTests`.
final class RestartIceDecisionsTests: XCTestCase {

    // MARK: - Constants — must match Android's shipped numbers exactly.

    func test_constants_matchAndroidValues() {
        XCTAssertEqual(RestartIceDecisions.iceRestartDebounceMs, 3_000)
        XCTAssertEqual(RestartIceDecisions.selfRepairWindowMs, 5_000)
        XCTAssertEqual(RestartIceDecisions.selfRepairShortWindowMs, 1_500)
        XCTAssertEqual(RestartIceDecisions.silentPathDeathLookbackMs, 4_000)
        XCTAssertEqual(RestartIceDecisions.recoverySettleInitialMs, 1_500)
        XCTAssertEqual(RestartIceDecisions.recoverySettleMaxMs, 20_000)
        XCTAssertEqual(RestartIceDecisions.restartOfferMaxInlineAttempts, 5)
        XCTAssertEqual(RestartIceDecisions.restartOfferParkBudgetMs, 45_000)
    }

    // MARK: - W-SILENTPATHDEATH self-repair window sizing

    func test_selfRepairWindow_longWindow_whenRecentExternalNetworkChange() {
        // Within the 4000ms lookback -> a real handoff is the likely cause,
        // give ICE the full 5s to self-heal.
        XCTAssertEqual(RestartIceDecisions.selfRepairWindowMs(msSinceLastExternalNetworkChange: 0), 5_000)
        XCTAssertEqual(RestartIceDecisions.selfRepairWindowMs(msSinceLastExternalNetworkChange: 4_000), 5_000)
    }

    func test_selfRepairWindow_shortWindow_whenNoRecentExternalNetworkChange() {
        // Just past the lookback -> silent path death suspected, escalate sooner.
        XCTAssertEqual(RestartIceDecisions.selfRepairWindowMs(msSinceLastExternalNetworkChange: 4_001), 1_500)
        XCTAssertEqual(RestartIceDecisions.selfRepairWindowMs(msSinceLastExternalNetworkChange: 60_000), 1_500)
    }

    /// `nil` (no external network-change event observed all call) must
    /// behave EXACTLY like Android's zero-initialized
    /// `lastExternalNetworkChangeAtMs = 0L` default: far outside the
    /// lookback -> short window, not a crash or a "treat as recent" bug.
    func test_selfRepairWindow_shortWindow_whenNeverSeenAnExternalChange() {
        XCTAssertEqual(RestartIceDecisions.selfRepairWindowMs(msSinceLastExternalNetworkChange: nil), 1_500)
    }

    // MARK: - W-OFFERGLARE — incoming remote offer verdict

    func test_incomingOffer_stable_appliesNormally_regardlessOfRole() {
        XCTAssertEqual(
            RestartIceDecisions.resolveIncomingOffer(signalingState: .stable, isInitiator: true),
            .applyNormally)
        XCTAssertEqual(
            RestartIceDecisions.resolveIncomingOffer(signalingState: .stable, isInitiator: false),
            .applyNormally)
    }

    /// The ORIGINAL call initiator wins a restart-offer glare: keeps its
    /// own pending local offer, ignores the peer's colliding one. Mirrors
    /// Android: `if (activeAsInitiator) { ... return }` (the "wins" branch
    /// literally returns without touching the PC).
    func test_incomingOffer_haveLocalOffer_initiatorWins() {
        XCTAssertEqual(
            RestartIceDecisions.resolveIncomingOffer(signalingState: .haveLocalOffer, isInitiator: true),
            .initiatorIgnoreKeepPendingOffer)
    }

    /// The ORIGINAL call responder loses: rolls its own pending offer back
    /// (JSEP rollback), then applies the peer's incoming offer. Mirrors
    /// Android's inline rollback branch (NOT the reentrant helper — see
    /// the kdoc on `QAudionWebRtcCallController.applyRemoteRestartOffer`
    /// for why the rollback must not re-enter whatever guards this call).
    func test_incomingOffer_haveLocalOffer_responderLoses() {
        XCTAssertEqual(
            RestartIceDecisions.resolveIncomingOffer(signalingState: .haveLocalOffer, isInitiator: false),
            .responderRollbackThenApply)
    }

    /// Any other mid-negotiation state (haveRemoteOffer, haveLocalPrAnswer,
    /// closed) is not a glare this decision knows how to resolve — ignore,
    /// same as Android's `else if (state != STABLE) { ... return }` WARN
    /// branch (a likely duplicate `call_incoming` dispatch).
    func test_incomingOffer_otherState_ignored() {
        XCTAssertEqual(
            RestartIceDecisions.resolveIncomingOffer(signalingState: .other, isInitiator: true),
            .ignoreUnexpectedState)
        XCTAssertEqual(
            RestartIceDecisions.resolveIncomingOffer(signalingState: .other, isInitiator: false),
            .ignoreUnexpectedState)
    }

    /// Sanity: in every physically-realizable restart-offer race, both
    /// peers evaluate the SAME `isInitiator` fact about the SAME call from
    /// opposite ends (exactly one side is the original initiator) — so
    /// exactly one side ignores and the other rolls back+applies. Never
    /// both-ignore (call wedges, restart lost) or both-rollback (both
    /// offers vanish).
    func test_exactlyOneSideWinsAcrossBothViews() {
        let initiatorSide = RestartIceDecisions.resolveIncomingOffer(signalingState: .haveLocalOffer, isInitiator: true)
        let responderSide = RestartIceDecisions.resolveIncomingOffer(signalingState: .haveLocalOffer, isInitiator: false)
        XCTAssertEqual(initiatorSide, .initiatorIgnoreKeepPendingOffer)
        XCTAssertEqual(responderSide, .responderRollbackThenApply)
        XCTAssertNotEqual(initiatorSide, responderSide)
    }
}

import XCTest
@testable import QAudionEngine

/// W-GHOSTCALL (2026-09-25) — pins the pure decisions of the ghost-call fix
/// (incident e3acecd7: a `call_cancelled` VoIP push revived a call that had
/// already ended, and the user's Answer started an in-call state with no call).
/// No live `CXProvider`, no `AppState`: every input is a plain value. Same
/// discipline as `CallKitProviderResetPolicyTests`.
final class GhostCallPolicyTests: XCTestCase {

    private typealias Policy = GhostCallPolicy
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - cancelReportPlan

    /// The normal case, and the one that must stay byte-for-byte what it was:
    /// the call is still ringing, the push reports ITS uuid and ends it.
    func test_cancel_liveCall_reportsItsOwnUuid() {
        let callId = UUID()
        let placeholder = UUID()
        let plan = Policy.cancelReportPlan(callId: callId, isRecentlyEnded: false, placeholder: placeholder)
        XCTAssertEqual(plan.reportUuid, callId)
        XCTAssertFalse(plan.isPlaceholder)
    }

    /// The incident: the uuid is already dead, so it must never be reported
    /// again — a placeholder satisfies the PushKit mandate instead.
    func test_cancel_endedCall_reportsAFreshPlaceholder_neverTheEndedUuid() {
        let callId = UUID()
        let placeholder = UUID()
        let plan = Policy.cancelReportPlan(callId: callId, isRecentlyEnded: true, placeholder: placeholder)
        XCTAssertEqual(plan.reportUuid, placeholder)
        XCTAssertNotEqual(plan.reportUuid, callId)
        XCTAssertTrue(plan.isPlaceholder)
    }

    // MARK: - With the real ledger (the wiring AppState does)

    /// End-to-end over the pure pieces: nothing ended -> own uuid; after the
    /// call ends -> placeholder; after the TTL -> own uuid again.
    func test_cancel_followsTheLedger_acrossTheTtl() {
        var ended = RecentlyEndedCallLedger(ttl: 120)
        let callId = UUID()

        var plan = Policy.cancelReportPlan(
            callId: callId,
            isRecentlyEnded: ended.wasRecentlyEnded(callId, now: t0),
            placeholder: UUID())
        XCTAssertFalse(plan.isPlaceholder, "nothing ended yet")

        ended.recordEnded(callId, now: t0)
        plan = Policy.cancelReportPlan(
            callId: callId,
            isRecentlyEnded: ended.wasRecentlyEnded(callId, now: t0.addingTimeInterval(0.6)),
            placeholder: UUID())
        XCTAssertTrue(plan.isPlaceholder, "0.6 s after the hangup, the incident window")

        plan = Policy.cancelReportPlan(
            callId: callId,
            isRecentlyEnded: ended.wasRecentlyEnded(callId, now: t0.addingTimeInterval(121)),
            placeholder: UUID())
        XCTAssertFalse(plan.isPlaceholder, "the memory has expired")
    }

    /// A DIFFERENT call ending must not turn another call's cancel into a
    /// placeholder.
    func test_cancel_endedOtherCall_doesNotAffectThisOne() {
        var ended = RecentlyEndedCallLedger()
        let deadCall = UUID()
        let liveCall = UUID()
        ended.recordEnded(deadCall, now: t0)
        let plan = Policy.cancelReportPlan(
            callId: liveCall,
            isRecentlyEnded: ended.wasRecentlyEnded(liveCall, now: t0),
            placeholder: UUID())
        XCTAssertEqual(plan.reportUuid, liveCall)
        XCTAssertFalse(plan.isPlaceholder)
    }
}

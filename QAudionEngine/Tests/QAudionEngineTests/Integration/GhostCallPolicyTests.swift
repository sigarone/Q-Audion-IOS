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

    // MARK: - answerVerdict

    /// The normal call: this uuid is the active one and nothing marks it dead.
    /// This is the case that must never change behaviour.
    func test_answer_activeLiveCall_isAccepted() {
        let uuid = UUID()
        XCTAssertEqual(
            Policy.answerVerdict(uuid: uuid, activeCallKitId: uuid, isRecentlyEnded: false, isGhostPlaceholder: false),
            .accept)
    }

    /// Incident e3acecd7: the answer named a uuid that had just ended and
    /// `activeCallKitId` was already nil.
    func test_answer_recentlyEndedUuid_isRefused() {
        let uuid = UUID()
        XCTAssertEqual(
            Policy.answerVerdict(uuid: uuid, activeCallKitId: nil, isRecentlyEnded: true, isGhostPlaceholder: false),
            .refuseRecentlyEnded)
    }

    func test_answer_ghostPlaceholder_isRefused() {
        let placeholder = UUID()
        XCTAssertEqual(
            Policy.answerVerdict(uuid: placeholder, activeCallKitId: nil, isRecentlyEnded: false, isGhostPlaceholder: true),
            .refuseGhostPlaceholder)
    }

    /// No call at all and no ledger hit (e.g. an orphan ring): still refused.
    func test_answer_noActiveCall_isRefused() {
        XCTAssertEqual(
            Policy.answerVerdict(uuid: UUID(), activeCallKitId: nil, isRecentlyEnded: false, isGhostPlaceholder: false),
            .refuseNotActive)
    }

    /// A different call is live: accepting the stale uuid would overwrite the
    /// live call's `activeCallKitId`.
    func test_answer_otherCallIsActive_isRefused() {
        XCTAssertEqual(
            Policy.answerVerdict(uuid: UUID(), activeCallKitId: UUID(), isRecentlyEnded: false, isGhostPlaceholder: false),
            .refuseNotActive)
    }

    /// Belt and braces: even when the uuid IS the active one, a ledger hit
    /// wins — and the placeholder cause is reported before the ended one.
    func test_answer_ledgerHitsBeatActiveMatch_placeholderFirst() {
        let uuid = UUID()
        XCTAssertEqual(
            Policy.answerVerdict(uuid: uuid, activeCallKitId: uuid, isRecentlyEnded: true, isGhostPlaceholder: false),
            .refuseRecentlyEnded)
        XCTAssertEqual(
            Policy.answerVerdict(uuid: uuid, activeCallKitId: uuid, isRecentlyEnded: true, isGhostPlaceholder: true),
            .refuseGhostPlaceholder)
    }

    func test_answer_logCodes_areStableAndDistinct() {
        XCTAssertEqual(Policy.AnswerVerdict.accept.logCode, 0)
        XCTAssertEqual(Policy.AnswerVerdict.refuseGhostPlaceholder.logCode, 1)
        XCTAssertEqual(Policy.AnswerVerdict.refuseRecentlyEnded.logCode, 2)
        XCTAssertEqual(Policy.AnswerVerdict.refuseNotActive.logCode, 3)
    }

    /// The whole incident through the two real ledgers: the call ends, the
    /// ring UI is still on screen, the user taps Answer 1.28 s later.
    func test_answer_incidentSequence_endedCallThenAnswer() {
        var ended = RecentlyEndedCallLedger()
        var placeholders = RecentlyEndedCallLedger()
        let callId = UUID()

        // Live: ringing under CallKit, activeCallKitId == callId.
        XCTAssertEqual(
            Policy.answerVerdict(
                uuid: callId, activeCallKitId: callId,
                isRecentlyEnded: ended.wasRecentlyEnded(callId, now: t0),
                isGhostPlaceholder: placeholders.wasRecentlyEnded(callId, now: t0)),
            .accept)

        // The caller hangs up: endCall records the uuid and clears activeCallKitId.
        ended.recordEnded(callId, now: t0)
        let answerAt = t0.addingTimeInterval(1.28)
        XCTAssertEqual(
            Policy.answerVerdict(
                uuid: callId, activeCallKitId: nil,
                isRecentlyEnded: ended.wasRecentlyEnded(callId, now: answerAt),
                isGhostPlaceholder: placeholders.wasRecentlyEnded(callId, now: answerAt)),
            .refuseRecentlyEnded)

        // The cancel push reports a placeholder; a tap on ITS ring is refused too.
        let placeholder = UUID()
        placeholders.recordEnded(placeholder, now: answerAt)
        XCTAssertEqual(
            Policy.answerVerdict(
                uuid: placeholder, activeCallKitId: nil,
                isRecentlyEnded: ended.wasRecentlyEnded(placeholder, now: answerAt),
                isGhostPlaceholder: placeholders.wasRecentlyEnded(placeholder, now: answerAt)),
            .refuseGhostPlaceholder)
    }

    // MARK: - isAnsweredWithoutCall (watchdog)

    func test_watchdog_grace_isThreeSeconds() {
        XCTAssertEqual(Policy.answeredWithoutCallGraceSeconds, 3)
    }

    /// The incident: answered, `callId=none`.
    func test_watchdog_answeredButNoPeer_fires() {
        let uuid = UUID()
        XCTAssertTrue(Policy.isAnsweredWithoutCall(answeredCallKitId: uuid, expectedUuid: uuid, callContactId: nil))
        XCTAssertTrue(Policy.isAnsweredWithoutCall(answeredCallKitId: uuid, expectedUuid: uuid, callContactId: ""))
    }

    /// A normal answered call has its peer: the watchdog must stay silent.
    func test_watchdog_answeredWithPeer_isSilent() {
        let uuid = UUID()
        XCTAssertFalse(Policy.isAnsweredWithoutCall(answeredCallKitId: uuid, expectedUuid: uuid, callContactId: "peer-1"))
    }

    /// `endCall` clears `answeredCallKitId`: a call that already ended is not
    /// "answered without a call".
    func test_watchdog_callAlreadyEnded_isSilent() {
        XCTAssertFalse(Policy.isAnsweredWithoutCall(answeredCallKitId: nil, expectedUuid: UUID(), callContactId: nil))
    }

    /// A timer armed for an old answer must not end a LATER call.
    func test_watchdog_laterCallAnswered_isSilent() {
        XCTAssertFalse(Policy.isAnsweredWithoutCall(answeredCallKitId: UUID(), expectedUuid: UUID(), callContactId: nil))
    }
}

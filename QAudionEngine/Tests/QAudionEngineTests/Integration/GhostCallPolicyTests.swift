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

    // MARK: - wasRingingAtRemoteHangup (missed call under CallKit)

    private func ringing(
        state: Bool = false, active: Bool = false, answered: Bool = false, ringVisible: Bool = false
    ) -> Bool {
        Policy.wasRingingAtRemoteHangup(
            callStateIsRinging: state,
            hasActiveCallKitId: active,
            callWasAnswered: answered,
            incomingRingVisible: ringVisible)
    }

    /// The in-app ring (no CallKit): `callState == .ringing`, as before.
    func test_ringing_inAppRingingState_isRinging() {
        XCTAssertTrue(ringing(state: true))
        XCTAssertTrue(ringing(state: true, active: true, answered: true))
    }

    /// e3acecd7: CallKit owns the ring, `callState` stays `.idle`, the caller's own
    /// timeout ends it. This is the case that used to be lost.
    func test_ringing_callKitRingUnanswered_isRinging() {
        XCTAssertTrue(ringing(state: false, active: true, answered: false, ringVisible: true))
    }

    /// The guard the naive rule (`activeCallKitId != nil && !answered`) would
    /// get wrong: an OUTGOING call holds `activeCallKitId` and is never
    /// "answered" on this side, but its ring flag is never up. A remote hangup of
    /// a connected outgoing call must NOT be recorded as missed.
    func test_ringing_outgoingCallInProgress_isNotRinging() {
        XCTAssertFalse(ringing(state: false, active: true, answered: false, ringVisible: false))
    }

    func test_ringing_answeredIncomingCall_isNotRinging() {
        XCTAssertFalse(ringing(state: false, active: true, answered: true, ringVisible: false))
        XCTAssertFalse(ringing(state: false, active: true, answered: true, ringVisible: true))
    }

    func test_ringing_noCallAtAll_isNotRinging() {
        XCTAssertFalse(ringing())
        XCTAssertFalse(ringing(ringVisible: true), "a stray ring flag with no CallKit id is not a ringing call")
    }

    /// Every combination of the four inputs, against the rule written out longhand.
    func test_ringing_exhaustiveTruthTable() {
        for bits in 0..<16 {
            let state = bits & 1 != 0
            let active = bits & 2 != 0
            let answered = bits & 4 != 0
            let ringVisible = bits & 8 != 0
            let expected: Bool = state || (active && !answered && ringVisible)
            let actual: Bool = ringing(state: state, active: active, answered: answered, ringVisible: ringVisible)
            XCTAssertEqual(actual, expected, "truth-table row \(bits)")
        }
    }

    // MARK: - shouldRecordMissedOnCancelPush (push beats the WS hangup)

    private func recordsMissed(
        cancel: UUID, active: UUID?, answered: Bool = false, ringVisible: Bool = true
    ) -> Bool {
        Policy.shouldRecordMissedOnCancelPush(
            cancelCallId: cancel,
            activeCallKitId: active,
            callWasAnswered: answered,
            incomingRingVisible: ringVisible)
    }

    /// The gap this closes: the push lands first, the ring is still up for THIS
    /// call and nobody answered, so the push records the missed call itself.
    func test_cancelPushMissed_ringingUnansweredCall_isRecorded() {
        let callId = UUID()
        XCTAssertTrue(recordsMissed(cancel: callId, active: callId))
    }

    /// A cancel for a DIFFERENT call must never mark the ringing one missed.
    func test_cancelPushMissed_cancelForAnotherCall_isNotRecorded() {
        XCTAssertFalse(recordsMissed(cancel: UUID(), active: UUID()))
    }

    /// No call held at all (the WS hangup already tore it down): nothing to record.
    func test_cancelPushMissed_noActiveCall_isNotRecorded() {
        XCTAssertFalse(recordsMissed(cancel: UUID(), active: nil))
    }

    /// The ring flag is what says "still ringing": without it (already cleared, or
    /// an outgoing call) the push records nothing.
    func test_cancelPushMissed_ringFlagDown_isNotRecorded() {
        let callId = UUID()
        XCTAssertFalse(recordsMissed(cancel: callId, active: callId, ringVisible: false))
    }

    /// An answered call is never "missed", whatever the flags say.
    func test_cancelPushMissed_answeredCall_isNotRecorded() {
        let callId = UUID()
        XCTAssertFalse(recordsMissed(cancel: callId, active: callId, answered: true, ringVisible: true))
        XCTAssertFalse(recordsMissed(cancel: callId, active: callId, answered: true, ringVisible: false))
    }

    // MARK: - shouldIgnoreEndForStaleUuid (Reject on a stale ring during a live call)

    private func ignoresEnd(
        uuid: UUID, active: UUID?, recentlyEnded: Bool = false, placeholder: Bool = false
    ) -> Bool {
        Policy.shouldIgnoreEndForStaleUuid(
            uuid: uuid,
            activeCallKitId: active,
            isRecentlyEnded: recentlyEnded,
            isGhostPlaceholder: placeholder)
    }

    /// The finding: live call B, stale ring of the ended call A, Reject on A must
    /// NOT hang up B.
    func test_endStale_recentlyEndedUuid_whileOtherCallLive_isIgnored() {
        XCTAssertTrue(ignoresEnd(uuid: UUID(), active: UUID(), recentlyEnded: true))
    }

    func test_endStale_ghostPlaceholder_whileOtherCallLive_isIgnored() {
        XCTAssertTrue(ignoresEnd(uuid: UUID(), active: UUID(), placeholder: true))
    }

    /// The normal end: the uuid CallKit names IS the live call. Never ignored,
    /// even if a ledger also (wrongly) knows it — a legitimate end must not be
    /// swallowed by this rule.
    func test_endStale_liveCallsOwnUuid_isNeverIgnored() {
        let callId = UUID()
        XCTAssertFalse(ignoresEnd(uuid: callId, active: callId))
        XCTAssertFalse(ignoresEnd(uuid: callId, active: callId, recentlyEnded: true))
        XCTAssertFalse(ignoresEnd(uuid: callId, active: callId, placeholder: true))
    }

    /// No call held: nothing live to protect, the end runs as it always did.
    func test_endStale_noActiveCall_isNeverIgnored() {
        XCTAssertFalse(ignoresEnd(uuid: UUID(), active: nil))
        XCTAssertFalse(ignoresEnd(uuid: UUID(), active: nil, recentlyEnded: true))
        XCTAssertFalse(ignoresEnd(uuid: UUID(), active: nil, placeholder: true))
    }

    /// Pins the narrowness: an uuid NO ledger knows is not ignored even while
    /// another call is live (the rule only trusts what the ledgers know is dead).
    func test_endStale_unknownUuid_whileOtherCallLive_isNotIgnored() {
        XCTAssertFalse(ignoresEnd(uuid: UUID(), active: UUID()))
    }

    /// The whole input space: ignored iff a DIFFERENT call is active AND a ledger
    /// knows the uuid is dead.
    func test_endStale_exhaustiveTruthTable() {
        let mine = UUID()
        let other = UUID()
        for bits in 0..<8 {
            let hasActive = bits & 1 != 0
            let activeIsOther = bits & 2 != 0
            let ledgerHit = bits & 4 != 0
            let active: UUID? = hasActive ? (activeIsOther ? other : mine) : nil
            let expected: Bool = hasActive && activeIsOther && ledgerHit
            XCTAssertEqual(
                ignoresEnd(uuid: mine, active: active, recentlyEnded: ledgerHit),
                expected, "recentlyEnded truth-table row \(bits)")
            XCTAssertEqual(
                ignoresEnd(uuid: mine, active: active, placeholder: ledgerHit),
                expected, "placeholder truth-table row \(bits)")
        }
    }
}

import XCTest
@testable import QAudionEngine

/// W-CKLEDGER (2026-09-01) — pins the bookkeeping contract `CallKitProvider`
/// relies on, now that the three UUID sets live behind one lock in
/// `CallKitCallLedger`. Every case mirrors one provider method, so a change
/// to the ledger that would alter what the provider observes fails here
/// before it reaches a device. Same style as `RestartIceDecisionsTests`.
final class CallKitCallLedgerTests: XCTestCase {

    // MARK: - reportIncomingCall (success)

    func test_recordNativeReport_marksReportedAndOutstanding() {
        let ledger = CallKitCallLedger()
        let uuid = UUID()
        XCTAssertFalse(ledger.isNativelyReported(uuid))
        XCTAssertEqual(ledger.recordNativeReport(uuid), 1)
        XCTAssertTrue(ledger.isNativelyReported(uuid))
        XCTAssertEqual(ledger.outstandingCount, 1)
    }

    /// PushKit + WS both reporting the same uuid: the second insert is a
    /// Set no-op, the outstanding count does not double.
    func test_recordNativeReport_duplicateUuid_isIdempotent() {
        let ledger = CallKitCallLedger()
        let uuid = UUID()
        ledger.recordNativeReport(uuid)
        XCTAssertEqual(ledger.recordNativeReport(uuid), 1)
        XCTAssertEqual(ledger.outstandingCount, 1)
    }

    // MARK: - startOutgoingCall

    func test_recordOutstanding_isOutstandingButNotNativelyReported() {
        let ledger = CallKitCallLedger()
        let uuid = UUID()
        ledger.recordOutstanding(uuid)
        XCTAssertEqual(ledger.outstandingCount, 1)
        XCTAssertFalse(ledger.isNativelyReported(uuid))
        XCTAssertFalse(ledger.releaseNativeReport(uuid), "an outgoing call never showed a native incoming UI")
    }

    // MARK: - answerCall manual path (W495 / W520)

    func test_takeRejected_isAtomicTestAndRemove() {
        let ledger = CallKitCallLedger()
        let uuid = UUID()
        XCTAssertFalse(ledger.takeRejected(uuid))
        ledger.recordRejected(uuid)
        XCTAssertTrue(ledger.takeRejected(uuid))
        XCTAssertFalse(ledger.takeRejected(uuid), "manual-answer arming is consumed exactly once")
    }

    // MARK: - releaseFromSystemUI (W-WAKEONLY)

    func test_releaseNativeReport_onlyWhenNativelyShown_andKeepsOutstanding() {
        let ledger = CallKitCallLedger()
        let uuid = UUID()
        XCTAssertFalse(ledger.releaseNativeReport(uuid))
        ledger.recordNativeReport(uuid)
        XCTAssertTrue(ledger.releaseNativeReport(uuid))
        XCTAssertFalse(ledger.isNativelyReported(uuid))
        XCTAssertFalse(ledger.releaseNativeReport(uuid), "second release is a no-op")
        XCTAssertEqual(ledger.outstandingCount, 1, "releasing the system UI must not end the CallKit ledger entry")
    }

    // MARK: - reportCallEnded

    func test_forget_clearsAllThreeSets() {
        let ledger = CallKitCallLedger()
        let uuid = UUID()
        ledger.recordNativeReport(uuid)
        ledger.recordRejected(uuid)
        ledger.forget(uuid)
        XCTAssertFalse(ledger.isNativelyReported(uuid))
        XCTAssertFalse(ledger.takeRejected(uuid))
        XCTAssertEqual(ledger.outstandingCount, 0)
    }

    func test_forget_unknownUuid_isNoOp() {
        let ledger = CallKitCallLedger()
        let kept = UUID()
        ledger.recordNativeReport(kept)
        ledger.forget(UUID())
        XCTAssertTrue(ledger.isNativelyReported(kept))
        XCTAssertEqual(ledger.outstandingCount, 1)
    }

    // MARK: - endAllOutstanding

    func test_drainOutstanding_returnsSnapshotAndEmptiesOutstanding() {
        let ledger = CallKitCallLedger()
        let incoming = UUID()
        let outgoing = UUID()
        ledger.recordNativeReport(incoming)
        ledger.recordOutstanding(outgoing)
        let stale = ledger.drainOutstanding()
        XCTAssertEqual(stale, [incoming, outgoing])
        XCTAssertEqual(ledger.outstandingCount, 0)
        XCTAssertFalse(ledger.isNativelyReported(incoming))
        XCTAssertTrue(ledger.drainOutstanding().isEmpty, "second drain finds nothing")
    }

    /// A suppressed call (rejected-only, never reported) is not outstanding
    /// and must survive a drain — the per-uuid loop it replaces only touched
    /// uuids that were in the outstanding set.
    func test_drainOutstanding_leavesRejectedOnlyEntriesAlone() {
        let ledger = CallKitCallLedger()
        let suppressed = UUID()
        let reported = UUID()
        ledger.recordRejected(suppressed)
        ledger.recordNativeReport(reported)
        ledger.recordRejected(reported)
        _ = ledger.drainOutstanding()
        XCTAssertTrue(ledger.takeRejected(suppressed), "rejected-only uuid untouched by drain")
        XCTAssertFalse(ledger.takeRejected(reported), "outstanding uuid dropped from every set")
    }

    func test_drainOutstanding_empty_returnsEmpty() {
        let ledger = CallKitCallLedger()
        XCTAssertTrue(ledger.drainOutstanding().isEmpty)
        XCTAssertEqual(ledger.outstandingCount, 0)
    }

    // MARK: - providerDidReset (W571)

    func test_clearRejected_leavesReportedAndOutstanding() {
        let ledger = CallKitCallLedger()
        let reported = UUID()
        let suppressed = UUID()
        ledger.recordNativeReport(reported)
        ledger.recordRejected(suppressed)
        ledger.clearRejected()
        XCTAssertFalse(ledger.takeRejected(suppressed))
        XCTAssertTrue(ledger.isNativelyReported(reported))
        XCTAssertEqual(ledger.outstandingCount, 1)
    }

    // MARK: - reportCallEnded native balance (W-ADMBALANCE-UUID)

    func test_nativeBalance_consumedOnceForItsOwnUuid() {
        let ledger = CallKitCallLedger()
        let call = UUID()
        ledger.recordNativeBalance(call)
        ledger.recordNativeBalance(call)
        XCTAssertTrue(ledger.consumeNativeBalance(call))
        XCTAssertFalse(ledger.consumeNativeBalance(call), "a duplicate reportCallEnded must not balance twice")
    }

    /// THE race: the OLD call's report runs after the NEXT native call was
    /// recorded. It must not take the next call's record, and the next call's
    /// own report must still find it.
    func test_nativeBalance_lateReportOfOldCall_doesNotConsumeNextCallsRecord() {
        let ledger = CallKitCallLedger()
        let old = UUID()
        let next = UUID()
        ledger.recordNativeBalance(old)
        ledger.recordNativeBalance(next)
        XCTAssertTrue(ledger.consumeNativeBalance(old))
        XCTAssertTrue(ledger.consumeNativeBalance(next))
    }

    /// A legacy (native SRTP off) call is never recorded: its report keeps the
    /// drain even while a native call's record is pending.
    func test_nativeBalance_legacyCallNeverConsumesANativeRecord() {
        let ledger = CallKitCallLedger()
        let legacy = UUID()
        let native = UUID()
        ledger.recordNativeBalance(native)
        XCTAssertFalse(ledger.consumeNativeBalance(legacy))
        XCTAssertTrue(ledger.consumeNativeBalance(native))
    }

    /// A record must survive until its own report: neither the reaper nor a
    /// provider reset drops it.
    func test_nativeBalance_survivesDrainOutstandingAndClearRejected() {
        let ledger = CallKitCallLedger()
        let call = UUID()
        ledger.recordOutstanding(call)
        ledger.recordNativeBalance(call)
        _ = ledger.drainOutstanding()
        ledger.clearRejected()
        XCTAssertTrue(ledger.consumeNativeBalance(call))
    }

    // MARK: - reportCallEnded self-activation (W-SELFACTID)

    /// THE race: the OLD native call's report runs after the NEXT native call
    /// self-activated. It balances only its own activation, and the next
    /// call's report still finds its own.
    func test_selfActivation_lateReportOfOldCall_doesNotTakeNextCallsMark() {
        let ledger = CallKitCallLedger()
        let old = UUID()
        let next = UUID()
        ledger.recordNativeBalance(old)
        ledger.markAudioSelfActivated(old)
        ledger.recordNativeBalance(next)
        ledger.markAudioSelfActivated(next)
        XCTAssertEqual(ledger.consumeEndBalance(old),
                       .init(nativeManualCall: true, selfActivated: true, duplicateNative: false))
        XCTAssertEqual(ledger.consumeEndBalance(next),
                       .init(nativeManualCall: true, selfActivated: true, duplicateNative: false))
    }

    /// The old call never self-activated (its activation failed): its late
    /// report must NOT take the next call's mark.
    func test_selfActivation_oldCallWithoutMark_leavesNextCallsMark() {
        let ledger = CallKitCallLedger()
        let old = UUID()
        let next = UUID()
        ledger.recordNativeBalance(old)
        ledger.recordNativeBalance(next)
        ledger.markAudioSelfActivated(next)
        XCTAssertEqual(ledger.consumeEndBalance(old),
                       .init(nativeManualCall: true, selfActivated: false, duplicateNative: false))
        XCTAssertTrue(ledger.consumeEndBalance(next).selfActivated)
    }

    /// W-DOUBLEDECR: a repeated report of a native uuid balances nothing and
    /// never falls through to the legacy flag a legacy call may still hold.
    func test_selfActivation_duplicateNativeReport_neverTouchesLegacyFlag() {
        let ledger = CallKitCallLedger()
        let native = UUID()
        let legacy = UUID()
        ledger.recordNativeBalance(native)
        ledger.markAudioSelfActivated(native)
        ledger.markAudioSelfActivated(legacy)
        XCTAssertTrue(ledger.consumeEndBalance(native).selfActivated)
        XCTAssertEqual(ledger.consumeEndBalance(native),
                       .init(nativeManualCall: false, selfActivated: false, duplicateNative: true))
        XCTAssertEqual(ledger.consumeEndBalance(legacy),
                       .init(nativeManualCall: false, selfActivated: true, duplicateNative: false),
                       "the legacy call's mark is still there for its own report")
    }

    /// Native SRTP off: the process-wide flag, exactly as before — any report
    /// consumes it, once.
    func test_selfActivation_legacyCalls_keepTheProcessWideFlag() {
        let ledger = CallKitCallLedger()
        let first = UUID()
        let second = UUID()
        ledger.markAudioSelfActivated(first)
        XCTAssertEqual(ledger.consumeEndBalance(second),
                       .init(nativeManualCall: false, selfActivated: true, duplicateNative: false))
        XCTAssertFalse(ledger.consumeEndBalance(first).selfActivated, "consumed once")
        ledger.markAudioSelfActivated(nil)
        XCTAssertTrue(ledger.consumeEndBalance(first).selfActivated, "no uuid: the process-wide flag")
    }

    /// A legacy call's mark is never taken by a native call's report, and a
    /// native call's mark never by a legacy call's report.
    func test_selfActivation_nativeAndLegacyMarksAreSeparate() {
        let ledger = CallKitCallLedger()
        let native = UUID()
        let legacy = UUID()
        ledger.recordNativeBalance(native)
        ledger.markAudioSelfActivated(legacy)
        XCTAssertFalse(ledger.consumeEndBalance(native).selfActivated)
        ledger.recordNativeBalance(native)
        ledger.markAudioSelfActivated(native)
        XCTAssertTrue(ledger.consumeEndBalance(legacy).selfActivated)
        XCTAssertFalse(ledger.consumeEndBalance(UUID()).selfActivated)
        XCTAssertTrue(ledger.consumeEndBalance(native).selfActivated)
    }

    /// An activation that lands after its own native report consumed the
    /// record is no longer native-keyed: it takes the process-wide flag, as
    /// the single flag did before.
    func test_selfActivation_markAfterOwnReport_takesTheProcessWideFlag() {
        let ledger = CallKitCallLedger()
        let native = UUID()
        ledger.recordNativeBalance(native)
        XCTAssertFalse(ledger.consumeEndBalance(native).selfActivated)
        ledger.markAudioSelfActivated(native)
        XCTAssertTrue(ledger.consumeEndBalance(UUID()).selfActivated)
    }

    /// The duplicate memory is bounded: the oldest ended native uuid falls out.
    func test_selfActivation_endedNativeMemoryIsBounded() {
        let ledger = CallKitCallLedger()
        let first = UUID()
        ledger.recordNativeBalance(first)
        _ = ledger.consumeEndBalance(first)
        for _ in 0..<8 {
            let uuid = UUID()
            ledger.recordNativeBalance(uuid)
            _ = ledger.consumeEndBalance(uuid)
        }
        XCTAssertFalse(ledger.consumeEndBalance(first).duplicateNative)
    }

    // MARK: - beginReport / finishReport (W-GHOSTCALL single-flight)

    /// Incident e3acecd7 03.221/03.222: two reports of the same uuid inside the
    /// same millisecond. Only the first may be "the first report".
    func test_beginReport_firstCallerWins_secondIsADuplicate() {
        let ledger = CallKitCallLedger()
        let uuid = UUID()
        XCTAssertTrue(ledger.beginReport(uuid))
        XCTAssertFalse(ledger.beginReport(uuid), "second report while the first is in flight")
    }

    /// `CallKitProvider.reportIncomingCall` releases the claim only when IT took
    /// it: the losers of `beginReport` never call `finishReport`, so any number of
    /// duplicates leaves the claimer's claim in place until the claimer finishes.
    func test_beginReport_duplicatesLeaveTheClaimInPlace_untilTheClaimerFinishes() {
        let ledger = CallKitCallLedger()
        let uuid = UUID()
        XCTAssertTrue(ledger.beginReport(uuid))
        XCTAssertFalse(ledger.beginReport(uuid))
        XCTAssertFalse(ledger.beginReport(uuid), "a third report is still a duplicate")
        ledger.finishReport(uuid)
        XCTAssertTrue(ledger.beginReport(uuid), "only the claimer's release reopens it")
    }

    /// The claim is not a native report: CallKit has not answered yet.
    func test_beginReport_doesNotMarkReportedOrOutstanding() {
        let ledger = CallKitCallLedger()
        let uuid = UUID()
        XCTAssertTrue(ledger.beginReport(uuid))
        XCTAssertFalse(ledger.isNativelyReported(uuid))
        XCTAssertEqual(ledger.outstandingCount, 0)
    }

    /// After a SUCCESSFUL report the uuid stays a duplicate for good (it is in
    /// the natively-reported set), whether or not the claim was released.
    func test_beginReport_afterSuccess_isStillADuplicate() {
        let ledger = CallKitCallLedger()
        let uuid = UUID()
        XCTAssertTrue(ledger.beginReport(uuid))
        ledger.recordNativeReport(uuid)
        ledger.finishReport(uuid)
        XCTAssertFalse(ledger.beginReport(uuid))
    }

    /// A refused report (Focus / block list) releases its claim: a later report
    /// of the same uuid is a first report again, as it always was.
    func test_finishReport_afterFailure_letsALaterReportBeFirst() {
        let ledger = CallKitCallLedger()
        let uuid = UUID()
        XCTAssertTrue(ledger.beginReport(uuid))
        ledger.finishReport(uuid)
        XCTAssertTrue(ledger.beginReport(uuid))
    }

    func test_finishReport_isIdempotent_andUnknownUuidIsANoOp() {
        let ledger = CallKitCallLedger()
        let uuid = UUID()
        ledger.finishReport(uuid)
        XCTAssertTrue(ledger.beginReport(uuid))
        ledger.finishReport(uuid)
        ledger.finishReport(uuid)
        XCTAssertTrue(ledger.beginReport(uuid))
    }

    func test_beginReport_differentUuids_areIndependent() {
        let ledger = CallKitCallLedger()
        XCTAssertTrue(ledger.beginReport(UUID()))
        XCTAssertTrue(ledger.beginReport(UUID()))
    }

    /// W-WAKEONLY releases the native-UI mark while the call stays live; the
    /// old `isNativelyReported` read went false at that point and so does this.
    func test_beginReport_afterReleaseFromSystemUI_matchesTheOldRead() {
        let ledger = CallKitCallLedger()
        let uuid = UUID()
        ledger.recordNativeReport(uuid)
        XCTAssertFalse(ledger.beginReport(uuid))
        XCTAssertTrue(ledger.releaseNativeReport(uuid))
        XCTAssertTrue(ledger.beginReport(uuid))
    }

    /// The point of the claim: from many threads at once exactly one caller gets
    /// `true` (each winner leaves one outstanding entry, so the count is the
    /// number of winners).
    func test_concurrentBeginReport_exactlyOneWinner() {
        let ledger = CallKitCallLedger()
        let uuid = UUID()
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            if ledger.beginReport(uuid) {
                ledger.recordOutstanding(UUID())
            }
        }
        XCTAssertEqual(ledger.outstandingCount, 1)
    }

    // MARK: - CallKitReportFailurePolicy (W-GHOSTCALL)

    func test_shouldArm_doNotDisturbAndBlockList_stillArmTheFallback() {
        for code in [3, 4] {
            XCTAssertTrue(
                CallKitReportFailurePolicy.shouldArmManualAnswer(alreadyReported: false, errorCode: code),
                "code \(code): the system UI never appeared, so the in-app answer path is armed as before")
        }
    }

    /// e3acecd7 03.222: `ok=0 code=2` and the fallback was armed with the native
    /// UI alive. Code 2 means CallKit already has the call.
    func test_shouldArm_callUuidAlreadyExists_neverArms() {
        XCTAssertEqual(CallKitReportFailurePolicy.callUUIDAlreadyExistsCode, 2)
        XCTAssertFalse(CallKitReportFailurePolicy.shouldArmManualAnswer(alreadyReported: false, errorCode: 2))
        XCTAssertFalse(CallKitReportFailurePolicy.shouldArmManualAnswer(alreadyReported: true, errorCode: 2))
    }

    func test_shouldArm_duplicateReport_neverArms_whateverTheCode() {
        for code in [0, 1, 2, 3, 4, 5] {
            XCTAssertFalse(CallKitReportFailurePolicy.shouldArmManualAnswer(alreadyReported: true, errorCode: code))
        }
    }

    /// Unknown / unentitled refusals keep the old behaviour: the UI did not
    /// appear, so the fallback stays armed.
    func test_shouldArm_otherCodes_keepTheOldBehaviour() {
        for code in [0, 1, 5] {
            XCTAssertTrue(CallKitReportFailurePolicy.shouldArmManualAnswer(alreadyReported: false, errorCode: code))
        }
    }

    /// The whole doubled-push race through the ledger and the policy: the first
    /// report claims, the second is a duplicate, CallKit refuses the second with
    /// Code=2 — and nothing is armed.
    func test_doubledPushKitReport_neverArmsTheManualAnswerPath() {
        let ledger = CallKitCallLedger()
        let uuid = UUID()
        let firstIsFirst = ledger.beginReport(uuid)
        let secondIsFirst = ledger.beginReport(uuid)
        XCTAssertTrue(firstIsFirst)
        XCTAssertFalse(secondIsFirst)
        // First: CallKit accepts.
        ledger.recordNativeReport(uuid)
        ledger.finishReport(uuid)
        // Second: CallKit refuses with Code=2.
        if CallKitReportFailurePolicy.shouldArmManualAnswer(alreadyReported: !secondIsFirst, errorCode: 2) {
            ledger.recordRejected(uuid)
        }
        ledger.finishReport(uuid)
        XCTAssertFalse(ledger.takeRejected(uuid), "no in-app manual-answer arming over a live native UI")
        XCTAssertTrue(ledger.isNativelyReported(uuid))
        XCTAssertEqual(ledger.outstandingCount, 1)
    }

    // MARK: - Concurrency

    /// The reason this type exists: concurrent mutation from many threads
    /// (the pool-thread `async` members racing the main-thread synchronous
    /// ones) must leave the sets consistent. Without the lock this is a
    /// `Set` mutated from two threads — corruption or a crash, not a wrong
    /// count.
    func test_concurrentMutation_keepsSetsConsistent() {
        let ledger = CallKitCallLedger()
        let iterations = 400
        let uuids: [UUID] = (0..<iterations).map { _ in UUID() }
        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            let uuid = uuids[i]
            if i % 2 == 0 {
                ledger.recordNativeReport(uuid)
                ledger.recordRejected(uuid)
                _ = ledger.releaseNativeReport(uuid)
            } else {
                ledger.recordOutstanding(uuid)
                ledger.recordRejected(uuid)
                ledger.forget(uuid)
            }
            _ = ledger.outstandingCount
            _ = ledger.isNativelyReported(uuid)
        }
        // Even indices: outstanding (native mark released, rejected still armed).
        // Odd indices: forgotten entirely.
        XCTAssertEqual(ledger.outstandingCount, iterations / 2)
        for (i, uuid) in uuids.enumerated() {
            XCTAssertFalse(ledger.isNativelyReported(uuid))
            XCTAssertEqual(ledger.takeRejected(uuid), i % 2 == 0)
        }
        XCTAssertEqual(ledger.drainOutstanding().count, iterations / 2)
        XCTAssertEqual(ledger.outstandingCount, 0)
    }
}

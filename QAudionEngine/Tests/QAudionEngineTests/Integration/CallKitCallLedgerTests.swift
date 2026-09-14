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

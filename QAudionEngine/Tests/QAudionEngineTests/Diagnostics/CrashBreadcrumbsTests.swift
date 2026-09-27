import XCTest
@testable import QAudionEngine

/// W-CRASHCRUMBS (this task).
final class CrashBreadcrumbsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CrashBreadcrumbs.resetForTesting()
        CrashBreadcrumbs.clearCallContext()
    }

    override func tearDown() {
        CrashBreadcrumbs.resetForTesting()
        CrashBreadcrumbs.clearCallContext()
        super.tearDown()
    }

    // MARK: - Ring

    func test_add_thenSnapshot_returnsInOrder() {
        CrashBreadcrumbs.add("info", "call", "one")
        CrashBreadcrumbs.add("warn", "call", "two")
        let snap = CrashBreadcrumbs.snapshotForCrash()
        XCTAssertEqual(snap, ["info call: one", "warn call: two"])
    }

    func test_emptyRing_snapshotIsEmpty() {
        XCTAssertEqual(CrashBreadcrumbs.snapshotForCrash(), [])
    }

    func test_ring_evictsOldestPastCapacity() {
        for i in 0..<(CrashBreadcrumbs.capacity + 10) {
            CrashBreadcrumbs.add("info", "t", String(describing: i))
        }
        let snap = CrashBreadcrumbs.snapshotForCrash()
        XCTAssertEqual(snap.count, CrashBreadcrumbs.capacity)
        // The oldest 10 must be gone; the ring keeps the MOST RECENT lines.
        XCTAssertTrue(snap.first!.hasSuffix(": 10"))
        XCTAssertTrue(snap.last!.hasSuffix(": " + String(CrashBreadcrumbs.capacity + 9)))
    }

    func test_longLine_isTruncatedToMaxLineBytes() {
        let huge = String(repeating: "x", count: 500)
        CrashBreadcrumbs.add("info", "t", huge)
        let snap = CrashBreadcrumbs.snapshotForCrash()
        XCTAssertEqual(snap.count, 1)
        XCTAssertLessThanOrEqual(snap[0].utf8.count, CrashBreadcrumbs.maxLineBytes)
    }

    // MARK: - Call context

    func test_noContextSet_lastCallContextIsNil() {
        XCTAssertNil(CrashBreadcrumbs.lastCallContext())
    }

    func test_setCallContext_roundTrips_withTruncatedCallId() {
        CrashBreadcrumbs.setCallContext(inCall: true, native: true, role: "caller",
                                         callId: "abcdefghijklmnop", phase: "keying")
        let ctx = CrashBreadcrumbs.lastCallContext()
        XCTAssertNotNil(ctx)
        XCTAssertTrue(ctx!.contains("in_call=1"))
        XCTAssertTrue(ctx!.contains("native=1"))
        XCTAssertTrue(ctx!.contains("role=caller"))
        XCTAssertTrue(ctx!.contains("call8=abcdefgh"), "call id must be truncated to 8 chars: \(ctx!)")
        XCTAssertFalse(ctx!.contains("abcdefghijklmnop"), "the FULL call id must never be persisted")
        XCTAssertTrue(ctx!.contains("phase=keying"))
    }

    func test_clearCallContext_removesIt() {
        CrashBreadcrumbs.setCallContext(inCall: true, native: false, role: nil, callId: nil, phase: "start")
        XCTAssertNotNil(CrashBreadcrumbs.lastCallContext())
        CrashBreadcrumbs.clearCallContext()
        XCTAssertNil(CrashBreadcrumbs.lastCallContext())
    }

    func test_setCallContext_nonNative_reflectsInLine() {
        CrashBreadcrumbs.setCallContext(inCall: true, native: false, role: nil, callId: nil, phase: "start")
        XCTAssertEqual(CrashBreadcrumbs.lastCallContext(), "in_call=1 native=0 phase=start")
    }
}

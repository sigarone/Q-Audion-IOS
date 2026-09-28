import XCTest
@testable import QAudionEngine

/// W-MEDIAATACCEPT (option b) — G1/iOS-9: `PendingIceCandidateQueue` is a
/// process-wide singleton, so every test resets it in `setUp`/`tearDown`,
/// same discipline as `RingSignalingRegistryTests`/`CallKeyStoreTests`.
final class PendingIceCandidateQueueTests: XCTestCase {

    override func setUp() {
        super.setUp()
        PendingIceCandidateQueue.shared.resetForTesting()
    }

    override func tearDown() {
        PendingIceCandidateQueue.shared.resetForTesting()
        super.tearDown()
    }

    private func cand(_ s: String, removed: Bool = false) -> PendingIceCandidateQueue.Candidate {
        PendingIceCandidateQueue.Candidate(candidate: s, sdpMid: "0", sdpMLineIndex: 0, removed: removed)
    }

    // MARK: - Admission (delegates to RingSignalingDecisions.iceAdmit)

    func testEnqueueAdmitsMatchingCallId() {
        let q = PendingIceCandidateQueue.shared
        XCTAssertTrue(q.enqueue(callId: "abc", boundCallId: "abc", cand("c1")))
        XCTAssertEqual(q.peekForTesting("abc").count, 1)
    }

    func testEnqueueIsCaseInsensitiveOnCallId() {
        let q = PendingIceCandidateQueue.shared
        XCTAssertTrue(q.enqueue(callId: "ABC-Call", boundCallId: "abc-call", cand("c1")))
        XCTAssertEqual(q.peekForTesting("abc-call").count, 1)
    }

    func testEnqueueDropsMismatchedCallId() {
        let q = PendingIceCandidateQueue.shared
        XCTAssertFalse(q.enqueue(callId: "abc", boundCallId: "xyz", cand("c1")))
        XCTAssertEqual(q.peekForTesting("abc").count, 0)
    }

    func testEnqueueDropsEmptyCallId() {
        let q = PendingIceCandidateQueue.shared
        XCTAssertFalse(q.enqueue(callId: "", boundCallId: "", cand("c1")))
    }

    // MARK: - Cap (100 per call)

    func testEnqueueEnforcesPerCallCap() {
        let q = PendingIceCandidateQueue.shared
        for i in 0..<PendingIceCandidateQueue.perCallCap {
            XCTAssertTrue(q.enqueue(callId: "abc", boundCallId: "abc", cand("c\(i)")))
        }
        XCTAssertEqual(q.peekForTesting("abc").count, PendingIceCandidateQueue.perCallCap)
        // The 101st candidate for the SAME call is dropped, not evicting an
        // older one — the cap is a hard ceiling, not a FIFO within one call.
        XCTAssertFalse(q.enqueue(callId: "abc", boundCallId: "abc", cand("overflow")))
        XCTAssertEqual(q.peekForTesting("abc").count, PendingIceCandidateQueue.perCallCap)
    }

    // MARK: - Dedup (identical candidate, e.g. a WS retransmit)

    func testEnqueueDedupesIdenticalCandidate() {
        let q = PendingIceCandidateQueue.shared
        XCTAssertTrue(q.enqueue(callId: "abc", boundCallId: "abc", cand("same")))
        XCTAssertFalse(q.enqueue(callId: "abc", boundCallId: "abc", cand("same")))
        XCTAssertEqual(q.peekForTesting("abc").count, 1)
    }

    func testEnqueueDoesNotDedupeDifferentRemovedFlag() {
        // An add followed by its own removal are NOT the same entry (the
        // removal must still replay at flush time) — W-ICEBATCH parity.
        let q = PendingIceCandidateQueue.shared
        XCTAssertTrue(q.enqueue(callId: "abc", boundCallId: "abc", cand("same", removed: false)))
        XCTAssertTrue(q.enqueue(callId: "abc", boundCallId: "abc", cand("same", removed: true)))
        XCTAssertEqual(q.peekForTesting("abc").count, 2)
    }

    // MARK: - Isolation between calls

    func testQueuesAreIsolatedPerCall() {
        let q = PendingIceCandidateQueue.shared
        XCTAssertTrue(q.enqueue(callId: "call-a", boundCallId: "call-a", cand("ca1")))
        XCTAssertTrue(q.enqueue(callId: "call-b", boundCallId: "call-b", cand("cb1")))
        XCTAssertEqual(q.peekForTesting("call-a").map { $0.candidate }, ["ca1"])
        XCTAssertEqual(q.peekForTesting("call-b").map { $0.candidate }, ["cb1"])
    }

    // MARK: - Drain (read-and-clear, oldest first)

    func testDrainReturnsInOrderAndClears() {
        let q = PendingIceCandidateQueue.shared
        _ = q.enqueue(callId: "abc", boundCallId: "abc", cand("first"))
        _ = q.enqueue(callId: "abc", boundCallId: "abc", cand("second"))
        let drained = q.drain("abc")
        XCTAssertEqual(drained.map { $0.candidate }, ["first", "second"])
        XCTAssertEqual(q.peekForTesting("abc").count, 0)
    }

    func testDrainOnEmptyCallReturnsEmpty() {
        XCTAssertEqual(PendingIceCandidateQueue.shared.drain("nope"), [])
    }

    // MARK: - Wipe

    func testWipeClearsOnlyThatCall() {
        let q = PendingIceCandidateQueue.shared
        _ = q.enqueue(callId: "call-a", boundCallId: "call-a", cand("ca1"))
        _ = q.enqueue(callId: "call-b", boundCallId: "call-b", cand("cb1"))
        q.wipe("call-a")
        XCTAssertEqual(q.peekForTesting("call-a").count, 0)
        XCTAssertEqual(q.peekForTesting("call-b").count, 1)
    }

    func testWipeAllClearsEveryCall() {
        let q = PendingIceCandidateQueue.shared
        _ = q.enqueue(callId: "call-a", boundCallId: "call-a", cand("ca1"))
        _ = q.enqueue(callId: "call-b", boundCallId: "call-b", cand("cb1"))
        q.wipeAll()
        XCTAssertEqual(q.peekForTesting("call-a").count, 0)
        XCTAssertEqual(q.peekForTesting("call-b").count, 0)
    }

    // MARK: - Eviction (maxCalls)

    func testOldestCallEvictedBeyondMaxCalls() {
        let q = PendingIceCandidateQueue.shared
        for i in 0..<PendingIceCandidateQueue.maxCalls {
            XCTAssertTrue(q.enqueue(callId: "call-\(i)", boundCallId: "call-\(i)", cand("c")))
        }
        // One more distinct call evicts the OLDEST ("call-0").
        XCTAssertTrue(q.enqueue(callId: "call-new", boundCallId: "call-new", cand("c")))
        XCTAssertEqual(q.peekForTesting("call-0").count, 0)
        XCTAssertEqual(q.peekForTesting("call-new").count, 1)
    }
}

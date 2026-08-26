import XCTest
@testable import QAudionEngine

/// W-ROUTETIERDWELL (2026-08-26, best-practices audit item 3) — pins the
/// multi-poll dwell confirmation added to route-tier reclassification so a
/// single noisy candidate-pair stat can no longer swing the outgoing video
/// sender ceiling 4.5x, mirroring `evaluateBackpressure`'s existing
/// asymmetric dwell discipline. Same style as `RestartIceDecisionsTests`.
final class RouteTierDwellTests: XCTestCase {

    // MARK: - Constants — must match the CPU-backpressure knob's own numbers.

    func test_constants_matchBackpressureDwellCounts() {
        XCTAssertEqual(RouteTierDwell.sustainPolls, 2)
        XCTAssertEqual(RouteTierDwell.recoverPolls, 3)
    }

    // MARK: - First-ever resolution (from .unknown) commits immediately

    func test_firstResolution_direct_commitsImmediately() {
        var dwell = RouteTierDwell()
        XCTAssertEqual(dwell.committed, .unknown)
        XCTAssertTrue(dwell.observe(.direct))
        XCTAssertEqual(dwell.committed, .direct)
    }

    func test_firstResolution_relay_commitsImmediately() {
        var dwell = RouteTierDwell()
        XCTAssertTrue(dwell.observe(.relay))
        XCTAssertEqual(dwell.committed, .relay)
    }

    // MARK: - Direct -> Relay reclassification requires sustainPolls (2) agreement

    func test_directToRelay_singlePoll_doesNotCommit() {
        var dwell = RouteTierDwell(committed: .direct)
        XCTAssertFalse(dwell.observe(.relay))
        XCTAssertEqual(dwell.committed, .direct, "a single noisy poll must not swing the ceiling")
    }

    func test_directToRelay_commitsOnSecondConsecutivePoll() {
        var dwell = RouteTierDwell(committed: .direct)
        XCTAssertFalse(dwell.observe(.relay))
        XCTAssertTrue(dwell.observe(.relay))
        XCTAssertEqual(dwell.committed, .relay)
    }

    func test_directToRelay_interruptedDwell_resetsCount() {
        var dwell = RouteTierDwell(committed: .direct)
        XCTAssertFalse(dwell.observe(.relay))
        // A poll that reverts to the still-committed tier clears the
        // in-flight dwell entirely — it does not "bank" partial progress.
        XCTAssertFalse(dwell.observe(.direct))
        XCTAssertFalse(dwell.observe(.relay), "dwell count must have reset, not carried over")
        XCTAssertEqual(dwell.committed, .direct)
        XCTAssertTrue(dwell.observe(.relay))
        XCTAssertEqual(dwell.committed, .relay)
    }

    // MARK: - Relay -> Direct reclassification requires recoverPolls (3) agreement

    func test_relayToDirect_twoPolls_doesNotCommit() {
        var dwell = RouteTierDwell(committed: .relay)
        XCTAssertFalse(dwell.observe(.direct))
        XCTAssertFalse(dwell.observe(.direct))
        XCTAssertEqual(dwell.committed, .relay, "recovery is slower to trust than degradation")
    }

    func test_relayToDirect_commitsOnThirdConsecutivePoll() {
        var dwell = RouteTierDwell(committed: .relay)
        XCTAssertFalse(dwell.observe(.direct))
        XCTAssertFalse(dwell.observe(.direct))
        XCTAssertTrue(dwell.observe(.direct))
        XCTAssertEqual(dwell.committed, .direct)
    }

    // MARK: - Steady state: repeated agreement with the committed tier is a no-op

    func test_repeatedAgreementWithCommittedTier_neverReCommits() {
        var dwell = RouteTierDwell(committed: .direct)
        for _ in 0..<10 {
            XCTAssertFalse(dwell.observe(.direct))
        }
        XCTAssertEqual(dwell.committed, .direct)
    }

    // MARK: - Oscillation never commits on a single blip in either direction

    func test_oscillatingPolls_neverCommit() {
        var dwell = RouteTierDwell(committed: .direct)
        for _ in 0..<6 {
            XCTAssertFalse(dwell.observe(.relay))
            XCTAssertFalse(dwell.observe(.direct))
        }
        XCTAssertEqual(dwell.committed, .direct)
    }

    // MARK: - reset()

    func test_reset_clearsCommittedAndInFlightDwell() {
        var dwell = RouteTierDwell(committed: .relay)
        XCTAssertFalse(dwell.observe(.direct))
        dwell.reset()
        XCTAssertEqual(dwell.committed, .unknown)
        // Post-reset, the next observation is treated as a first-ever
        // resolution again (commits immediately).
        XCTAssertTrue(dwell.observe(.direct))
        XCTAssertEqual(dwell.committed, .direct)
    }
}

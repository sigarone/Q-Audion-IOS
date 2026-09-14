import XCTest
@testable import QAudionApp

/// Pins which readiness answers make a node a candidate for a NEW connection.
///
/// The probe used to hit `/api/v1/health` and accept any status below 500,
/// which meant it could not hear a refusal even in principle: `/health` is a
/// liveness signal and answers 200 for as long as the process is up. A node
/// shedding load, serving a read-only replica, or already draining passed that
/// check as the most attractive destination in the fleet. `/api/v1/ready`
/// answers the other question, and this is the predicate that reads it.
final class ServerSelectorReadinessProbeTests: XCTestCase {

    func testReadyNodeIsACandidate() {
        XCTAssertTrue(ServerSelector.isProbeAcceptable(200))
    }

    func testNodeDecliningNewWorkIsNot() {
        // 503 is shedding / read-only / draining. Selecting it anyway would
        // fight the very mechanism that produced the 503.
        XCTAssertFalse(ServerSelector.isProbeAcceptable(503))
    }

    func testNodeTooOldToHaveTheEndpointStillCounts() {
        // Mid-rollout every un-upgraded node returns 404. Excluding them would
        // empty the candidate list and turn an upgrade into an outage.
        XCTAssertTrue(ServerSelector.isProbeAcceptable(404))
    }

    func testAnythingElseIsNotUsable() {
        // Notably 401: the old probe accepted it explicitly ("server is alive"),
        // which was the correct reading for liveness and the wrong one here.
        for code in [401, 403, 429, 500, 502, 504] {
            XCTAssertFalse(ServerSelector.isProbeAcceptable(code), "status \(code)")
        }
    }
}

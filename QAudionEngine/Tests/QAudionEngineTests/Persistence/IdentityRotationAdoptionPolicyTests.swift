import XCTest
@testable import QAudionEngine

/// 2026-09-19 — a rotated identity key the user had SAS-verified the previous key for is adopted only by a
/// fresh SAS confirmation on the call that presented it, and only when that call's SAS is bound to the
/// handshake transcript. See `IdentityRotationAdoptionPolicy`.
final class IdentityRotationAdoptionPolicyTests: XCTestCase {

    func test_adoptsForThePeerOfTheCallWhenTheSasIsTranscriptBound() {
        XCTAssertTrue(IdentityRotationAdoptionPolicy.mayAdopt(
            pendingPeerId: "peer-a", activePeerId: "peer-a", sessionKeyTranscriptBound: true))
    }

    func test_refusesWhenTheSasIsNotBoundToTheTranscript() {
        // The words then say nothing about the signer identity key, so a match proves nothing about it.
        XCTAssertFalse(IdentityRotationAdoptionPolicy.mayAdopt(
            pendingPeerId: "peer-a", activePeerId: "peer-a", sessionKeyTranscriptBound: false))
    }

    func test_refusesWhenTheConfirmedCallIsWithSomeoneElse() {
        XCTAssertFalse(IdentityRotationAdoptionPolicy.mayAdopt(
            pendingPeerId: "peer-a", activePeerId: "peer-b", sessionKeyTranscriptBound: true))
    }

    func test_refusesWithNoPendingRotationOrNoActiveCall() {
        XCTAssertFalse(IdentityRotationAdoptionPolicy.mayAdopt(
            pendingPeerId: nil, activePeerId: "peer-a", sessionKeyTranscriptBound: true))
        XCTAssertFalse(IdentityRotationAdoptionPolicy.mayAdopt(
            pendingPeerId: "peer-a", activePeerId: nil, sessionKeyTranscriptBound: true))
        XCTAssertFalse(IdentityRotationAdoptionPolicy.mayAdopt(
            pendingPeerId: "", activePeerId: "", sessionKeyTranscriptBound: true))
    }
}

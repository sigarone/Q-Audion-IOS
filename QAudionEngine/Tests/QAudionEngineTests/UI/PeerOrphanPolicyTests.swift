import XCTest
@testable import QAudionEngine

/// W-ORPHANPEER (2026-07-22) — fences the rule for hiding contacts whose
/// account no longer exists on the server. iOS third of a three-platform
/// contract; the twins are Desktop's `test/PeerOrphanPolicy.spec.ts` and
/// Android's `PeerOrphanPolicyTest.kt`, and all three must stay in agreement
/// or the clients disagree about who exists.
///
/// The safety of the whole feature rests on one distinction: "the account is
/// gone" may hide things, "we could not find out" may never. On iOS that is
/// especially easy to lose, because `AccountApi.getPublicUser` throws for
/// every failure and the `try? await` idiom — which the app already uses
/// elsewhere for its own good reasons — collapses a deleted account, an
/// offline radio, a 401 and a timeout into one `nil`. Deciding to hide on
/// that would empty the address book on a flaky link.
///
/// Pure by design: no WebRTC, no UIKit, so this runs in the macOS `swift test`
/// CI job, which has no WebRTC slice.
final class PeerOrphanPolicyTests: XCTestCase {

    // MARK: - classifyProfileLookup

    func testSuccessMeansTheAccountExists() {
        XCTAssertEqual(classifyProfileLookup(succeeded: true, httpStatus: nil), .exists)
    }

    func test404IsTheServerSayingTheAccountIsGone() {
        XCTAssertEqual(classifyProfileLookup(succeeded: false, httpStatus: 404), .absent)
    }

    /// THE regression guard. Every one of these means "we do not know", and
    /// not one may hide a contact.
    func testNoOtherFailureIsEverTreatedAsAbsence() {
        for status in [400, 401, 403, 408, 429, 500, 502, 503, 504] {
            XCTAssertEqual(
                classifyProfileLookup(succeeded: false, httpStatus: status),
                .unknown,
                "status \(status) must not classify as absent"
            )
        }
    }

    /// A transport failure carries no status at all — offline, DNS, TLS,
    /// timeout, cancellation. Pinned separately because it is the common case
    /// on a phone and the one most likely to be mishandled.
    func testTransportFailureWithNoStatusIsUnknown() {
        XCTAssertEqual(classifyProfileLookup(succeeded: false, httpStatus: nil), .unknown)
    }

    // MARK: - isOrphanPeer

    func testOnlyDefinitiveAbsenceMarksAnOrphan() {
        XCTAssertTrue(isOrphanPeer(.absent))
        XCTAssertFalse(isOrphanPeer(.exists))
        XCTAssertFalse(isOrphanPeer(.unknown))
    }

    func testItIsExactlyOneOutcomeNotEverythingThatIsNotExists() {
        XCTAssertEqual(ProfileLookupOutcome.allCases.filter { isOrphanPeer($0) }, [.absent])
    }

    // MARK: - hiding rules

    func testAnOrphanIsHiddenFromTheAddressBookAndNobodyElseIs() {
        XCTAssertTrue(shouldHideContact(true))
        XCTAssertFalse(shouldHideContact(false))
    }

    func testAnEmptyConversationWithAnOrphanDisappears() {
        XCTAssertTrue(shouldHideConversation(peerIsOrphan: true, messageCount: 0))
    }

    /// The deliberate limit on the feature, chosen explicitly rather than
    /// overlooked: those messages are end-to-end encrypted and exist nowhere
    /// else, so the account being gone does not make them disposable.
    func testAConversationCarryingMessagesIsNeverHidden() {
        XCTAssertFalse(shouldHideConversation(peerIsOrphan: true, messageCount: 1))
        XCTAssertFalse(shouldHideConversation(peerIsOrphan: true, messageCount: 4200))
    }

    func testALivePeerIsLeftAloneEvenWithAnEmptyConversation() {
        XCTAssertFalse(shouldHideConversation(peerIsOrphan: false, messageCount: 0))
    }

    func testANegativeCountIsTreatedAsEmptyRatherThanCrashing() {
        XCTAssertTrue(shouldHideConversation(peerIsOrphan: true, messageCount: -1))
    }
}

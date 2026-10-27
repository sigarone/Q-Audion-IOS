import XCTest
@testable import QAudionEngine

/// The allow-list of v5/v6 call close reasons, and which one an ending call reports.
final class CallCloseReasonTests: XCTestCase {

    func testTheAllowListIsExactlyTheEightReasons() {
        XCTAssertEqual(Set(CallCloseReason.allTokens), [
            "dtls_fp_mismatch", "kcmac_mismatch", "handshake_malformed",
            "identity_unresolved", "identity_key_mismatch",
            "sas_commit_mismatch", "sas_reveal_timeout", "peer_incompatible",
        ])
        for reason in CallCloseReason.allCases {
            XCTAssertEqual(CallCloseReason.accepted(reason.rawValue), reason)
            XCTAssertEqual(reason.labelKey, "call_history.close." + reason.rawValue)
        }
    }

    func testAnythingElseIsNotAccepted() {
        XCTAssertNil(CallCloseReason.accepted(nil))
        XCTAssertNil(CallCloseReason.accepted(""))
        XCTAssertNil(CallCloseReason.accepted("user_hangup"))
        XCTAssertNil(CallCloseReason.accepted("sig_invalid"))
        XCTAssertNil(CallCloseReason.accepted("Identity_Key_Mismatch"), "exact, case-sensitive tokens")
        XCTAssertNil(CallCloseReason.accepted("identity_key_mismatch "))
    }

    func testAHandshakeFatalAlwaysWinsOverAHold() {
        XCTAssertEqual(
            CallCloseReason.forEnd(fatalReason: "kcmac_mismatch", heldIdentityCode: "identity_unresolved"),
            .kcmacMismatch)
        XCTAssertEqual(CallCloseReason.forEnd(fatalReason: "dtls_fp_mismatch", heldIdentityCode: nil), .dtlsFpMismatch)
        XCTAssertEqual(CallCloseReason.forEnd(fatalReason: "handshake_malformed", heldIdentityCode: nil), .handshakeMalformed)
    }

    /// R-COMMIT-REASONS: the two SAS-commitment reasons are security reasons that win like any handshake
    /// fatal; as hold codes they are not identity reasons.
    func testTheSasCommitReasonsAreFatalReasons() {
        XCTAssertEqual(
            CallCloseReason.forEnd(fatalReason: "sas_commit_mismatch", heldIdentityCode: "identity_unresolved"),
            .sasCommitMismatch)
        XCTAssertEqual(CallCloseReason.forEnd(fatalReason: "sas_reveal_timeout", heldIdentityCode: nil), .sasRevealTimeout)
        XCTAssertNil(CallCloseReason.forEnd(fatalReason: nil, heldIdentityCode: "sas_reveal_timeout"))
        XCTAssertNil(CallCloseReason.accepted("answered_on_other_device"), "the sibling exit is not a security reason")
    }

    func testACallClosedWhileHeldReportsTheIdentityReason() {
        XCTAssertEqual(CallCloseReason.forEnd(fatalReason: nil, heldIdentityCode: "identity_unresolved"), .identityUnresolved)
        XCTAssertEqual(CallCloseReason.forEnd(fatalReason: nil, heldIdentityCode: "identity_key_mismatch"), .identityKeyMismatch)
    }

    func testOtherHoldCodesAndOrdinaryEndsReportNothing() {
        XCTAssertNil(CallCloseReason.forEnd(fatalReason: nil, heldIdentityCode: "sig_invalid"))
        XCTAssertNil(CallCloseReason.forEnd(fatalReason: nil, heldIdentityCode: "ratchet_v5_downgrade"))
        XCTAssertNil(CallCloseReason.forEnd(fatalReason: nil, heldIdentityCode: nil))
        // A hold code that is a fatal token is not a hold reason.
        XCTAssertNil(CallCloseReason.forEnd(fatalReason: nil, heldIdentityCode: "kcmac_mismatch"))
        XCTAssertNil(CallCloseReason.forEnd(fatalReason: "user_hangup", heldIdentityCode: nil))
    }

    /// An incompatible peer is a fatal reason of its own, distinct from a malformed handshake in the history,
    /// while the hangup on the wire keeps the reason every platform understands.
    func testPeerIncompatibleIsADistinctFatalReasonWithTheMalformedWireReason() {
        XCTAssertEqual(CallCloseReason.forEnd(fatalReason: "peer_incompatible", heldIdentityCode: nil), .peerIncompatible)
        XCTAssertEqual(
            CallCloseReason.forEnd(fatalReason: "peer_incompatible", heldIdentityCode: "identity_unresolved"),
            .peerIncompatible)
        XCTAssertNil(CallCloseReason.forEnd(fatalReason: nil, heldIdentityCode: "peer_incompatible"))
        XCTAssertNotEqual(CallCloseReason.peerIncompatible, .handshakeMalformed)
        XCTAssertEqual(CallCloseReason.peerIncompatible.wireReason, "handshake_malformed")
        for reason in CallCloseReason.allCases where reason != .peerIncompatible {
            XCTAssertEqual(reason.wireReason, reason.rawValue)
        }
    }
}

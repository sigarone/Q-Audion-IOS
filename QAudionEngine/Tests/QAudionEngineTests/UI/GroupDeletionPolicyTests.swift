import XCTest
@testable import QAudionEngine

/// W-GRPDEL (2026-08-02) — fences the rules behind "delete a group chat from
/// my device even though I did not create it". iOS third of a three-platform
/// contract; the twins are Android's `GroupDeletionPolicyTest.kt` and
/// Desktop's `test/groupDeletionPolicy.spec.ts`, and all three must agree or
/// the clients disagree about which groups still exist for a user.
///
/// Two rules carry the whole feature and both are easy to get subtly wrong:
///
///   1. **The local purge is unconditional.** The server leave call is
///      best-effort — offline, 403, 5xx, a timeout, a pinning failure — and
///      none of those may leave the user holding a row they cannot get rid
///      of. That is the exact bug this feature exists to fix: the server used
///      to answer 400 "you are not a member of this group" for an
///      already-left group, every client rendered it as "does not exist" and
///      then kept the row anyway.
///
///   2. **A tombstone is cleared only by an explicit re-add.** Every client
///      re-syncs groups from `GET /api/v1/groups` on launch and on WS
///      reconnect, so without a tombstone the deleted chat comes back within
///      seconds. But a tombstone that can never be cleared is just as broken:
///      the user could never be re-added. The distinction that makes both
///      safe is that a PASSIVE listing (the group appearing in a reconcile
///      sweep, a snapshot replay of the roster) is not consent, while an
///      event that names THIS user as newly added is.
///
/// Pure by design: no Keychain, no UserDefaults, no WebRTC, no UIKit — the
/// stores that hold the actual state call into these functions rather than
/// re-deriving the rules themselves.
final class GroupDeletionPolicyTests: XCTestCase {

    // MARK: - normalizedGroupTombstoneKey

    /// THE interop trap. The server speaks dashed UUIDs (`group_id` on the
    /// wire, the REST path segment), the local registry / GroupChatService /
    /// GroupMessageStore all key on dash-stripped lowercase hex. A tombstone
    /// written under one form and read under the other is no tombstone at
    /// all — the group is silently resurrected on the next reconcile and the
    /// bug looks exactly like "the tombstone does not work".
    func testDashedUuidAndStrippedHexCollapseToTheSameKey() {
        let dashed = "3FEDC2E7-1A2B-4C3D-8E9F-0011223344AA"
        let hex = "3fedc2e71a2b4c3d8e9f0011223344aa"
        XCTAssertEqual(normalizedGroupTombstoneKey(dashed), hex)
        XCTAssertEqual(normalizedGroupTombstoneKey(hex), hex)
        XCTAssertEqual(normalizedGroupTombstoneKey(dashed),
                       normalizedGroupTombstoneKey(hex))
    }

    func testSurroundingWhitespaceIsNotPartOfTheKey() {
        XCTAssertEqual(normalizedGroupTombstoneKey("  3fedc2e7  "), "3fedc2e7")
    }

    func testAnEmptyIdNormalizesToEmptyRatherThanCrashing() {
        XCTAssertEqual(normalizedGroupTombstoneKey(""), "")
        XCTAssertEqual(normalizedGroupTombstoneKey("   "), "")
    }

    // MARK: - classifyGroupLeave

    func testA2xxLeaveIsARealDeparture() {
        XCTAssertEqual(classifyGroupLeave(succeeded: true, httpStatus: 200), .left)
    }

    /// Since the W-GRPGHOST server fix (bcrypto-server 54c9f5d) leaving a
    /// group you already left answers 200 with no membership change. That is
    /// success, and the client must not special-case it into an error.
    func testAnAlreadyLeftGroupAnsweringTwoHundredIsSuccess() {
        XCTAssertEqual(classifyGroupLeave(succeeded: true, httpStatus: 200), .left)
    }

    func testEveryNonSuccessStatusIsARejectionCarryingItsCode() {
        for status in [400, 401, 403, 404, 409, 410, 422, 500, 502, 503] {
            XCTAssertEqual(
                classifyGroupLeave(succeeded: false, httpStatus: status),
                .rejected(status: status),
                "status \(status) must be reported verbatim, not flattened")
        }
    }

    /// Offline, DNS, TLS/pinning, timeout, cancellation — no HTTP status ever
    /// materialized. Kept distinct from `.rejected` purely so the log line
    /// says which one happened; both purge.
    func testATransportFailureWithNoStatusIsUnreachable() {
        XCTAssertEqual(classifyGroupLeave(succeeded: false, httpStatus: nil), .unreachable)
    }

    // MARK: - shouldPurgeLocalGroupState  (the fail-open rule)

    /// The single most important assertion in this file. If any future edit
    /// makes the purge conditional on the server having answered, the
    /// undeletable-chat bug is back.
    func testTheLocalPurgeHappensNoMatterWhatTheServerSaid() {
        let everyOutcome: [GroupLeaveOutcome] = [
            .left,
            .unreachable,
            .notAttempted,
            .rejected(status: 400),
            .rejected(status: 401),
            .rejected(status: 403),
            .rejected(status: 404),
            .rejected(status: 410),
            .rejected(status: 422),
            .rejected(status: 500),
            .rejected(status: 503),
        ]
        for outcome in everyOutcome {
            XCTAssertTrue(
                shouldPurgeLocalGroupState(after: outcome),
                "\(outcome) must still purge — the user asked to delete this chat")
        }
    }

    /// Same rule for the tombstone: a group whose leave call never even left
    /// the device is the case that MOST needs a tombstone, because the
    /// server still lists the user as a member and the next reconcile would
    /// otherwise bring the chat straight back.
    func testTheTombstoneIsWrittenNoMatterWhatTheServerSaid() {
        for outcome: GroupLeaveOutcome in [.left, .unreachable, .notAttempted, .rejected(status: 503)] {
            XCTAssertTrue(shouldWriteGroupTombstone(after: outcome), "\(outcome)")
        }
    }

    // MARK: - clearsGroupTombstone

    /// A reconcile sweep listing the group is NOT consent to have it back.
    /// This is the passive path that runs on every launch and every WS
    /// reconnect; if it cleared the tombstone the delete would survive
    /// roughly one second.
    func testAPassiveListingNeverClearsATombstone() {
        XCTAssertFalse(clearsGroupTombstone(.passiveReconcileListing))
        XCTAssertFalse(clearsGroupTombstone(.serverMembershipSnapshot))
    }

    /// Nor does an inbound group message. The sender does not know we left,
    /// and store-and-forward can deliver frames queued before the delete.
    func testAnInboundGroupFrameNeverClearsATombstone() {
        XCTAssertFalse(clearsGroupTombstone(.inboundGroupMessage))
    }

    /// The escape hatch that keeps the tombstone from being a life sentence:
    /// an admin adding this user back, over either transport, and an invite
    /// the user actually accepted.
    func testAnExplicitReAddClearsTheTombstone() {
        XCTAssertTrue(clearsGroupTombstone(.membershipEventAddingSelf))
        XCTAssertTrue(clearsGroupTombstone(.p2pMemberAddedNamingSelf))
        XCTAssertTrue(clearsGroupTombstone(.acceptedInvite))
    }

    /// Pins the split exhaustively, so a source added later has to be
    /// classified deliberately instead of inheriting whichever side the
    /// author happened to write first.
    func testExactlyThreeSourcesCountAsAnExplicitReAdd() {
        XCTAssertEqual(
            Set(GroupResurrectionSource.allCases.filter { clearsGroupTombstone($0) }),
            Set([.membershipEventAddingSelf, .p2pMemberAddedNamingSelf, .acceptedInvite]))
    }

    // MARK: - shouldSkipGroupResurrection

    func testWithoutATombstoneNothingIsEverSkipped() {
        for source in GroupResurrectionSource.allCases {
            XCTAssertFalse(
                shouldSkipGroupResurrection(source: source, hasTombstone: false),
                "\(source) must be unaffected when the group was never deleted")
        }
    }

    func testWithATombstonePassiveSourcesAreSkippedAndReAddsAreNot() {
        XCTAssertTrue(shouldSkipGroupResurrection(source: .passiveReconcileListing, hasTombstone: true))
        XCTAssertTrue(shouldSkipGroupResurrection(source: .serverMembershipSnapshot, hasTombstone: true))
        XCTAssertTrue(shouldSkipGroupResurrection(source: .inboundGroupMessage, hasTombstone: true))
        XCTAssertFalse(shouldSkipGroupResurrection(source: .membershipEventAddingSelf, hasTombstone: true))
        XCTAssertFalse(shouldSkipGroupResurrection(source: .p2pMemberAddedNamingSelf, hasTombstone: true))
        XCTAssertFalse(shouldSkipGroupResurrection(source: .acceptedInvite, hasTombstone: true))
    }

    // MARK: - classifyMembershipEventForTombstone

    /// The server reuses ONE `group_membership_changed` event for adds,
    /// removes, admin promote/demote and catch-up snapshots, so "does this
    /// event add me?" has to be read off `operation` + `subject_user_id`
    /// rather than from the roster merely containing us — the roster
    /// contains us on every snapshot replay too.
    func testOnlyAnAddOperationNamingSelfCountsAsAReAdd() {
        XCTAssertEqual(
            classifyMembershipEventForTombstone(operation: "add", subjectUserId: "u1", selfUserId: "u1"),
            .membershipEventAddingSelf)
        XCTAssertEqual(
            classifyMembershipEventForTombstone(operation: "member_added", subjectUserId: "u1", selfUserId: "u1"),
            .membershipEventAddingSelf)
    }

    func testAnAddNamingSomebodyElseIsNotAReAddOfSelf() {
        XCTAssertEqual(
            classifyMembershipEventForTombstone(operation: "add", subjectUserId: "u2", selfUserId: "u1"),
            .serverMembershipSnapshot)
    }

    /// The catch-up burst the server sends on every reconnect. It lists the
    /// full roster — including us — with `operation: "snapshot"`, and it is
    /// the single most likely thing to resurrect a deleted group.
    func testASnapshotReplayIsNeverAReAddEvenThoughItListsUs() {
        XCTAssertEqual(
            classifyMembershipEventForTombstone(operation: "snapshot", subjectUserId: "", selfUserId: "u1"),
            .serverMembershipSnapshot)
    }

    func testRemovesAndAdminOpsAreNotReAdds() {
        for op in ["remove", "leave", "member_removed", "member_left", "admin_add", "admin_remove", ""] {
            XCTAssertEqual(
                classifyMembershipEventForTombstone(operation: op, subjectUserId: "u1", selfUserId: "u1"),
                .serverMembershipSnapshot,
                "operation \(op) must not clear a tombstone")
        }
    }

    func testAnEmptySelfIdCanNeverMatchTheSubject() {
        XCTAssertEqual(
            classifyMembershipEventForTombstone(operation: "add", subjectUserId: "", selfUserId: ""),
            .serverMembershipSnapshot)
    }
}

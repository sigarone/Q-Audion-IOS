import XCTest
@testable import QAudionEngine

/// W-GRPNAME (2026-08-02) — fences the rules behind "a group is never
/// nameless, not even for a second". iOS half of a three-platform contract;
/// the Desktop twin is `test/messaging/groupCreation.spec.ts` +
/// `groupCreationFanout.spec.ts`, and the two must agree or a group created
/// on one platform renders as a raw id on the other.
///
/// The bug this exists to prevent is on record: group `1a751eae` was created
/// at 06:34:08 and only reached `metadata_version = 1` at 06:34:46 — 38
/// seconds during which every member who learned of it from a server
/// snapshot saw a raw hex id as the chat name, and permanently so had that
/// second call failed.
///
/// Pure by design: no Keychain, no UserDefaults, no network — `AppState`
/// calls into these functions rather than re-deriving the rules inline.
final class GroupCreationPolicyTests: XCTestCase {

    // MARK: - Constants shared with the server and the other clients

    /// Server contract, verbatim: `metadata_version`, when sent with a blob,
    /// must be >= 1. Zero means "no metadata" server-side, so stamping 0 on a
    /// real blob is the same defect as not sending one. Desktop pins the same
    /// value in `GROUP_METADATA_INITIAL_VERSION`.
    func testTheFirstPublishedMetadataVersionIsOne() {
        XCTAssertEqual(initialGroupMetadataVersion, 1)
    }

    /// The founding epoch every platform AND the server bootstrap at. Adopting
    /// Go's zero value here once made every Android group message
    /// undecryptable on iOS.
    func testTheFoundingGroupEpochIsOne() {
        XCTAssertEqual(initialGroupEpoch, 1)
    }

    // MARK: - groupNameToPublishAtCreation

    func testARealNameIsPublishedVerbatim() {
        XCTAssertEqual(groupNameToPublishAtCreation("Famiglia"), "Famiglia")
    }

    func testSurroundingWhitespaceIsTrimmedBeforePublishing() {
        XCTAssertEqual(groupNameToPublishAtCreation("  Team Milano \n"), "Team Milano")
    }

    /// Nothing to publish beats publishing nothing: an empty name sealed into
    /// a blob would burn version 1 on something that renders as no name at
    /// all, and the monotonic `metadata_version` guard would then make the
    /// real first rename harder to land, not easier.
    func testABlankNameIsNotWorthPublishing() {
        XCTAssertNil(groupNameToPublishAtCreation(""))
        XCTAssertNil(groupNameToPublishAtCreation("   "))
        XCTAssertNil(groupNameToPublishAtCreation("\n\t "))
    }

    /// The poisoning case. A device that only ever saw the local placeholder
    /// must never publish it as the group's canonical name — every other
    /// member would then adopt "Gruppo a1b2c3d4…" as the REAL name and no
    /// later rename could be distinguished from it.
    func testASynthesizedPlaceholderIsNeverPublishedAsARealName() {
        XCTAssertNil(groupNameToPublishAtCreation("Gruppo a1b2c3d4…"))
        XCTAssertNil(groupNameToPublishAtCreation("a1b2c3d4…"))
    }

    /// The blank-name fallback the create sheet synthesises ("Gruppo 3
    /// membri") IS a real user-facing name and must survive the check above —
    /// it only looks superficially like the placeholder.
    func testTheMemberCountFallbackNameIsStillARealName() {
        XCTAssertEqual(groupNameToPublishAtCreation("Gruppo 3 membri"), "Gruppo 3 membri")
    }

    // MARK: - isSynthesizedGroupPlaceholderName

    func testBothPlaceholderShapesAreRecognised() {
        // Current shape — DisplayName.shortGroupFallback.
        XCTAssertTrue(isSynthesizedGroupPlaceholderName("Gruppo 3fedc2e7…"))
        // Legacy shape — the bare hex fragment older builds persisted, which
        // is exactly what "the group renamed itself to 3fedc2e7…" looked like.
        XCTAssertTrue(isSynthesizedGroupPlaceholderName("3fedc2e7…"))
    }

    func testARealNameIsNeverMistakenForAPlaceholder() {
        for name in ["Famiglia", "Gruppo 3 membri", "Team", "…", "",
                     "Gruppo", "3fedc2e7", "Gruppo zzzzzzzz…", "Gruppo 3fedc2e…"] {
            XCTAssertFalse(isSynthesizedGroupPlaceholderName(name),
                           "\(name) is not a synthesized placeholder")
        }
    }

    func testPlaceholderDetectionIgnoresSurroundingWhitespace() {
        XCTAssertTrue(isSynthesizedGroupPlaceholderName("  Gruppo 3fedc2e7…  "))
    }

    // MARK: - groupCreatePublishVerdict

    /// The happy path: we published a blob, the server stored it at the epoch
    /// we sealed for, and echoed the version.
    func testAStoredBlobAtOurEpochIsPublished() {
        let v = groupCreatePublishVerdict(
            sentBlob: true, localEpoch: 1, serverEpoch: 1, serverMetadataVersion: 1)
        XCTAssertTrue(v.namePublished)
        XCTAssertEqual(v.publishedVersion, 1)
        XCTAssertNil(v.rebuildAtEpoch)
        XCTAssertFalse(v.needsMetadataPut)
        XCTAssertEqual(v.reason, .published)
    }

    /// A server that ignored the new fields (older build) answers without a
    /// `metadata_version`, i.e. 0 — the group therefore has NO metadata. We
    /// must not credit ourselves with a version we do not have, and we must
    /// fall back to the ordinary PUT rather than leave the group nameless.
    func testAServerThatDidNotStoreTheBlobFallsBackToThePut() {
        let v = groupCreatePublishVerdict(
            sentBlob: true, localEpoch: 1, serverEpoch: 1, serverMetadataVersion: 0)
        XCTAssertFalse(v.namePublished)
        XCTAssertEqual(v.publishedVersion, 0)
        XCTAssertTrue(v.needsMetadataPut)
        XCTAssertEqual(v.reason, .serverIgnoredBlob)
    }

    /// No blob was sealed (blank name, or the engine failed): the old
    /// two-call behaviour is the fallback, never "give up on the name".
    func testNoBlobFallsBackToThePut() {
        let v = groupCreatePublishVerdict(
            sentBlob: false, localEpoch: 1, serverEpoch: 1, serverMetadataVersion: 0)
        XCTAssertFalse(v.namePublished)
        XCTAssertTrue(v.needsMetadataPut)
        XCTAssertEqual(v.reason, .noBlob)
    }

    /// EPOCH DOMINATES. The 0xE4 wire binds `group_epoch` into its AAD, so a
    /// blob sealed at our epoch is unreadable by anyone once the group lives
    /// at another one — and an accepted-but-unreadable blob is worse than
    /// none, because its version would suppress the retry.
    func testAnEpochMismatchBeatsEvenAStoredVersion() {
        let v = groupCreatePublishVerdict(
            sentBlob: true, localEpoch: 1, serverEpoch: 2, serverMetadataVersion: 1)
        XCTAssertFalse(v.namePublished)
        XCTAssertEqual(v.publishedVersion, 0)
        XCTAssertEqual(v.rebuildAtEpoch, 2)
        XCTAssertTrue(v.needsMetadataPut)
        XCTAssertEqual(v.reason, .epochMismatch)
    }

    /// An absent/zero server epoch is NOT an epoch mismatch — it is simply
    /// absent, and 0 is the exact value whose adoption broke Android↔iOS.
    func testAnAbsentServerEpochIsNeverAdoptedNorTreatedAsAMismatch() {
        let v = groupCreatePublishVerdict(
            sentBlob: true, localEpoch: 1, serverEpoch: 0, serverMetadataVersion: 1)
        XCTAssertEqual(v.reason, .published)
        XCTAssertNil(v.rebuildAtEpoch)
    }

    /// Every non-published verdict must ask for the PUT — the whole point is
    /// that "the name did not get published" is never a terminal state.
    func testEveryUnpublishedVerdictAsksForTheMetadataPut() {
        let unpublished: [GroupCreatePublishVerdict] = [
            groupCreatePublishVerdict(sentBlob: false, localEpoch: 1, serverEpoch: 1, serverMetadataVersion: 0),
            groupCreatePublishVerdict(sentBlob: true, localEpoch: 1, serverEpoch: 1, serverMetadataVersion: 0),
            groupCreatePublishVerdict(sentBlob: true, localEpoch: 1, serverEpoch: 3, serverMetadataVersion: 1),
        ]
        for v in unpublished {
            XCTAssertFalse(v.namePublished, "\(v.reason)")
            XCTAssertTrue(v.needsMetadataPut, "\(v.reason)")
            XCTAssertEqual(v.publishedVersion, 0, "\(v.reason)")
        }
    }

    // MARK: - membershipEventIsAttested

    func testAFrameWithBothEnvelopeAndSignatureIsAttested() {
        XCTAssertTrue(membershipEventIsAttested(envelopeB64: "ZW52", signatureB64: "c2ln"))
    }

    /// The creation fan-out and the crash-recovery snapshot both arrive with
    /// empty envelope+signature: nothing signs a group into existence.
    func testAnEmptyOrHalfEmptyFrameIsNotAttested() {
        XCTAssertFalse(membershipEventIsAttested(envelopeB64: "", signatureB64: ""))
        XCTAssertFalse(membershipEventIsAttested(envelopeB64: "ZW52", signatureB64: ""))
        XCTAssertFalse(membershipEventIsAttested(envelopeB64: "", signatureB64: "c2ln"))
        XCTAssertFalse(membershipEventIsAttested(envelopeB64: "  ", signatureB64: "  "))
    }

    // MARK: - Creation fan-out × tombstone  (the regression fence)

    /// W-GRPDEL must survive W-GRPNAME, and this is the exact shape that
    /// threatens it. The creation fan-out is an `operation: "add"` naming a
    /// member of the founding roster, UNSIGNED — field for field
    /// indistinguishable from an admin adding this user back, which is the
    /// one event allowed to clear a tombstone. Attestation is what tells them
    /// apart: a re-add is a claim an admin key makes, not one a bare server
    /// frame can make.
    func testAnUnattestedAddNamingSelfNeverClearsATombstone() {
        let source = classifyMembershipEventForTombstone(
            operation: "add", subjectUserId: "u1", selfUserId: "u1",
            isReplay: false, isAttested: false)
        XCTAssertEqual(source, .serverMembershipSnapshot)
        XCTAssertFalse(clearsGroupTombstone(source))
        XCTAssertTrue(shouldSkipGroupResurrection(source: source, hasTombstone: true))
    }

    /// …while the ATTESTED re-add — `handleAddMember` fans out the admin's
    /// real signed envelope — still works. A fence that also blocked this
    /// would make the tombstone a life sentence, which is the other half of
    /// the W-GRPDEL contract.
    func testAnAttestedAddNamingSelfStillClearsATombstone() {
        let source = classifyMembershipEventForTombstone(
            operation: "add", subjectUserId: "u1", selfUserId: "u1",
            isReplay: false, isAttested: true)
        XCTAssertEqual(source, .membershipEventAddingSelf)
        XCTAssertTrue(clearsGroupTombstone(source))
        XCTAssertFalse(shouldSkipGroupResurrection(source: source, hasTombstone: true))
    }

    /// And an unattested frame still onboards a group that was never deleted:
    /// that is the whole point of the creation fan-out (a member added at
    /// creation learns of the group live instead of on the next reconcile).
    /// A fence that blocked the happy path would trade one broken behaviour
    /// for another.
    func testAnUnattestedFrameStillOnboardsAGroupThatWasNeverDeleted() {
        let source = classifyMembershipEventForTombstone(
            operation: "add", subjectUserId: "u1", selfUserId: "u1",
            isReplay: false, isAttested: false)
        XCTAssertFalse(shouldSkipGroupResurrection(source: source, hasTombstone: false))
    }

    /// Attestation is checked FIRST, so it wins over every operation
    /// vocabulary — and `replay` still wins on an attested frame, unchanged.
    func testAttestationAndReplayBothDowngradeToSnapshot() {
        for op in ["add", "member_added", "create", "created", "group_created"] {
            XCTAssertEqual(
                classifyMembershipEventForTombstone(
                    operation: op, subjectUserId: "u1", selfUserId: "u1",
                    isReplay: false, isAttested: false),
                .serverMembershipSnapshot,
                "unattested \(op)")
            XCTAssertEqual(
                classifyMembershipEventForTombstone(
                    operation: op, subjectUserId: "u1", selfUserId: "u1",
                    isReplay: true, isAttested: true),
                .serverMembershipSnapshot,
                "replayed \(op)")
        }
    }

    /// The attested overload must agree with the plain function on every
    /// input it does not veto — otherwise the two would drift and the older
    /// call sites would mean something different from the new one.
    func testTheAttestedOverloadMatchesThePlainOneWhenAttested() {
        for op in ["add", "member_added", "remove", "leave", "snapshot", "admin_add", ""] {
            for subject in ["u1", "u2", ""] {
                for replay in [true, false] {
                    XCTAssertEqual(
                        classifyMembershipEventForTombstone(
                            operation: op, subjectUserId: subject, selfUserId: "u1",
                            isReplay: replay, isAttested: true),
                        classifyMembershipEventForTombstone(
                            operation: op, subjectUserId: subject, selfUserId: "u1",
                            isReplay: replay),
                        "op=\(op) subject=\(subject) replay=\(replay)")
                }
            }
        }
    }
}

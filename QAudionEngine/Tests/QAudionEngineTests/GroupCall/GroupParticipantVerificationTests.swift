import XCTest
@testable import QAudionEngine

/// M3: which participants of a group call are shown as "not verified" and when the call screen shows
/// its banner. Pure state, no UI.
final class GroupParticipantVerificationTests: XCTestCase {

    private typealias Contact = ContactsStore.StoredContact

    private func contact(
        verified: Bool = false, verifiedAtMs: Int64? = nil,
        proximityAt: Int64? = nil, proximityConfirmed: Bool? = nil,
        presence: ContactsStore.PresenceAuth? = nil
    ) -> Contact {
        Contact(userId: "u1", displayName: "Alice", phoneHash: "", avatarUrl: nil, lastSeen: nil,
                isVerified: verified, verifiedAtMs: verifiedAtMs, presenceAuth: presence,
                proximityPairedAtMs: proximityAt, proximityServerConfirmed: proximityConfirmed)
    }

    private func presence(_ status: ContactsStore.PresenceAuth.Status) -> ContactsStore.PresenceAuth {
        ContactsStore.PresenceAuth(
            tier: .nfcPresent, keyFingerprint: String(repeating: "a", count: 64),
            peerIdentityKey: Data(repeating: 1, count: 32), firstConfirmedCallId: "c",
            firstConfirmedAt: 1, confirmedCallCount: 1, witnessTier: "secure_element", status: status)
    }

    private let keyA = Data(repeating: 0xA1, count: 32)
    private let keyB = Data(repeating: 0xB2, count: 32)

    // MARK: - isVerified

    func testNoRecordsAtAllIsNotVerified() {
        XCTAssertFalse(GroupParticipantVerification.isVerified(contact: nil, sasBinding: nil, pinnedKeys: []))
        XCTAssertFalse(GroupParticipantVerification.isVerified(contact: contact(), sasBinding: nil, pinnedKeys: [keyA]))
    }

    func testSasConfirmationAppliesOnlyToTheKeyItWasBoundTo() {
        let binding = SasBinding(sasFingerprint: "ab12", identityTag: SasBinding.identityTag(forPinnedKey: keyA))
        XCTAssertTrue(GroupParticipantVerification.isVerified(contact: nil, sasBinding: binding, pinnedKeys: [keyA]))
        XCTAssertTrue(GroupParticipantVerification.isVerified(contact: nil, sasBinding: binding, pinnedKeys: [keyB, keyA]),
                      "any pinned device key of the peer may carry the confirmation")
        // The pin moved to another key: the old confirmation does not vouch for it.
        XCTAssertFalse(GroupParticipantVerification.isVerified(contact: nil, sasBinding: binding, pinnedKeys: [keyB]))
        // No pin at all: nothing to apply the confirmation to.
        XCTAssertFalse(GroupParticipantVerification.isVerified(contact: nil, sasBinding: binding, pinnedKeys: []))
    }

    func testContactLevelVerificationCounts() {
        XCTAssertTrue(GroupParticipantVerification.isVerified(contact: contact(verified: true), sasBinding: nil, pinnedKeys: []))
        XCTAssertTrue(GroupParticipantVerification.isVerified(contact: contact(verifiedAtMs: 5), sasBinding: nil, pinnedKeys: []))
    }

    func testInPersonPairingCountsOnlyWhenTheServerConfirmedIt() {
        XCTAssertTrue(GroupParticipantVerification.isVerified(
            contact: contact(proximityAt: 10, proximityConfirmed: true), sasBinding: nil, pinnedKeys: []))
        XCTAssertFalse(GroupParticipantVerification.isVerified(
            contact: contact(proximityAt: 10, proximityConfirmed: false), sasBinding: nil, pinnedKeys: []),
            "a pairing the server could not confirm is 'saved', not 'verified'")
        XCTAssertFalse(GroupParticipantVerification.isVerified(
            contact: contact(proximityAt: 10, proximityConfirmed: nil), sasBinding: nil, pinnedKeys: []))
    }

    func testOnlyAnActivePresenceRecordCounts() {
        XCTAssertTrue(GroupParticipantVerification.isVerified(
            contact: contact(presence: presence(.active)), sasBinding: nil, pinnedKeys: []))
        XCTAssertFalse(GroupParticipantVerification.isVerified(
            contact: contact(presence: presence(.suspended)), sasBinding: nil, pinnedKeys: []))
        XCTAssertFalse(GroupParticipantVerification.isVerified(
            contact: contact(presence: presence(.revoked)), sasBinding: nil, pinnedKeys: []))
    }

    // MARK: - GroupVerificationState

    func testBannerAppearsWhenAtLeastOneParticipantIsUnverified() {
        let verified: Set<String> = ["a", "b"]
        let state = GroupVerificationState(
            participantIds: ["me", "a", "b", "c", "d"], selfId: "me", isVerified: { verified.contains($0) })
        XCTAssertTrue(state.showsBanner)
        XCTAssertEqual(state.unverifiedIds, ["c", "d"])
        XCTAssertEqual(state.count, 2)
        XCTAssertEqual(state.firstUnverifiedId, "c", "the banner action opens the first unverified participant")
        XCTAssertTrue(state.isUnverified("c"))
        XCTAssertFalse(state.isUnverified("a"))
        XCTAssertFalse(state.isUnverified("me"))
    }

    func testNoBannerWhenEveryoneIsVerifiedOrWhenAloneInTheCall() {
        let everyone = GroupVerificationState(participantIds: ["me", "a", "b"], selfId: "me", isVerified: { _ in true })
        XCTAssertFalse(everyone.showsBanner)
        XCTAssertNil(everyone.firstUnverifiedId)
        let alone = GroupVerificationState(participantIds: ["me"], selfId: "me", isVerified: { _ in false })
        XCTAssertFalse(alone.showsBanner, "the local participant is never listed as unverified")
        XCTAssertEqual(GroupVerificationState(), GroupVerificationState(unverifiedIds: []))
    }

    func testDuplicateAndEmptyIdsAreIgnoredAndThePredicateIsAskedOncePerParticipant() {
        var asked: [String] = []
        let state = GroupVerificationState(participantIds: ["me", "a", "a", "", "b"], selfId: "me", isVerified: { id in
            asked.append(id)
            return false
        })
        XCTAssertEqual(state.unverifiedIds, ["a", "b"])
        XCTAssertEqual(asked, ["a", "b"])
    }

    func testVerifyingAParticipantClearsTheirBadgeAndEventuallyTheBanner() {
        var verified: Set<String> = []
        func state() -> GroupVerificationState {
            GroupVerificationState(participantIds: ["me", "a", "b"], selfId: "me", isVerified: { verified.contains($0) })
        }
        XCTAssertEqual(state().count, 2)
        verified.insert("a")
        XCTAssertEqual(state().unverifiedIds, ["b"])
        XCTAssertEqual(state().firstUnverifiedId, "b")
        verified.insert("b")
        XCTAssertFalse(state().showsBanner)
    }
}

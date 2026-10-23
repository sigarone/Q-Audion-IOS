import XCTest
@testable import QAudionEngine

final class SiriCallResolutionTests: XCTestCase {

    private func contact(
        userId: String,
        displayName: String,
        phoneHash: String = "unused",
        isVerified: Bool = false,
        phoneNumber: String? = nil
    ) -> ContactsStore.StoredContact {
        ContactsStore.StoredContact(
            userId: userId,
            displayName: displayName,
            phoneHash: phoneHash,
            avatarUrl: nil,
            lastSeen: nil,
            isVerified: isVerified,
            phoneNumber: phoneNumber
        )
    }

    func test_resolve_matchesByExactE164Phone_evenWithDifferentFormatting() {
        let contacts = [
            contact(userId: "u1", displayName: "Alfredo Rossi", phoneNumber: "+39 02 1234 5678")
        ]
        let match = SiriCallResolution.resolve(
            handle: "02/1234.5678", displayName: "Alfredo Rossi", contacts: contacts)
        XCTAssertEqual(match, SiriCallResolution.Match(userId: "u1", displayName: "Alfredo Rossi"))
    }

    func test_resolve_fallsBackToDisplayNameWhenNoPhoneMatch() {
        let contacts = [
            contact(userId: "u1", displayName: "Alfredo Rossi")
        ]
        let match = SiriCallResolution.resolve(handle: nil, displayName: "alfredo rossi", contacts: contacts)
        XCTAssertEqual(match, SiriCallResolution.Match(userId: "u1", displayName: "Alfredo Rossi"))
    }

    func test_resolve_prefersVerifiedContactOnAmbiguousName() {
        let contacts = [
            contact(userId: "u1", displayName: "Alfredo Rossi", isVerified: false),
            contact(userId: "u2", displayName: "Alfredo Rossi", isVerified: true)
        ]
        let match = SiriCallResolution.resolve(handle: nil, displayName: "Alfredo Rossi", contacts: contacts)
        XCTAssertEqual(match?.userId, "u2")
    }

    func test_resolve_returnsNilWhenNothingMatches() {
        let contacts = [contact(userId: "u1", displayName: "Alfredo Rossi")]
        XCTAssertNil(SiriCallResolution.resolve(handle: "+390299999999", displayName: "Someone Else", contacts: contacts))
    }

    func test_resolve_returnsNilOnEmptyNameAndNoPhoneMatch() {
        XCTAssertNil(SiriCallResolution.resolve(handle: nil, displayName: "   ", contacts: []))
    }

    func test_resolve_phoneMatchTakesPriorityOverAWrongNameMatch() {
        // The phone number is authoritative — Siri's displayName can be a
        // stale/renamed system-contact label that no longer matches the
        // Q-Audion contact's own displayName.
        let contacts = [
            contact(userId: "u1", displayName: "Contatto salvato", phoneNumber: "+390212345678")
        ]
        let match = SiriCallResolution.resolve(handle: "+39 02 1234 5678", displayName: "Nome diverso", contacts: contacts)
        XCTAssertEqual(match?.userId, "u1")
    }

    // MARK: - the identifier this app gave the person (a donated interaction)

    func test_resolve_anAppIdentifierThatNamesAContactIsTheAnswerAndWinsOverPhoneAndName() {
        let contacts = [
            contact(userId: "u1", displayName: "Alfredo Rossi", phoneNumber: "+390212345678"),
            contact(userId: "u2", displayName: "Anna Verdi", phoneNumber: "+390298765432")
        ]
        let match = SiriCallResolution.resolve(
            appIdentifier: "u2", handle: "+390212345678", displayName: "Alfredo Rossi", contacts: contacts)
        XCTAssertEqual(match, SiriCallResolution.Match(userId: "u2", displayName: "Anna Verdi"))
    }

    func test_resolve_anAppIdentifierThatNamesNobodyFallsBackToPhoneAndName() {
        let contacts = [contact(userId: "u1", displayName: "Alfredo Rossi", phoneNumber: "+390212345678")]
        let match = SiriCallResolution.resolve(
            appIdentifier: "gone", handle: "+39 02 1234 5678", displayName: "Someone", contacts: contacts)
        XCTAssertEqual(match?.userId, "u1")
    }

    func test_resolve_aBlankAppIdentifierIsNoIdentifier() {
        let contacts = [contact(userId: "u1", displayName: "Alfredo Rossi")]
        XCTAssertEqual(
            SiriCallResolution.resolve(appIdentifier: "  ", handle: nil, displayName: "alfredo rossi", contacts: contacts)?.userId,
            "u1")
        XCTAssertEqual(
            SiriCallResolution.resolve(appIdentifier: nil, handle: nil, displayName: "alfredo rossi", contacts: contacts)?.userId,
            "u1")
    }

    // MARK: - the peer of a queued message

    func test_messageTarget_aConversationIdentifierThatNamesAContactIsTheAnswer() {
        let contacts = [contact(userId: "u1", displayName: "Alfredo Rossi")]
        let match = SiriCallResolution.resolveMessageTarget(
            conversationIdentifier: "u1", conversationPeerIds: [], appIdentifier: nil,
            handle: nil, displayName: "", contacts: contacts)
        XCTAssertEqual(match, SiriCallResolution.Match(userId: "u1", displayName: "Alfredo Rossi"))
    }

    func test_messageTarget_aConversationWithSomeoneWhoIsNotAContactIsStillAnAnswer() {
        let match = SiriCallResolution.resolveMessageTarget(
            conversationIdentifier: "stranger", conversationPeerIds: ["stranger", "other"], appIdentifier: nil,
            handle: nil, displayName: " Chi Lo Sa ", contacts: [])
        XCTAssertEqual(match, SiriCallResolution.Match(userId: "stranger", displayName: "Chi Lo Sa"))
    }

    func test_messageTarget_aConversationIdentifierThatNamesNobodyIsNotGuessedFromTheName() {
        // The name and the phone number below would both match u1; the explicit identifier is unknown, so the
        // message goes nowhere instead of to somebody else.
        let contacts = [contact(userId: "u1", displayName: "Alfredo Rossi", phoneNumber: "+390212345678")]
        let match = SiriCallResolution.resolveMessageTarget(
            conversationIdentifier: "unknown", conversationPeerIds: ["u9"], appIdentifier: "u1",
            handle: "+390212345678", displayName: "Alfredo Rossi", contacts: contacts)
        XCTAssertNil(match)
    }

    func test_messageTarget_withoutAConversationItIsMatchedLikeACallTarget() {
        let contacts = [contact(userId: "u1", displayName: "Alfredo Rossi", phoneNumber: "+390212345678")]
        XCTAssertEqual(
            SiriCallResolution.resolveMessageTarget(
                conversationIdentifier: nil, conversationPeerIds: [], appIdentifier: nil,
                handle: "+39 02 1234 5678", displayName: "x", contacts: contacts)?.userId,
            "u1")
        XCTAssertEqual(
            SiriCallResolution.resolveMessageTarget(
                conversationIdentifier: "   ", conversationPeerIds: [], appIdentifier: "u1",
                handle: nil, displayName: "", contacts: contacts)?.userId,
            "u1")
    }
}

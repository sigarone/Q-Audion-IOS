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
}

import XCTest
@testable import QAudionEngine

final class ContactDetailViewModelTests: XCTestCase {

    func test_mockIsDeterministic() {
        XCTAssertEqual(ContactDetailViewModel.mock, ContactDetailViewModel.mock)
    }

    func test_mockPhoneHashIs64Hex() {
        let h = ContactDetailViewModel.mock.phoneHash
        XCTAssertEqual(h.count, 64)
    }

    func test_mockFingerprintIs4Groups() {
        let parts = ContactDetailViewModel.mock.fingerprint.split(separator: ".")
        XCTAssertEqual(parts.count, 4)
        for p in parts {
            XCTAssertEqual(p.count, 4)
        }
    }

    func test_mockTrustLevelIsSasVerified() {
        XCTAssertEqual(ContactDetailViewModel.mock.trustLevel, .sasVerified)
    }

    func test_mockIsNotBlocked() {
        XCTAssertFalse(ContactDetailViewModel.mock.isBlocked)
    }
}

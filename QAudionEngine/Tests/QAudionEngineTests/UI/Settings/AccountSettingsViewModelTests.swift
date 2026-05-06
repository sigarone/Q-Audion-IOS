import XCTest
@testable import QAudionEngine

final class AccountSettingsViewModelTests: XCTestCase {

    func test_mockIsDeterministic() {
        XCTAssertEqual(AccountSettingsViewModel.mock, AccountSettingsViewModel.mock)
    }

    func test_mockPhoneHashIs64HexChars() {
        let h = AccountSettingsViewModel.mock.phoneHash
        XCTAssertEqual(h.count, 64)
        XCTAssertTrue(h.allSatisfy { $0.isHexDigit })
    }

    func test_mockHasNonEmptyUserId() {
        XCTAssertFalse(AccountSettingsViewModel.mock.userId.isEmpty)
    }
}

private extension Character {
    var isHexDigit: Bool {
        ("0"..."9").contains(self) || ("a"..."f").contains(self) || ("A"..."F").contains(self)
    }
}

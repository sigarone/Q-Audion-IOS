import XCTest
@testable import QAudionEngine

final class KeyManagementViewModelTests: XCTestCase {

    func test_mockIsDeterministic() {
        XCTAssertEqual(KeyManagementViewModel.mock, KeyManagementViewModel.mock)
    }

    func test_mockExposesIdentityFingerprint_in4HexGroups() {
        let mock = KeyManagementViewModel.mock
        // §5.1 fingerprint format: "xxxx.xxxx.xxxx.xxxx"
        let parts = mock.fingerprint.split(separator: ".")
        XCTAssertEqual(parts.count, 4)
        for part in parts {
            XCTAssertEqual(part.count, 4, "Each fingerprint group must be 4 hex chars")
            XCTAssertTrue(part.allSatisfy(\.isHexDigit), "Group '\(part)' is not all hex")
        }
    }

    func test_mockHasAtLeastOneLinkedDevice() {
        XCTAssertGreaterThanOrEqual(KeyManagementViewModel.mock.linkedDevices.count, 1)
    }
}

private extension Character {
    var isHexDigit: Bool { isHexDigit(self) }
    private func isHexDigit(_ c: Character) -> Bool {
        ("0"..."9").contains(c) || ("a"..."f").contains(c) || ("A"..."F").contains(c)
    }
}

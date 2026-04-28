import XCTest
@testable import QAudionEngine

final class PrivacySettingsViewModelTests: XCTestCase {

    func test_mockIsDeterministic() {
        XCTAssertEqual(PrivacySettingsViewModel.mock, PrivacySettingsViewModel.mock)
    }

    func test_mockDisappearingDurationIsPlausible() {
        let valid: [TimeInterval] = [0, 60, 3600, 86400, 604800]
        XCTAssertTrue(valid.contains(PrivacySettingsViewModel.mock.disappearingMessagesDuration))
    }

    func test_mockBlockedListIsArray() {
        XCTAssertNotNil(PrivacySettingsViewModel.mock.blockedUserIds as [String]?)
    }
}

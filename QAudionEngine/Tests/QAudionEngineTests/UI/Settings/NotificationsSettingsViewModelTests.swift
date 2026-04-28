import XCTest
@testable import QAudionEngine

final class NotificationsSettingsViewModelTests: XCTestCase {

    func test_mockIsDeterministic() {
        XCTAssertEqual(NotificationsSettingsViewModel.mock, NotificationsSettingsViewModel.mock)
    }

    func test_quietHourStartHourInRange() {
        let qh = NotificationsSettingsViewModel.mock.quietHours
        XCTAssertTrue((0...23).contains(qh.startHour), "startHour must be 0...23")
        XCTAssertTrue((0...23).contains(qh.endHour), "endHour must be 0...23")
    }

    func test_quietHourMinutesInRange() {
        let qh = NotificationsSettingsViewModel.mock.quietHours
        XCTAssertTrue((0...59).contains(qh.startMinute), "startMinute must be 0...59")
        XCTAssertTrue((0...59).contains(qh.endMinute), "endMinute must be 0...59")
    }

    func test_mutedContactsCountNonNegative() {
        XCTAssertGreaterThanOrEqual(NotificationsSettingsViewModel.mock.mutedContactsCount, 0)
    }
}

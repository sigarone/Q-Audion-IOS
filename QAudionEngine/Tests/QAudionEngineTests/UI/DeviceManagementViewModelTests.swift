import XCTest
@testable import QAudionEngine

final class DeviceManagementViewModelTests: XCTestCase {

    func test_mockIsDeterministic() {
        XCTAssertEqual(DeviceManagementViewModel.mock, DeviceManagementViewModel.mock)
    }

    func test_mockHasCurrentDeviceFirst() {
        let mock = DeviceManagementViewModel.mock
        XCTAssertTrue(mock.devices.first?.isCurrentDevice ?? false,
                      "Current device must be first in the list for UI clarity")
    }

    func test_mockOtherDevicesAreRevocable() {
        let mock = DeviceManagementViewModel.mock
        let nonCurrent = mock.devices.filter { !$0.isCurrentDevice }
        XCTAssertGreaterThanOrEqual(nonCurrent.count, 1)
        for d in nonCurrent {
            XCTAssertTrue(d.canRevoke, "Non-current devices must be revocable")
        }
    }

    func test_mockCurrentDeviceIsNotRevocable() {
        let mock = DeviceManagementViewModel.mock
        let current = mock.devices.first { $0.isCurrentDevice }
        XCTAssertNotNil(current)
        XCTAssertFalse(current!.canRevoke,
                       "User cannot revoke the device they are currently using — must do that elsewhere")
    }
}

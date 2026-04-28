import XCTest
@testable import QAudionEngine

final class TransportSettingsViewModelTests: XCTestCase {

    func test_mockIsDeterministic() {
        XCTAssertEqual(TransportSettingsViewModel.mock, TransportSettingsViewModel.mock)
    }

    func test_allModeCasesReachable() {
        XCTAssertEqual(TransportSettingsViewModel.Mode.allCases.count, 4)
    }

    func test_mockDefaultModeIsAuto() {
        XCTAssertEqual(TransportSettingsViewModel.mock.mode, .auto)
    }

    func test_mockConnectionMsNonNegative() {
        let m = TransportSettingsViewModel.mock
        XCTAssertGreaterThanOrEqual(m.lastConnectionMs, 0)
        XCTAssertGreaterThanOrEqual(m.lastTurnRoundTripMs, 0)
    }
}

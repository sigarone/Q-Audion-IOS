import XCTest
@testable import QAudionEngine

final class CallsSettingsViewModelTests: XCTestCase {

    func test_mockIsDeterministic() {
        XCTAssertEqual(CallsSettingsViewModel.mock, CallsSettingsViewModel.mock)
    }

    func test_mockCodecIsOpus() {
        XCTAssertEqual(CallsSettingsViewModel.mock.codecPreference, .opus)
    }

    func test_mockAudioProcessingFlagsAllEnabled() {
        let m = CallsSettingsViewModel.mock
        XCTAssertTrue(m.isAecEnabled, "AEC should be enabled by default")
        XCTAssertTrue(m.isNsEnabled, "NS should be enabled by default")
        XCTAssertTrue(m.isAgcEnabled, "AGC should be enabled by default")
    }

    func test_mockVoipBackgroundModeActive() {
        XCTAssertTrue(CallsSettingsViewModel.mock.isVoipBackgroundModeActive)
    }
}

import XCTest
@testable import QAudionEngine

final class AboutSettingsViewModelTests: XCTestCase {

    func test_mockIsDeterministic() {
        XCTAssertEqual(AboutSettingsViewModel.mock, AboutSettingsViewModel.mock)
    }

    func test_onnxruntimeVersionIsPinned() {
        // CLAUDE.md §4: must NOT be upgraded past 1.17.0 — it raises MinOS to iOS 18+.
        XCTAssertEqual(AboutSettingsViewModel.mock.onnxruntimeVersion, "1.17.0")
    }

    func test_iosDeploymentTarget() {
        XCTAssertEqual(AboutSettingsViewModel.mock.iosDeploymentTarget, "16.0")
    }

    func test_mlKem1024AlwaysEnabled() {
        XCTAssertTrue(AboutSettingsViewModel.mock.mlKem1024Enabled)
    }

    func test_gitCommitShortIsSevenChars() {
        XCTAssertEqual(AboutSettingsViewModel.mock.gitCommitShort.count, 7)
    }
}

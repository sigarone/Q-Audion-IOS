import XCTest
@testable import QAudionEngine

final class BackupSettingsViewModelTests: XCTestCase {

    func test_mockIsDeterministic() {
        XCTAssertEqual(BackupSettingsViewModel.mock, BackupSettingsViewModel.mock)
    }

    func test_cloudBackupDisabledByDefault() {
        // BLOCKED by Open Discrepancy §10: cross-platform backup format mismatch
        // (Desktop QABK+32B salt+scrypt N=2^15 vs Android QAUD+16B salt+scrypt N=2^17).
        // This flag must remain false until all platforms converge on a single layout.
        XCTAssertFalse(BackupSettingsViewModel.mock.cloudBackupEnabled)
    }

    func test_restoreNotInProgressByDefault() {
        XCTAssertFalse(BackupSettingsViewModel.mock.restoreInProgress)
    }

    func test_mockLastBackupSizeBytesPositive() {
        let size = BackupSettingsViewModel.mock.lastBackupSizeBytes
        XCTAssertNotNil(size)
        if let size { XCTAssertGreaterThan(size, 0) }
    }
}

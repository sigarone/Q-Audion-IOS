import XCTest
@testable import QAudionEngine

/// W-SCREENRECDETECT (2026-09-02) — pins `ScreenCaptureAlertPolicy`'s truth
/// table without UIKit/a simulator. See that type's header for the audit
/// reference and why the rule lives outside the NotificationCenter handler.
final class ScreenCaptureAlertPolicyTests: XCTestCase {

    func testLogsOnlyWhenProtectedAndCaptured() {
        XCTAssertTrue(ScreenCaptureAlertPolicy.shouldLog(protectionEnabled: true, isCaptured: true))
    }

    func testSilentWhenProtectionIsOff() {
        XCTAssertFalse(ScreenCaptureAlertPolicy.shouldLog(protectionEnabled: false, isCaptured: true))
    }

    func testSilentWhenNotCurrentlyCaptured() {
        XCTAssertFalse(ScreenCaptureAlertPolicy.shouldLog(protectionEnabled: true, isCaptured: false))
    }

    func testSilentWhenNeitherFlagIsSet() {
        XCTAssertFalse(ScreenCaptureAlertPolicy.shouldLog(protectionEnabled: false, isCaptured: false))
    }
}

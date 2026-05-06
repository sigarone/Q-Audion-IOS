import XCTest
@testable import QAudionEngine

final class ThreatReportViewModelTests: XCTestCase {

    func test_mockIsDeterministic() {
        XCTAssertEqual(ThreatReportViewModel.mock, ThreatReportViewModel.mock)
    }

    func test_mockIsHighSeverity() {
        XCTAssertEqual(ThreatReportViewModel.mock.severity, .high)
    }

    func test_mockIsDeepfakeDetected() {
        XCTAssertEqual(ThreatReportViewModel.mock.threatKind, .deepfakeDetected)
    }

    func test_mockHasSessionId() {
        XCTAssertNotNil(ThreatReportViewModel.mock.sessionId)
    }

    func test_threatKindRawValues_areSnakeCase() {
        // Match the wire format BCryptoSecurityApiImpl currently emits.
        XCTAssertEqual(ThreatReportViewModel.ThreatKind.deepfakeDetected.rawValue, "deepfake_detected")
        XCTAssertEqual(ThreatReportViewModel.ThreatKind.voiceMismatch.rawValue, "voice_mismatch")
        XCTAssertEqual(ThreatReportViewModel.ThreatKind.keyTampering.rawValue, "key_tampering")
        XCTAssertEqual(ThreatReportViewModel.ThreatKind.suspiciousNetwork.rawValue, "suspicious_network")
        XCTAssertEqual(ThreatReportViewModel.ThreatKind.panicWipeTriggered.rawValue, "panic_wipe_triggered")
        XCTAssertEqual(ThreatReportViewModel.ThreatKind.other.rawValue, "other")
    }

    func test_severityCaseIterableHas4Cases() {
        XCTAssertEqual(ThreatReportViewModel.Severity.allCases.count, 4)
    }
}

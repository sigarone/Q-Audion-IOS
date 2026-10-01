import XCTest
@testable import QAudionApp
import QAudionEngine

/// Post-v5: the five call close reasons (`CallCloseReason`) are an allow-list in the egress redactor and
/// have a label in the call history. `identity_key_mismatch` is 21 characters, above the 20-character
/// residual sweep of `LogRedactor.redactStructured`, so without the allow-list the telemetry
/// `end_reason` would ship as `***REDACTED***`.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing`
/// list of `.github/workflows/ios-app-tests.yml`.
final class CallCloseReasonRedactionTests: XCTestCase {

    func test_everyCloseReasonSurvivesTheEgressRedactor() {
        for reason in CallCloseReason.allCases {
            let token = reason.rawValue
            XCTAssertTrue(LogRedactor.redactStructured("end_reason=\(token)").contains(token), token)
            XCTAssertTrue(LogRedactor.redactStructured("call ended reason \(token) after 12 s").contains(token), token)
            XCTAssertTrue(LogRedactor.redactStructured("{\"end_reason\":\"\(token)\"}").contains(token), token)
        }
    }

    func test_aTokenGluedIntoALongerSecretRunIsStillRedacted() {
        let line = "blob AAAAbbbb1234+identity_key_mismatch+CCCCdddd5678 end"
        XCTAssertFalse(LogRedactor.redactStructured(line).contains("identity_key_mismatch"))
    }

    func test_otherLongSnakeCaseWordsAreStillRedactedByTheResidualSweep() {
        // Not an allow-listed token: the 20-character residual bar still applies to it.
        let line = "reason=some_other_long_reason_name_here"
        XCTAssertFalse(LogRedactor.redactStructured(line).contains("some_other_long_reason_name_here"))
    }

    func test_everyCloseReasonHasAHistoryLabelAndAnythingElseHasNone() {
        for reason in CallCloseReason.allCases {
            let label = CallCloseReasonLabel.text(for: reason.rawValue)
            XCTAssertNotNil(label, reason.rawValue)
            XCTAssertFalse(label?.isEmpty ?? true, reason.rawValue)
        }
        XCTAssertNil(CallCloseReasonLabel.text(for: nil))
        XCTAssertNil(CallCloseReasonLabel.text(for: "user_hangup"))
        XCTAssertNil(CallCloseReasonLabel.text(for: "ice-recovery-exhausted"))
        XCTAssertNil(CallCloseReasonLabel.text(for: "identity_key_mismatch "), "an exact token only")
    }
}

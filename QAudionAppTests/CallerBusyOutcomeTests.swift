import XCTest
@testable import QAudionApp
import QAudionEngine

/// W-CALLERBUSY (2026-10-03) — what the user sees and what leaves the phone when the callee was busy or
/// unreachable: the outgoing screen message, the call-history label, and the end reason in the telemetry.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing`
/// list of `.github/workflows/ios-app-tests.yml`.
final class CallerBusyOutcomeTests: XCTestCase {

    func test_everyOutcomeHasAMessageForTheOutgoingScreen() {
        for outcome in CallerTerminalOutcome.allCases {
            XCTAssertFalse(CallerOutcomeText.message(for: outcome).isEmpty, "\(outcome)")
        }
        XCTAssertNotEqual(
            CallerOutcomeText.message(for: .busy), CallerOutcomeText.message(for: .peerOffline),
            "the two outcomes must read differently")
    }

    func test_everyOutcomeHasAHistoryLabel() {
        for outcome in CallerTerminalOutcome.allCases {
            let label = CallCloseReasonLabel.text(for: outcome.closeToken)
            XCTAssertNotNil(label, "\(outcome)")
            XCTAssertFalse(label?.isEmpty ?? true, "\(outcome)")
        }
        XCTAssertNotEqual(CallCloseReasonLabel.text(for: "busy"), CallCloseReasonLabel.text(for: "peer_offline"))
    }

    func test_theHandshakeLabelsAreUnchanged() {
        for reason in CallCloseReason.allCases {
            XCTAssertNotNil(CallCloseReasonLabel.text(for: reason.rawValue), reason.rawValue)
        }
        XCTAssertNil(CallCloseReasonLabel.text(for: "Busy"), "exact, case-sensitive tokens")
        XCTAssertNil(CallCloseReasonLabel.text(for: "user_hangup"))
    }

    func test_theOutcomeTokensSurviveTheEgressRedactor() {
        for outcome in CallerTerminalOutcome.allCases {
            let token = outcome.closeToken
            XCTAssertTrue(LogRedactor.redactStructured("end_reason=\(token)").contains(token), token)
            XCTAssertTrue(LogRedactor.redactStructured("{\"end_reason\":\"\(token)\"}").contains(token), token)
        }
    }
}

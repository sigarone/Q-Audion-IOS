import XCTest
@testable import QAudionApp
import QAudionEngine

/// W-PAIRFB — proves the `pairing.proximity.*` telemetry attribute VALUES
/// this sweep adds (`ProximityPairingTelemetry.swift`) survive
/// `TelemetryService.emit`'s mandatory scrub untouched, so they actually
/// reach the server instead of silently coming back as `***REDACTED***`.
///
/// `TelemetryService.emit` runs every STRING attribute value through
/// `RuntimeLogSink.redactStructured` (a one-line forward to
/// `LogRedactor.redactStructured`, same fail-closed egress redactor the
/// text-log shipper uses) before a batch is sealed — see `TelemetryService.redactAttrs`. That redactor's
/// residual sweep treats ANY run of 20+ letters/digits/`+/=_-` with no
/// separator as an unproven secret and blanks it: a plain enum token that
/// happens to be long enough is not a privacy bug (nothing leaks) but IS a
/// telemetry bug (the one attribute meant to say why a pairing failed comes
/// back empty). This test exercises the REAL redactor, not just a length
/// check, against every value this feature can actually emit.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing`
/// list of `.github/workflows/ios-app-tests.yml`. The cases call `LogRedactor.redactStructured`
/// directly: `RuntimeLogSink` is `@MainActor` and only forwards to it.
@MainActor
final class ProximityPairingTelemetryRedactionTests: XCTestCase {

    /// Every `role` value `pairing.proximity.started` can carry.
    func test_roleValues_surviveTheRedactorUnchanged() {
        for role in [ProximityRole.displayer, .scanner] {
            assertSurvives(role.rawValue, label: "role")
        }
    }

    /// Every `stage` value `pairing.proximity.failed`/`cancelled` can carry.
    func test_stageValues_surviveTheRedactorUnchanged() {
        let stages: [ProximityPairingTelemetryEvent.Stage] = [
            .preparing, .scanning, .showingCode, .connecting, .exchanging, .confirming,
        ]
        for stage in stages {
            assertSurvives(stage.rawValue, label: "stage")
        }
    }

    /// Every `cause` value `pairing.proximity.failed` can carry — the one
    /// this sweep had to fix twice. The values are Android's, and several are
    /// over the 20-character residual-redaction floor, so they only survive
    /// because `LogRedactor` allow-lists them.
    func test_failureCauseValues_surviveTheRedactorUnchanged() {
        for cause in ProximityPairingTelemetryEvent.FailureCause.allCases {
            assertSurvives(cause.rawValue, label: "cause")
        }
    }

    /// Every `cause` word iOS sends is one of Android's
    /// (`ProximityPairingLogic.telemetryCause`), except the iOS-only ones listed
    /// here; changing one here without Android splits the server-side dashboards.
    func test_failureCauseValues_areAndroidWordsOrIosOnly() {
        let android: Set<String> = [
            "bluetooth_unavailable", "identity_unavailable", "invalid_qr", "expired_qr", "timeout",
            "transport_failed", "security_check_failed", "self_pairing", "session_busy", "peer_rejected",
            "peer_security_check_failed", "peer_aborted", "cancelled", "crypto_failure", "qr_unavailable",
        ]
        let iosOnly: Set<String> = ["screen_captured", "other"]
        let ours: Set<String> = Set(ProximityPairingTelemetryEvent.FailureCause.allCases.map { $0.rawValue })
        XCTAssertEqual(ours, android.union(iosOnly))
    }

    /// Every `reason` value a rejected scan can carry.
    func test_scanRejectionValues_surviveTheRedactorUnchanged() {
        for reason in ProximityQrRejection.allCases {
            assertSurvives(reason.rawValue, label: "reason")
        }
    }

    /// The log lines a rejected scan writes (`ProximityScanReport`): `reason=not_pair_prefix` and
    /// `reason=non_canonical` are one run of 20+ characters once the `=` is counted.
    func test_scanLogLines_surviveTheRedactorUnchanged() {
        var lines: [String] = ["scan outcome=not_pair len=129"]
        for reason in ProximityQrRejection.allCases {
            lines.append("scan outcome=invalid reason=\(reason.rawValue) len=129")
        }
        for line in lines {
            assertSurvives(line, label: "log line")
        }
    }

    /// Every `server_check` value `pairing.proximity.completed` can carry.
    func test_serverCheckOutcomeValues_surviveTheRedactorUnchanged() {
        for outcome in [ProximityServerCheckOutcome.confirmed, .unavailable, .mismatch] {
            assertSurvives(outcome.rawValue, label: "server_check")
        }
    }

    /// Every `outcome` value `pairing.proximity.completed` can carry (the
    /// one attribute this app layer adds that the engine module doesn't
    /// know about — see `ContactsListContainer.ProximityOutcome.Kind`).
    func test_completionOutcomeValues_surviveTheRedactorUnchanged() {
        let kinds: [ContactsListContainer.ProximityOutcome.Kind] = [
            .newContactVerified, .existingContact, .savedUnverified, .notAdded,
        ]
        for kind in kinds {
            assertSurvives(kind.rawValue, label: "outcome")
        }
    }

    private func assertSurvives(_ value: String, label: String, file: StaticString = #filePath, line: UInt = #line) {
        let redacted = LogRedactor.redactStructured(value)
        XCTAssertEqual(redacted, value,
                       "\(label) value '\(value)' did not survive LogRedactor.redactStructured unchanged (got '\(redacted)') — it will not reach the server as telemetry",
                       file: file, line: line)
    }
}

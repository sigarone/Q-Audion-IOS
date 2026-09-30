import XCTest
@testable import QAudionApp
import QAudionEngine

/// W-PAIRFB — proves the `pairing.proximity.*` telemetry attribute VALUES
/// this sweep adds (`ProximityPairingTelemetry.swift`) survive
/// `TelemetryService.emit`'s mandatory scrub untouched, so they actually
/// reach the server instead of silently coming back as `***REDACTED***`.
///
/// `TelemetryService.emit` runs every STRING attribute value through
/// `RuntimeLogSink.redactStructured` (== `LogRedactor.redactStructured`,
/// same fail-closed egress redactor the text-log shipper uses) before a
/// batch is sealed — see `TelemetryService.redactAttrs`. That redactor's
/// residual sweep treats ANY run of 20+ letters/digits/`+/=_-` with no
/// separator as an unproven secret and blanks it: a plain enum token that
/// happens to be long enough is not a privacy bug (nothing leaks) but IS a
/// telemetry bug (the one attribute meant to say why a pairing failed comes
/// back empty). This test exercises the REAL redactor, not just a length
/// check, against every value this feature can actually emit.
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
            .preparing, .showingCode, .connecting, .exchanging, .confirming,
        ]
        for stage in stages {
            assertSurvives(stage.rawValue, label: "stage")
        }
    }

    /// Every `cause` value `pairing.proximity.failed` can carry — the one
    /// this sweep had to fix twice (`bluetoothUnavailable`/
    /// `authenticationFailed` were exactly 20 chars, the redaction floor).
    func test_failureCauseValues_surviveTheRedactorUnchanged() {
        let causes: [ProximityPairingTelemetryEvent.FailureCause] = [
            .bluetoothUnavailable, .identityUnavailable, .invalidQrCode, .expiredQrCode,
            .timeout, .transportFailed, .protocolViolation, .authenticationFailed,
            .identityRejected, .sessionBusy, .peerAborted, .userRejected,
            .cryptoFailure, .screenCaptured, .qrRenderFailed, .other,
        ]
        for cause in causes {
            XCTAssertLessThan(cause.rawValue.count, 20,
                              "'\(cause.rawValue)' is at/over the residual-redaction floor — see this file's header comment")
            assertSurvives(cause.rawValue, label: "cause")
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
        let redacted = RuntimeLogSink.redactStructured(value)
        XCTAssertEqual(redacted, value,
                       "\(label) value '\(value)' did not survive LogRedactor.redactStructured unchanged (got '\(redacted)') — it will not reach the server as telemetry",
                       file: file, line: line)
    }
}

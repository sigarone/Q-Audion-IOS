import XCTest
import UIKit
import QAudionEngine
@testable import QAudionApp

/// W-RETRYAFTER (2026-10-03) review fixes -- the bug-report retry queue.
///
/// A report that fails for a reason that is not its fault (429, 5xx, no network) now stays in
/// `BugReporter`'s in-memory queue and is retried 30-300+ s later. Two things must hold across
/// that gap, and these tests pin them without a network (`attemptOverride` stands in for the
/// upload; `Retry-After: 1` keeps the pause to about a second):
///
///   1. The call id and the diagnostic snapshot belong to the moment the report was queued, not
///      to the moment of the retry (the user may be in another call by then).
///   2. An AUTOMATIC report is gated on the diagnostics opt-in, so the opt-in is re-read before
///      every attempt; switching it OFF while a report waits drops the report. Manual and abuse
///      reports are explicit user actions and stay queued.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the
/// `-only-testing` list of `.github/workflows/ios-app-tests.yml`.
@MainActor
final class BugReporterRetryQueueTests: XCTestCase {

    private var savedConsent: Any?

    override func setUp() {
        super.setUp()
        savedConsent = UserDefaults.standard.object(forKey: TelemetryService.consentKey)
    }

    override func tearDown() {
        if let saved = savedConsent {
            UserDefaults.standard.set(saved, forKey: TelemetryService.consentKey)
        } else {
            UserDefaults.standard.removeObject(forKey: TelemetryService.consentKey)
        }
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeReport(trigger: String) -> BugReporter.PendingReport {
        return BugReporter.PendingReport(screenshot: nil, logEntries: [], trigger: trigger, capturedAt: Date())
    }

    /// Runs `uploadReport` (which returns once the queue is empty) and fails, instead of
    /// hanging, if it does not finish in time.
    private func drain(_ reporter: BugReporter,
                       report: BugReporter.PendingReport,
                       timeout: TimeInterval = 15,
                       file: StaticString = #filePath,
                       line: UInt = #line) async {
        let finished = expectation(description: "queue drained")
        let task = Task { @MainActor in
            await reporter.uploadReport(report: report, note: "n")
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: timeout)
        if reporter.queuedReportsForTesting.isEmpty == false {
            task.cancel()
            XCTFail("the queue did not drain in \(timeout) s", file: file, line: line)
        }
    }

    // MARK: - The report keeps the call and state of the moment it was queued

    func test_retryCarriesTheCallIdAndSnapshotFromQueueTime() async {
        let reporter = BugReporter(forTesting: ())
        var liveCallId = "call-A"
        var liveSnapshot = "state-A"
        reporter.configure(getToken: { "token" },
                           getServerUrl: { "https://example.invalid" },
                           getActiveCallId: { liveCallId },
                           getDiagSnapshot: { liveSnapshot })

        var seen: [(callId: String, snapshot: String)] = []
        reporter.attemptOverride = { queued in
            seen.append((queued.callId, queued.diagSnapshot))
            if seen.count == 1 {
                // The user starts another call while this report waits for its retry.
                liveCallId = "call-B"
                liveSnapshot = "state-B"
                return .retry(status: 429, retryAfter: "1")
            }
            return .done
        }

        await drain(reporter, report: makeReport(trigger: "manual"))

        XCTAssertEqual(seen.count, 2, "first attempt kept the report, second one sent it")
        XCTAssertEqual(seen.first?.callId, "call-A")
        XCTAssertEqual(seen.last?.callId, "call-A", "the retry must not pick up the later call")
        XCTAssertEqual(seen.last?.snapshot, "state-A", "nor the later app state")
        XCTAssertTrue(reporter.queuedReportsForTesting.isEmpty)
    }

    func test_queuedEntryHoldsTheValuesFixedAtQueueTime() async {
        let reporter = BugReporter(forTesting: ())
        var liveCallId = "call-A"
        reporter.configure(getToken: { "token" },
                           getServerUrl: { "https://example.invalid" },
                           getActiveCallId: { liveCallId },
                           getDiagSnapshot: { "state-A" })

        // A long pause keeps the report in the queue so the entry can be looked at.
        let firstAttempt = expectation(description: "first attempt done")
        reporter.attemptOverride = { _ in
            firstAttempt.fulfill()
            return .retry(status: 429, retryAfter: "60")
        }
        let task = Task { @MainActor in
            await reporter.uploadReport(report: self.makeReport(trigger: "manual"), note: "n")
        }
        await fulfillment(of: [firstAttempt], timeout: 10)
        liveCallId = "call-B"

        let queued = reporter.queuedReportsForTesting
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.callId, "call-A")
        XCTAssertEqual(queued.first?.diagSnapshot, "state-A")

        task.cancel()
        await task.value
    }

    // MARK: - Consent is re-read for automatic reports

    func test_autoReportIsDroppedWhenTheOptInIsSwitchedOffWhileItWaits() async {
        UserDefaults.standard.set(true, forKey: TelemetryService.consentKey)
        let reporter = BugReporter(forTesting: ())
        var attempts = 0
        reporter.attemptOverride = { _ in
            attempts += 1
            // The user opts out right after the first (failed) attempt.
            UserDefaults.standard.set(false, forKey: TelemetryService.consentKey)
            return .retry(status: 429, retryAfter: "1")
        }

        await drain(reporter, report: makeReport(trigger: "auto"))

        XCTAssertEqual(attempts, 1, "the retry of an automatic report must not happen after the opt-out")
        XCTAssertTrue(reporter.queuedReportsForTesting.isEmpty, "and the report must not stay queued")
    }

    func test_manualReportIsRetriedEvenWithTheOptInOff() async {
        UserDefaults.standard.set(false, forKey: TelemetryService.consentKey)
        let reporter = BugReporter(forTesting: ())
        var attempts = 0
        reporter.attemptOverride = { _ in
            attempts += 1
            return attempts == 1 ? .retry(status: 503, retryAfter: "1") : .done
        }

        await drain(reporter, report: makeReport(trigger: "manual"))

        XCTAssertEqual(attempts, 2, "the user pressed Invia report: that is not diagnostics egress")
        XCTAssertTrue(reporter.queuedReportsForTesting.isEmpty)
    }

    func test_dropQueuedAutoReportsKeepsManualAndAbuseReports() async {
        UserDefaults.standard.set(true, forKey: TelemetryService.consentKey)
        let reporter = BugReporter(forTesting: ())

        // The first report is attempted, fails and waits (long pause); the others queue behind it.
        let firstAttempt = expectation(description: "first attempt done")
        reporter.attemptOverride = { _ in
            firstAttempt.fulfill()
            return .retry(status: 429, retryAfter: "60")
        }
        let task = Task { @MainActor in
            await reporter.uploadReport(report: self.makeReport(trigger: "manual"), note: "m")
        }
        await fulfillment(of: [firstAttempt], timeout: 10)
        // While a drain is running these return at once (they are only queued).
        await reporter.uploadReport(report: makeReport(trigger: "auto"), note: "a")
        await reporter.uploadReport(report: makeReport(trigger: "abuse"), note: "x")
        XCTAssertEqual(reporter.queuedReportsForTesting.map { $0.trigger }, ["manual", "auto", "abuse"])

        UserDefaults.standard.set(false, forKey: TelemetryService.consentKey)
        reporter.dropQueuedAutoReports()

        XCTAssertEqual(reporter.queuedReportsForTesting.map { $0.trigger }, ["manual", "abuse"])

        task.cancel()
        await task.value
    }

    func test_consentRuleOnlyGatesAutomaticReports() {
        for diagnosticsEnabled in [true, false] {
            for trigger in ["manual", "abuse"] {
                XCTAssertFalse(BugReporter.isConsentWithdrawn(for: makeReport(trigger: trigger),
                                                              diagnosticsEnabled: diagnosticsEnabled),
                               "\(trigger) is never gated (opt-in \(diagnosticsEnabled))")
            }
        }
        XCTAssertFalse(BugReporter.isConsentWithdrawn(for: makeReport(trigger: "auto"), diagnosticsEnabled: true))
        XCTAssertTrue(BugReporter.isConsentWithdrawn(for: makeReport(trigger: "auto"), diagnosticsEnabled: false))
    }
}

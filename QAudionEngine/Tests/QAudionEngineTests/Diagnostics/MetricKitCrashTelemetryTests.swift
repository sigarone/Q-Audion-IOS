import XCTest
import Foundation
@testable import QAudionEngine

/// W-MKCRASHTELEMETRY (this task).
final class MetricKitCrashTelemetryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MetricKitCrashTelemetry.resetReportedForTesting()
    }

    override func tearDown() {
        MetricKitCrashTelemetry.resetReportedForTesting()
        super.tearDown()
    }

    private func makeCrashInput(
        windowBeginMs: Int64 = 1000, windowEndMs: Int64 = 2000,
        appBuild: String = "1.0.1180", osVersion: String = "17.5",
        signal: String = "11", exceptionType: String = "EXC_BAD_ACCESS",
        exceptionCode: String = "1", terminationReason: String = "?",
        frames: [String] = ["QAudionApp + 100", "QAudionApp + 200"]
    ) -> MetricKitCrashTelemetry.CrashInput {
        MetricKitCrashTelemetry.CrashInput(
            windowBeginMs: windowBeginMs, windowEndMs: windowEndMs, appBuild: appBuild,
            osVersion: osVersion, signal: signal, exceptionType: exceptionType,
            exceptionCode: exceptionCode, terminationReason: terminationReason, frames: frames)
    }

    // MARK: - Crash attributes

    func test_crashAttributes_basicFields() {
        let attrs = MetricKitCrashTelemetry.attributes(for: makeCrashInput())
        XCTAssertEqual(attrs["source"] as? String, "metrickit")
        XCTAssertEqual(attrs["crash_kind"] as? String, "metrickit_crash")
        XCTAssertEqual(attrs["signal"] as? String, "11")
        XCTAssertEqual(attrs["exception_type"] as? String, "EXC_BAD_ACCESS")
        XCTAssertEqual(attrs["exception_code"] as? String, "1")
        XCTAssertEqual(attrs["frame_count"] as? Int, 2)
        XCTAssertEqual(attrs["frames"] as? [String], ["QAudionApp + 100", "QAudionApp + 200"])
        XCTAssertEqual(attrs["crash_app_ver"] as? String, "1.0.1180")
        XCTAssertEqual(attrs["os_version"] as? String, "17.5")
        XCTAssertEqual(attrs["crash_ts_ms"] as? Int64, 2000)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(attrs))
    }

    func test_crashAttributes_capsFramesTo15() {
        let frames = (0..<50).map { "Bin\($0) + \($0 * 10)" }
        let attrs = MetricKitCrashTelemetry.attributes(for: makeCrashInput(frames: frames))
        XCTAssertEqual((attrs["frames"] as? [String])?.count, MetricKitCrashTelemetry.maxFrames)
        XCTAssertEqual(attrs["frame_count"] as? Int, 50)
    }

    // MARK: - Hang attributes

    func test_hangAttributes_basicFields() {
        let input = MetricKitCrashTelemetry.HangInput(
            windowBeginMs: 1000, windowEndMs: 5000, appBuild: "1.0.1180", osVersion: "17.5",
            hangDurationMs: 3500, frames: ["QAudionApp + 42"])
        let attrs = MetricKitCrashTelemetry.attributes(for: input)
        XCTAssertEqual(attrs["source"] as? String, "metrickit")
        XCTAssertEqual(attrs["crash_kind"] as? String, "metrickit_hang")
        XCTAssertEqual(attrs["hang_duration_ms"] as? Int64, 3500)
        XCTAssertEqual(attrs["frames"] as? [String], ["QAudionApp + 42"])
        XCTAssertEqual(attrs["crash_app_ver"] as? String, "1.0.1180")
        XCTAssertEqual(attrs["crash_ts_ms"] as? Int64, 5000)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(attrs))
    }

    // MARK: - Identifiers

    func test_crashIdentifier_isStableForSameInput() {
        let a = MetricKitCrashTelemetry.identifier(for: makeCrashInput())
        let b = MetricKitCrashTelemetry.identifier(for: makeCrashInput())
        XCTAssertEqual(a, b)
    }

    func test_crashIdentifier_differsWhenAnyFieldDiffers() {
        let base = MetricKitCrashTelemetry.identifier(for: makeCrashInput())
        XCTAssertNotEqual(base, MetricKitCrashTelemetry.identifier(for: makeCrashInput(windowBeginMs: 999)))
        XCTAssertNotEqual(base, MetricKitCrashTelemetry.identifier(for: makeCrashInput(signal: "6")))
        XCTAssertNotEqual(base, MetricKitCrashTelemetry.identifier(for: makeCrashInput(appBuild: "1.0.1181")))
    }

    func test_hangIdentifier_usesFirstFrame() {
        let a = MetricKitCrashTelemetry.HangInput(windowBeginMs: 1, windowEndMs: 2, appBuild: "1.0",
                                                   osVersion: "17", hangDurationMs: 100, frames: ["X + 1"])
        let b = MetricKitCrashTelemetry.HangInput(windowBeginMs: 1, windowEndMs: 2, appBuild: "1.0",
                                                   osVersion: "17", hangDurationMs: 100, frames: ["Y + 1"])
        XCTAssertNotEqual(MetricKitCrashTelemetry.identifier(for: a), MetricKitCrashTelemetry.identifier(for: b))
    }

    // MARK: - Dedup: pure core

    func test_shouldReport_newId_reportsAndAppends() {
        let (report, updated) = MetricKitCrashTelemetry.shouldReport("id1", existing: ["id0"])
        XCTAssertTrue(report)
        XCTAssertEqual(updated, ["id0", "id1"])
    }

    func test_shouldReport_existingId_doesNotReportOrChangeList() {
        let (report, updated) = MetricKitCrashTelemetry.shouldReport("id0", existing: ["id0", "id1"])
        XCTAssertFalse(report)
        XCTAssertEqual(updated, ["id0", "id1"])
    }

    func test_shouldReport_trimsToMaxReportedIdentifiers() {
        let existing = (0..<MetricKitCrashTelemetry.maxReportedIdentifiers).map { "id\($0)" }
        let (report, updated) = MetricKitCrashTelemetry.shouldReport("new", existing: existing)
        XCTAssertTrue(report)
        XCTAssertEqual(updated.count, MetricKitCrashTelemetry.maxReportedIdentifiers)
        XCTAssertEqual(updated.last, "new")
        XCTAssertFalse(updated.contains("id0"))
    }

    // MARK: - Dedup: persisted wrapper

    func test_markReportedIfNew_firstCallTrue_secondCallFalse() {
        XCTAssertTrue(MetricKitCrashTelemetry.markReportedIfNew("dup-test-id"))
        XCTAssertFalse(MetricKitCrashTelemetry.markReportedIfNew("dup-test-id"))
    }

    func test_markReportedIfNew_differentIds_bothTrue() {
        XCTAssertTrue(MetricKitCrashTelemetry.markReportedIfNew("id-a"))
        XCTAssertTrue(MetricKitCrashTelemetry.markReportedIfNew("id-b"))
    }
}

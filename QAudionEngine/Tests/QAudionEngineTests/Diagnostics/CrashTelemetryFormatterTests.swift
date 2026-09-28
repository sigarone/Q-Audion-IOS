import XCTest
import Foundation
@testable import QAudionEngine

/// W-CRASHTELEMETRY (this task).
final class CrashTelemetryFormatterTests: XCTestCase {

    private func makeReport(
        crashKind: String = "signal",
        name: String = "SIGSEGV",
        reason: String = "boom",
        thread: String = "main",
        stackLines: [String] = ["frame0", "frame1"],
        callContext: String? = "in_call=1 native=1 phase=active",
        breadcrumbLines: [String] = ["info call: one", "warn call: two"],
        appVer: String = "1.0.1180",
        crashTsMs: Int64 = 1_758_000_000_000
    ) -> CrashTelemetryFormatter.Report {
        CrashTelemetryFormatter.Report(
            crashKind: crashKind, name: name, reason: reason, thread: thread,
            stackLines: stackLines, callContext: callContext, breadcrumbLines: breadcrumbLines,
            appVer: appVer, crashTsMs: crashTsMs)
    }

    func test_attributes_basicFields() {
        let attrs = CrashTelemetryFormatter.attributes(for: makeReport())
        XCTAssertEqual(attrs["source"] as? String, "in_process")
        XCTAssertEqual(attrs["crash_kind"] as? String, "signal")
        XCTAssertEqual(attrs["name"] as? String, "SIGSEGV")
        XCTAssertEqual(attrs["reason"] as? String, "boom")
        XCTAssertEqual(attrs["thread"] as? String, "main")
        XCTAssertEqual(attrs["frame_count"] as? Int, 2)
        XCTAssertEqual(attrs["frames"] as? [String], ["frame0", "frame1"])
        XCTAssertEqual(attrs["crash_app_ver"] as? String, "1.0.1180")
        XCTAssertEqual(attrs["crash_ts_ms"] as? Int64, 1_758_000_000_000)
        XCTAssertEqual(attrs["call_context"] as? String, "in_call=1 native=1 phase=active")
        XCTAssertEqual(attrs["breadcrumbs"] as? [String], ["info call: one", "warn call: two"])
    }

    func test_attributes_nilCallContext_omitsKey() {
        let attrs = CrashTelemetryFormatter.attributes(for: makeReport(callContext: nil))
        XCTAssertNil(attrs["call_context"])
    }

    func test_attributes_emptyBreadcrumbs_omitsKey() {
        let attrs = CrashTelemetryFormatter.attributes(for: makeReport(breadcrumbLines: []))
        XCTAssertNil(attrs["breadcrumbs"])
    }

    func test_attributes_capsFramesTo15_keepsFrameCountAsTotal() {
        let stack = (0..<50).map { "frame\($0)" }
        let attrs = CrashTelemetryFormatter.attributes(for: makeReport(stackLines: stack))
        XCTAssertEqual((attrs["frames"] as? [String])?.count, CrashTelemetryFormatter.maxFrames)
        XCTAssertEqual(attrs["frame_count"] as? Int, 50)
        XCTAssertEqual((attrs["frames"] as? [String])?.first, "frame0")
    }

    func test_attributes_capsBreadcrumbsTo20_keepsMostRecent() {
        let crumbs = (0..<50).map { "crumb\($0)" }
        let attrs = CrashTelemetryFormatter.attributes(for: makeReport(breadcrumbLines: crumbs))
        let kept = attrs["breadcrumbs"] as? [String]
        XCTAssertEqual(kept?.count, CrashTelemetryFormatter.maxBreadcrumbs)
        // Most RECENT breadcrumbs survive (tail of the oldest-first ring).
        XCTAssertEqual(kept?.last, "crumb49")
    }

    func test_attributes_longReasonAndName_areClipped() {
        let longReason = String(repeating: "r", count: 5000)
        let longName = String(repeating: "n", count: 5000)
        let attrs = CrashTelemetryFormatter.attributes(for: makeReport(name: longName, reason: longReason))
        XCTAssertLessThanOrEqual((attrs["name"] as? String)?.utf8.count ?? .max, 120)
        XCTAssertLessThanOrEqual((attrs["reason"] as? String)?.utf8.count ?? .max, 300)
    }

    func test_attributes_overallSizeStaysUnderBudget_evenWithHugeInputs() {
        let hugeStack = (0..<2000).map { "frame\($0) " + String(repeating: "x", count: 300) }
        let hugeCrumbs = (0..<2000).map { "crumb\($0) " + String(repeating: "y", count: 300) }
        let report = makeReport(stackLines: hugeStack, breadcrumbLines: hugeCrumbs)
        let attrs = CrashTelemetryFormatter.attributes(for: report)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(attrs))
        let size = try! JSONSerialization.data(withJSONObject: attrs).count
        XCTAssertLessThanOrEqual(size, CrashTelemetryFormatter.maxTotalAttrsBytes)
    }

    func test_attributes_isJSONSerializable() {
        let attrs = CrashTelemetryFormatter.attributes(for: makeReport())
        XCTAssertTrue(JSONSerialization.isValidJSONObject(attrs))
    }
}

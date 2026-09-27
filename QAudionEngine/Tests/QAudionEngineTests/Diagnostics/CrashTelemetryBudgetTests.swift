import XCTest
import Foundation
@testable import QAudionEngine

/// W-CRASHTELEMETRY (this task).
final class CrashTelemetryBudgetTests: XCTestCase {

    // MARK: - clip

    func test_clip_underBudget_returnsSameString() {
        XCTAssertEqual(CrashTelemetryBudget.clip("short", maxBytes: 100), "short")
    }

    func test_clip_overBudget_truncates() {
        let s = String(repeating: "a", count: 50)
        let clipped = CrashTelemetryBudget.clip(s, maxBytes: 10)
        XCTAssertEqual(clipped.utf8.count, 10)
    }

    func test_clip_exactBudget_unchanged() {
        let s = String(repeating: "a", count: 10)
        XCTAssertEqual(CrashTelemetryBudget.clip(s, maxBytes: 10), s)
    }

    // MARK: - cap

    func test_cap_headDefault_keepsFirstN() {
        let lines = ["a", "b", "c", "d", "e"]
        let capped = CrashTelemetryBudget.cap(lines, maxCount: 3, maxLineBytes: 100)
        XCTAssertEqual(capped, ["a", "b", "c"])
    }

    func test_cap_keepTail_keepsLastN() {
        let lines = ["a", "b", "c", "d", "e"]
        let capped = CrashTelemetryBudget.cap(lines, maxCount: 3, maxLineBytes: 100, keepTail: true)
        XCTAssertEqual(capped, ["c", "d", "e"])
    }

    func test_cap_fewerThanMax_returnsAll() {
        let lines = ["a", "b"]
        XCTAssertEqual(CrashTelemetryBudget.cap(lines, maxCount: 15, maxLineBytes: 100), ["a", "b"])
    }

    func test_cap_zeroMaxCount_returnsEmpty() {
        XCTAssertEqual(CrashTelemetryBudget.cap(["a", "b"], maxCount: 0, maxLineBytes: 100), [])
    }

    func test_cap_clipsEachLine() {
        let lines = [String(repeating: "x", count: 20), "short"]
        let capped = CrashTelemetryBudget.cap(lines, maxCount: 2, maxLineBytes: 5)
        XCTAssertEqual(capped, ["xxxxx", "short"])
    }

    // MARK: - enforceTotalBudget

    func test_enforceTotalBudget_underCap_unchanged() {
        let attrs: [String: Any] = ["a": "small", "frames": ["f1", "f2"]]
        let out = CrashTelemetryBudget.enforceTotalBudget(attrs, maxTotalBytes: 4096)
        XCTAssertEqual(out["a"] as? String, "small")
        XCTAssertEqual(out["frames"] as? [String], ["f1", "f2"])
    }

    func test_enforceTotalBudget_dropsBreadcrumbsFirst() {
        let bigCrumbs = (0..<50).map { "crumb-\($0)-" + String(repeating: "x", count: 200) }
        var attrs: [String: Any] = ["breadcrumbs": bigCrumbs]
        attrs["frames"] = ["f1", "f2", "f3"]
        let out = CrashTelemetryBudget.enforceTotalBudget(attrs, maxTotalBytes: 512)
        // Frames must survive; breadcrumbs must be shrunk or gone.
        XCTAssertEqual(out["frames"] as? [String], ["f1", "f2", "f3"])
        if let crumbs = out["breadcrumbs"] as? [String] {
            XCTAssertLessThan(crumbs.count, bigCrumbs.count)
        }
        let size = try? JSONSerialization.data(withJSONObject: out).count
        XCTAssertNotNil(size)
        XCTAssertLessThanOrEqual(size ?? .max, 512)
    }

    func test_enforceTotalBudget_thenTrimsFrames_whenStillOverBudget() {
        let bigFrames = (0..<40).map { "frame-\($0)-" + String(repeating: "y", count: 200) }
        let attrs: [String: Any] = ["frames": bigFrames]
        let out = CrashTelemetryBudget.enforceTotalBudget(attrs, maxTotalBytes: 512)
        let frames = out["frames"] as? [String] ?? []
        XCTAssertLessThan(frames.count, bigFrames.count)
        let size = try? JSONSerialization.data(withJSONObject: out).count
        XCTAssertLessThanOrEqual(size ?? .max, 512)
    }

    func test_enforceTotalBudget_neverDropsLastFrame() {
        // Even an absurdly tight budget must leave at least one frame rather
        // than removing the key entirely (some record beats none).
        let bigFrames = [String(repeating: "z", count: 5000)]
        let attrs: [String: Any] = ["frames": bigFrames]
        let out = CrashTelemetryBudget.enforceTotalBudget(attrs, maxTotalBytes: 10)
        XCTAssertEqual((out["frames"] as? [String])?.count, 1)
    }
}

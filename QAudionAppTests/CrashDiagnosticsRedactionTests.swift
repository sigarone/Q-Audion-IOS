import XCTest
@testable import QAudionApp
import QAudionEngine

/// The crash diagnostics lines (MetricKit thread stacks, the raw signal record turned into report text) are only
/// worth anything if the on-device redactors leave them alone: the stdout tee runs `LogRedactor.redact`, the live-log
/// shipper `LogRedactor.redactStructured`. Binary UUIDs are written with dots between their groups for that reason.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-app-tests.yml`.
final class CrashDiagnosticsRedactionTests: XCTestCase {

    private func assertSurvives(_ lines: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(lines.isEmpty, file: file, line: line)
        for l in lines {
            XCTAssertEqual(LogRedactor.redact(l), l, "tee redactor changed: " + l, file: file, line: line)
            XCTAssertEqual(LogRedactor.redactStructured(l), l, "egress redactor changed: " + l, file: file, line: line)
        }
    }

    func test_metricKitThreadLinesSurviveBothRedactors() {
        func stack(_ attributed: Bool, _ n: Int) -> [String: Any] {
            var node: [String: Any]?
            for i in (0..<n).reversed() {
                var f: [String: Any] = [
                    "binaryName": i % 2 == 0 ? "QAudionApp" : "libswift_Concurrency.dylib",
                    "binaryUUID": i % 2 == 0 ? "0123ABCD-4567-89AB-CDEF-0123456789AB" : "FEDCBA98-7654-3210-FEDC-BA9876543210",
                    "offsetIntoBinaryTextSegment": 1_234_567 + i,
                ]
                if let child = node { f["subFrames"] = [child] }
                node = f
            }
            return ["threadAttributed": attributed, "callStackRootFrames": node.map { [$0] } ?? []]
        }
        let root: [String: Any] = ["callStacks": [stack(false, 30), stack(true, 30), stack(false, 5)]]
        let lines = MetricKitCrashStackFormatter.lines(from: root)
        XCTAssertGreaterThan(lines.count, 30)
        assertSurvives(lines)
    }

    func test_rawSignalRecordReportSurvivesBothRedactors() throws {
        var text = RawCrashReport.preamble(appVersion: "1.0.1275", imageName: "QAudionApp",
                                           imageUUID: "0123ABCD-4567-89AB-CDEF-0123456789AB",
                                           loadAddress: 0x1_0467_0000, textSize: 0x40_0000)
        text += "sig=10\nts=1762543457\nmain=0\nbt=3\n"
        for a: UInt64 in [0x1_0467_a828, 0x1_8abc_def0, 0x1_9fff_0010] {
            text += "0x" + String(repeating: "0", count: 16 - String(a, radix: 16).count) + String(a, radix: 16) + "\n"
        }
        text += "fatal=Fatal error: Index out of range\n"
        let r = try XCTUnwrap(RawCrashReport.parse(text))
        var lines = r.summaryLines()
        lines += r.legacyReportText(context: "in_call=1 native=1 call8=abcd1234 phase=active", breadcrumbs: [])
            .components(separatedBy: "\n")
        assertSurvives(lines)
    }
}

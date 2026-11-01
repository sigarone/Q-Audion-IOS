import XCTest
@testable import QAudionApp

/// The log attachment of a report is the user's choice for that report (a checkbox, on by default),
/// the report names the call it is about even just after it ended, and the report id is logged.
@MainActor
final class BugReportConsentTests: XCTestCase {

    private func entry(_ level: String, _ message: String) -> LiveLogRawEntry {
        LiveLogRawEntry(seq: 1, timestamp: Date(), level: level, tag: "call", message: message)
    }

    private func report(trigger: String = "manual", attach: Bool, lines: Int) -> BugReporter.PendingReport {
        var r = BugReporter.PendingReport(
            screenshot: nil,
            logEntries: (0..<lines).map { entry("info", "line \($0)") },
            trigger: trigger,
            capturedAt: Date())
        r.attachLogs = attach
        return r
    }

    private func block(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return object["report"] as? [String: Any]
    }

    // MARK: - log_capture

    func test_logCaptureValues() {
        XCTAssertEqual(ReportLogCapture.resolve(attach: true, lineCount: 5), .reportConsent)
        XCTAssertEqual(ReportLogCapture.resolve(attach: false, lineCount: 5), .userDeclined)
        XCTAssertEqual(ReportLogCapture.resolve(attach: true, lineCount: 0), .empty)
        XCTAssertEqual(ReportLogCapture.resolve(attach: true, lineCount: 5, automatic: true), .on)
    }

    func test_reportIsAttachedByDefaultAndDeclinedCarriesNoLine() {
        XCTAssertTrue(report(attach: true, lines: 3).attachLogs)
        XCTAssertEqual(report(attach: true, lines: 3).attachedLogEntries.count, 3)
        XCTAssertTrue(report(attach: false, lines: 3).attachedLogEntries.isEmpty)
    }

    func test_headerSaysWhatWasDone() {
        let consent = BugReporter.addingReportBlock(to: "{}", report: report(attach: true, lines: 3))
        XCTAssertEqual(block(consent)?["log_capture"] as? String, "report_consent")
        XCTAssertEqual(block(consent)?["log_lines"] as? Int, 3)

        let declined = BugReporter.addingReportBlock(to: "{}", report: report(attach: false, lines: 3))
        XCTAssertEqual(block(declined)?["log_capture"] as? String, "user_declined")
        XCTAssertEqual(block(declined)?["log_lines"] as? Int, 0)

        let empty = BugReporter.addingReportBlock(to: "{}", report: report(attach: true, lines: 0))
        XCTAssertEqual(block(empty)?["log_capture"] as? String, "empty")

        let auto = BugReporter.addingReportBlock(to: "{}", report: report(trigger: "auto", attach: true, lines: 2))
        XCTAssertEqual(block(auto)?["log_capture"] as? String, "on")
    }

    func test_declinedReportDropsTheSnapshotQuotedLogLines() {
        let snapshot = "{\"call\":{\"group_diag\":[\"x\"],\"muted\":false}}"
        let declined = BugReporter.addingReportBlock(to: snapshot, report: report(attach: false, lines: 2))
        let kept = BugReporter.addingReportBlock(to: snapshot, report: report(attach: true, lines: 2))
        XCTAssertFalse(declined.contains("group_diag"))
        XCTAssertTrue(declined.contains("muted"))
        XCTAssertTrue(kept.contains("group_diag"))
    }

    func test_abuseReportCarriesNoBlock() {
        let out = BugReporter.addingReportBlock(to: "{}", report: report(trigger: "abuse", attach: true, lines: 0))
        XCTAssertEqual(out, "{}")
    }

    func test_ringLinesBelowInfoAreLeftOut() {
        let kept = ReportLogSupport.infoAndAbove([entry("debug", "a"), entry("info", "b"),
                                                  entry("warn", "c"), entry("error", "d")])
        XCTAssertEqual(kept.map { $0.message }, ["b", "c", "d"])
    }

    // MARK: - The call a report is about

    func test_liveCallIsReturnedAndRemembered() {
        var memory = ReportCallMemory()
        XCTAssertEqual(memory.resolve(live: "call-1", at: Date()), "call-1")
        XCTAssertEqual(memory.lastId, "call-1")
    }

    func test_endedCallIsKeptForTenMinutes() {
        var memory = ReportCallMemory()
        let start = Date()
        _ = memory.resolve(live: "call-1", at: start)
        XCTAssertEqual(memory.resolve(live: nil, at: start.addingTimeInterval(599)), "call-1")
        XCTAssertNil(memory.resolve(live: nil, at: start.addingTimeInterval(601)))
    }

    func test_noCallEverMeansNoId() {
        var memory = ReportCallMemory()
        XCTAssertNil(memory.resolve(live: nil, at: Date()))
        XCTAssertNil(memory.resolve(live: "", at: Date()))
    }

    func test_newCallReplacesTheOldOne() {
        var memory = ReportCallMemory()
        let t = Date()
        _ = memory.resolve(live: "call-1", at: t)
        _ = memory.resolve(live: "call-2", at: t.addingTimeInterval(60))
        XCTAssertEqual(memory.resolve(live: nil, at: t.addingTimeInterval(120)), "call-2")
    }

    func test_resetForgetsTheCall() {
        var memory = ReportCallMemory()
        let t = Date()
        _ = memory.resolve(live: "call-1", at: t)
        memory.reset()
        XCTAssertNil(memory.resolve(live: nil, at: t))
    }

    // MARK: - Report id

    func test_reportIdIsParsedFromTheResponse() {
        let body = Data("{\"id\":\"0123456789abcdef\",\"status\":\"received\"}".utf8)
        XCTAssertEqual(ReportLogSupport.reportId(fromResponse: body), "0123456789abcdef")
        XCTAssertNil(ReportLogSupport.reportId(fromResponse: Data("not json".utf8)))
        XCTAssertNil(ReportLogSupport.reportId(fromResponse: Data("{\"status\":\"received\"}".utf8)))
        XCTAssertNil(ReportLogSupport.reportId(fromResponse: nil))
    }

    func test_sentLineCarriesOnlyTheFirstEightCharacters() {
        let line = ReportLogSupport.sentLine(reportId: "0123456789abcdef", callId: "fedcba9876543210", logLines: 42)
        XCTAssertEqual(line, "W-REPORT sent id=01234567 call=fedcba98 logs=42")
        XCTAssertEqual(ReportLogSupport.sentLine(reportId: "abcdefghij", callId: nil, logLines: 0),
                       "W-REPORT sent id=abcdefgh call=0 logs=0")
    }
}

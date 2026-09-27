import XCTest
@testable import QAudionEngine

/// W-CRASHTELEMETRY (this task). Fixtures mirror `CrashReporter.persist()`'s
/// EXACT text shape byte-for-byte (see that type's own header comment) — a
/// change to the writer that is not reflected here is exactly the kind of
/// drift this test suite exists to catch.
final class CrashReportTextParserTests: XCTestCase {

    func test_nsException_withContextAndBreadcrumbs() {
        let text = [
            "=== QAUDION CRASH — NSException ===",
            "name: NSInvalidArgumentException",
            "reason: something went wrong",
            "stack:",
            "0   QAudionApp    0x0000000100 somefunc + 24",
            "1   QAudionApp    0x0000000200 otherfunc + 48",
            "context: in_call=1 native=1 call8=abcd1234 phase=active",
            "breadcrumbs:",
            "info call: one",
            "warn call: two"
        ].joined(separator: "\n")

        guard let parsed = CrashReportTextParser.parse(text) else {
            return XCTFail("expected a parsed report")
        }
        XCTAssertEqual(parsed.crashKind, "nsexception")
        XCTAssertEqual(parsed.name, "NSInvalidArgumentException")
        XCTAssertEqual(parsed.reason, "something went wrong")
        XCTAssertEqual(parsed.stackLines, [
            "0   QAudionApp    0x0000000100 somefunc + 24",
            "1   QAudionApp    0x0000000200 otherfunc + 48"
        ])
        XCTAssertEqual(parsed.callContext, "in_call=1 native=1 call8=abcd1234 phase=active")
        XCTAssertEqual(parsed.breadcrumbLines, ["info call: one", "warn call: two"])
    }

    func test_nsException_noContextNoBreadcrumbs() {
        let text = [
            "=== QAUDION CRASH — NSException ===",
            "name: NSRangeException",
            "reason: (nil)",
            "stack:",
            "0   QAudionApp    0x0000000100 somefunc + 24"
        ].joined(separator: "\n")

        guard let parsed = CrashReportTextParser.parse(text) else {
            return XCTFail("expected a parsed report")
        }
        XCTAssertEqual(parsed.crashKind, "nsexception")
        XCTAssertEqual(parsed.name, "NSRangeException")
        XCTAssertEqual(parsed.reason, "(nil)")
        XCTAssertEqual(parsed.stackLines, ["0   QAudionApp    0x0000000100 somefunc + 24"])
        XCTAssertNil(parsed.callContext)
        XCTAssertEqual(parsed.breadcrumbLines, [])
    }

    func test_signal_withFatalAndContext_noBreadcrumbs() {
        let text = [
            "=== QAUDION CRASH — signal 11 (SIGSEGV) ===",
            "fatal: Fatal error: Unexpectedly found nil",
            "stack:",
            "0   QAudionApp    0x0000000300 crashy + 12",
            "1   QAudionApp    0x0000000400 caller + 96",
            "context: in_call=1 native=0 phase=snapshot"
        ].joined(separator: "\n")

        guard let parsed = CrashReportTextParser.parse(text) else {
            return XCTFail("expected a parsed report")
        }
        XCTAssertEqual(parsed.crashKind, "signal")
        XCTAssertEqual(parsed.name, "SIGSEGV")
        XCTAssertEqual(parsed.reason, "Fatal error: Unexpectedly found nil")
        XCTAssertEqual(parsed.stackLines, [
            "0   QAudionApp    0x0000000300 crashy + 12",
            "1   QAudionApp    0x0000000400 caller + 96"
        ])
        XCTAssertEqual(parsed.callContext, "in_call=1 native=0 phase=snapshot")
        XCTAssertEqual(parsed.breadcrumbLines, [])
    }

    func test_signal_noFatal_withBreadcrumbs_noContext() {
        let text = [
            "=== QAUDION CRASH — signal 6 (SIGABRT) ===",
            "stack:",
            "0   QAudionApp    0x0000000500 aborted + 8"
            ,
            "breadcrumbs:",
            "error call: boom"
        ].joined(separator: "\n")

        guard let parsed = CrashReportTextParser.parse(text) else {
            return XCTFail("expected a parsed report")
        }
        XCTAssertEqual(parsed.crashKind, "signal")
        XCTAssertEqual(parsed.name, "SIGABRT")
        XCTAssertEqual(parsed.reason, "")
        XCTAssertEqual(parsed.stackLines, ["0   QAudionApp    0x0000000500 aborted + 8"])
        XCTAssertNil(parsed.callContext)
        XCTAssertEqual(parsed.breadcrumbLines, ["error call: boom"])
    }

    func test_emptyText_returnsNil() {
        XCTAssertNil(CrashReportTextParser.parse(""))
    }

    func test_foreignText_returnsNil() {
        XCTAssertNil(CrashReportTextParser.parse("some unrelated log line\nmore text"))
    }

    func test_missingStackLine_returnsNil() {
        let text = "=== QAUDION CRASH — NSException ===\nname: Foo\nreason: bar"
        XCTAssertNil(CrashReportTextParser.parse(text))
    }

    func test_emptyStack_isValid() {
        let text = [
            "=== QAUDION CRASH — signal 4 (SIGILL) ===",
            "stack:"
        ].joined(separator: "\n")
        guard let parsed = CrashReportTextParser.parse(text) else {
            return XCTFail("expected a parsed report")
        }
        XCTAssertEqual(parsed.name, "SIGILL")
        XCTAssertEqual(parsed.stackLines, [])
    }
}

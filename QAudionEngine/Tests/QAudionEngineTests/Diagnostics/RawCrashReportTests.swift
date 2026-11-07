import XCTest
@testable import QAudionEngine

final class RawCrashReportTests: XCTestCase {

    /// Byte for byte what `CrashRawCapture` writes: the preamble from `RawCrashReport.preamble`, then the lines the
    /// signal handler appends.
    private func record(signal: Int32 = 10, main: Bool = false, addresses: [UInt64], fatal: String? = nil) -> String {
        var s = RawCrashReport.preamble(appVersion: "1.0.1275", imageName: "QAudionApp",
                                        imageUUID: "0123ABCD-4567-89AB-CDEF-0123456789AB",
                                        loadAddress: 0x1_0000_0000, textSize: 0x40_0000)
        s += "sig=" + String(signal) + "\n"
        s += "ts=1762543457\n"
        s += "main=" + (main ? "1" : "0") + "\n"
        s += "bt=" + String(addresses.count) + "\n"
        for a in addresses { s += "0x" + RawCrashReport.hex16(a) + "\n" }
        if let f = fatal { s += "fatal=" + f + "\n" }
        return s
    }

    func test_preambleShape() {
        let p = RawCrashReport.preamble(appVersion: "1.0.1275", imageName: "QAudionApp",
                                        imageUUID: "0123abcd-4567-89ab-cdef-0123456789ab",
                                        loadAddress: 0x1_0000_0000, textSize: 0x40_0000)
        XCTAssertEqual(p, [
            "QACRASH1",
            "ver=1.0.1275",
            "img=QAudionApp uuid=0123ABCD.4567.89AB.CDEF.0123456789AB load=0x0000000100000000 size=0x0000000000400000",
            "",
        ].joined(separator: "\n"))
    }

    func test_parseRoundTrip() throws {
        let text = record(addresses: [0x1_0000_1000, 0x1_8000_0000, 0x1_003F_FFFF, 0x1_0040_0000], fatal: "boom")
        let r = try XCTUnwrap(RawCrashReport.parse(text))
        XCTAssertEqual(r.appVersion, "1.0.1275")
        XCTAssertEqual(r.imageName, "QAudionApp")
        XCTAssertEqual(r.imageUUID, "0123ABCD.4567.89AB.CDEF.0123456789AB")
        XCTAssertEqual(r.loadAddress, 0x1_0000_0000)
        XCTAssertEqual(r.textSize, 0x40_0000)
        XCTAssertEqual(r.signal, 10)
        XCTAssertEqual(r.timestampSec, 1762543457)
        XCTAssertFalse(r.mainThread)
        XCTAssertEqual(r.addresses.count, 4)
        XCTAssertEqual(r.fatal, "boom")
    }

    func test_framesInsideTheMainBinaryGetAnOffsetOthersKeepTheAddress() throws {
        let r = try XCTUnwrap(RawCrashReport.parse(
            record(addresses: [0x1_0000_1000, 0x1_8000_0000, 0x1_003F_FFFF, 0x1_0040_0000])))
        XCTAssertEqual(r.frameLines(), [
            "0   QAudionApp   0x0000000100001000 QAudionApp + 4096",
            "1   ?   0x0000000180000000",
            "2   QAudionApp   0x00000001003fffff QAudionApp + 4194303",
            "3   ?   0x0000000100400000",
        ])
    }

    func test_frameLinesMatchTheShapeTheSymbolicatorKeysOn() throws {
        let r = try XCTUnwrap(RawCrashReport.parse(record(addresses: [0x1_0000_1000])))
        // scripts/symbolicate.py: `(\d+)\s+QAudionApp\s+0x<hex>\s+QAudionApp\s*\+\s*(\d+)`
        let line = r.frameLines()[0]
        let rx = try NSRegularExpression(pattern: #"(\d+)\s+QAudionApp\s+0x([0-9a-fA-F]+)\s+QAudionApp\s*\+\s*(\d+)"#)
        XCTAssertNotNil(rx.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)))
    }

    func test_legacyTextFeedsTheExistingParser() throws {
        let r = try XCTUnwrap(RawCrashReport.parse(
            record(signal: 11, addresses: [0x1_0000_1000, 0x1_8000_0000], fatal: "Fatal error: x")))
        let text = r.legacyReportText(context: "in_call=1 phase=active", breadcrumbs: [])
        let parsed = try XCTUnwrap(CrashReportTextParser.parse(text))
        XCTAssertEqual(parsed.crashKind, "signal")
        XCTAssertEqual(parsed.name, "SIGSEGV")
        XCTAssertEqual(parsed.reason, "Fatal error: x")
        XCTAssertEqual(parsed.stackLines.count, 2)
        XCTAssertEqual(parsed.callContext, "in_call=1 phase=active")
        XCTAssertTrue(parsed.breadcrumbLines.isEmpty)
    }

    func test_legacyTextWithoutContextOrFatal() throws {
        let r = try XCTUnwrap(RawCrashReport.parse(record(signal: 10, addresses: [0x1_0000_1000])))
        let parsed = try XCTUnwrap(CrashReportTextParser.parse(r.legacyReportText(context: nil, breadcrumbs: [])))
        XCTAssertEqual(parsed.name, "SIGBUS")
        XCTAssertEqual(parsed.reason, "")
        XCTAssertNil(parsed.callContext)
    }

    func test_aRecordCutShortStillParses() throws {
        // The handler died after the signal line and the first address.
        var text = RawCrashReport.preamble(appVersion: "1.0.1275", imageName: "QAudionApp",
                                           imageUUID: "0123ABCD-4567-89AB-CDEF-0123456789AB",
                                           loadAddress: 0x1_0000_0000, textSize: 0x40_0000)
        text += "sig=10\nts=1762543457\nmain=1\nbt=9\n0x0000000100001000\n0x00000001000"
        let r = try XCTUnwrap(RawCrashReport.parse(text))
        XCTAssertEqual(r.signal, 10)
        XCTAssertTrue(r.mainThread)
        XCTAssertEqual(r.addresses.first, 0x1_0000_1000)
    }

    func test_foreignOrEmptyTextIsRejected() {
        XCTAssertNil(RawCrashReport.parse(""))
        XCTAssertNil(RawCrashReport.parse("hello\nsig=10\n"))
        // The magic alone, no signal line: nothing to report.
        XCTAssertNil(RawCrashReport.parse("QACRASH1\nver=1.0.1\n"))
    }

    func test_addressesAreCappedAndSignalNamesMapped() throws {
        var text = "QACRASH1\nsig=6\n"
        for i in 0..<200 { text += "0x" + RawCrashReport.hex16(UInt64(i)) + "\n" }
        let r = try XCTUnwrap(RawCrashReport.parse(text))
        XCTAssertEqual(r.addresses.count, RawCrashReport.maxAddresses)
        XCTAssertEqual(RawCrashReport.signalName(6), "SIGABRT")
        XCTAssertEqual(RawCrashReport.signalName(10), "SIGBUS")
        XCTAssertEqual(RawCrashReport.signalName(999), "SIG?")
    }

    func test_summaryLinesCarryBuildBinaryAndThread() throws {
        let r = try XCTUnwrap(RawCrashReport.parse(record(main: true, addresses: [0x1_0000_1000])))
        XCTAssertEqual(r.summaryLines(), [
            "app_version=1.0.1275 signal=10 (SIGBUS) ts=1762543457 thread=main frames=1",
            "image: QAudionApp uuid=0123ABCD.4567.89AB.CDEF.0123456789AB load 0x100000000 size 0x400000",
        ])
    }
}

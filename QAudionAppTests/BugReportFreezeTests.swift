import XCTest
import CryptoKit
@testable import QAudionApp

/// W-REPORTFREEZE (2026-10-03) -- sending a bug report during a group call froze the iPhone
/// main thread for ~32 s (hang ms=32304, `main_stall_ms_max` 27404, 762 live-log lines
/// dropped). `BugReporter` is `@MainActor` and ran the whole assembly there: the 1.36 MB log
/// went through `LogRedactor.redactStructured` just to keep its last 200 characters, and
/// `redactStructured` restored its ~2,350 stashed values with one full-string
/// `replacingOccurrences` per entry (quadratic).
///
/// What these tests pin:
///   - the single-pass restore gives the same text as the quadratic loop it replaced, on a real
///     stash from the real pipeline and on a synthetic one with forged / malformed sentinels;
///   - the restore is linear (a 1.5 MB text with 5,000 stashed values runs in well under a
///     second; the old loop needed tens of seconds);
///   - `buildDiagSummary` redacts only the tail window and still returns exactly what redacting
///     the whole log would have returned (redaction strength identical, fail-closed);
///   - the off-main assembly produces the same kind of upload: encrypted fields, redacted
///     `diag_summary`, no plaintext log text.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the
/// `-only-testing` list of `.github/workflows/ios-app-tests.yml`.
final class BugReportFreezeTests: XCTestCase {

    // MARK: - Fixtures

    /// Deterministic generator: the same seed gives the same log on every run.
    private struct Lcg {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
        mutating func hex(_ n: Int) -> String {
            let digits = Array("0123456789abcdef")
            var s = ""
            for _ in 0..<n { s.append(digits[int(16)]) }
            return s
        }
        mutating func b64(_ n: Int) -> String {
            let digits = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
            var s = ""
            for _ in 0..<n { s.append(digits[int(digits.count)]) }
            return s
        }
        mutating func uuid() -> String {
            return "\(hex(8))-\(hex(4))-\(hex(4))-\(hex(4))-\(hex(12))"
        }

        /// One log entry as `recentLogsAsString` formats it, some of them with a call id, a
        /// labelled fingerprint, an identifier, a close reason (all stashed by the redactor),
        /// an IP, a secret keyword, a long blob, non-ASCII text, a key-bytes line, and a
        /// keyword whose value sits on the NEXT line (`password=` + line feed).
        mutating func line(_ k: Int) -> String {
            let ts = "2026-10-03T10:57:\(String(format: "%02ld", k % 60)).350Z"
            switch int(12) {
            case 0:
                return "\(ts) [INFO] [call] group join call_id \(uuid()) keyfp=\(hex(16)) state=connected"
            case 1:
                return "\(ts) [INFO] [net] candidate 192.168.\(int(255)).\(int(255)):\(5000 + int(999)) typ relay"
            case 2:
                return "\(ts) [WARN] [auth] token=\(b64(20 + int(40))) refresh failed"
            case 3:
                return "\(ts) [INFO] [call] performAcceptIncomingGroupCall BCryptoGroupCallManager end_reason=identity_key_mismatch"
            case 4:
                return "\(ts) [DEBUG] [net] Authorization: Bearer \(b64(30 + int(60)))"
            case 5:
                return "\(ts) [INFO] [ui] Chiamata terminata: è già così ✓ 📞 \(uuid())"
            case 6:
                return "\(ts) [INFO] [auth] password=\n\(b64(8)) next"
            case 7:
                return "\(ts) [INFO] [call] relay blob \(b64(12))+XyzAbcDef+\(hex(24))=="
            case 8:
                return "\(ts) [DEBUG] [stdout] mixed run \(hex(10))\(b64(30))-\(hex(12)) tail"
            case 9:
                let ints = (0..<32).map { _ in String(int(256)) }.joined(separator: ", ")
                return "\(ts) [INFO] [stdout] derived_key [\(ints)] len 32"
            case 10:
                return "\(ts) [INFO] [call] short8 \(hex(8)) peer \(uuid()) sframe=\(b64(24))"
            default:
                return "\(ts) [INFO] [call] frames received=\(int(500)) loss=\(int(9)) rtt=\(int(300)) ms"
            }
        }
    }

    private func fixtureLog(seed: UInt64, minBytes: Int) -> String {
        var rng = Lcg(state: seed)
        var out = String()
        var k = 0
        while out.utf8.count < minBytes {
            out.append(rng.line(k))
            out.append("\n")
            k += 1
        }
        return out
    }

    /// The restore loop `redactStructured` ran before W-REPORTFREEZE, verbatim.
    private func legacyRestore(_ text: String, stash: [String]) -> String {
        var work = text
        if !stash.isEmpty {
            for (i, u) in stash.enumerated() {
                work = work.replacingOccurrences(of: "\u{0001}K\(i)\u{0001}", with: u)
            }
        }
        return work
    }

    private func sentinel(_ i: Int) -> String { "\u{0001}K\(i)\u{0001}" }

    // MARK: - Single-pass restore == the quadratic loop

    func test_restoreStashed_matchesTheLegacyLoopOnASyntheticStash() {
        var rng = Lcg(state: 42)
        var stash: [String] = []
        var text = ""
        for i in 0..<600 {
            stash.append(i % 3 == 0 ? rng.uuid() : (i % 3 == 1 ? "BCryptoGroupCallManager\(i)" : "keyfp=\(rng.hex(16))"))
            text += "line \(i) è già ✓ 📞 \(sentinel(i)) tail text\n"
        }
        // Sentinels that must stay exactly as they are, in the old loop and in the new pass.
        text += "forged out of range \u{0001}K99999\u{0001} after\n"
        text += "leading zero \u{0001}K01\u{0001} after\n"
        text += "no digits \u{0001}K\u{0001} after\n"
        text += "a lone control char \u{0001} and K5 without delimiters\n"
        // A sentinel-looking run in the INPUT that names a real index is restored, as before.
        text += "forged in range \(sentinel(7)) after\n"
        // Cut sentinel at the very end of the text.
        text += "\u{0001}K12"

        let expected = legacyRestore(text, stash: stash)
        XCTAssertEqual(LogRedactor.restoreStashed(text, stash: stash), expected)
    }

    func test_restoreStashed_withAnEmptyStashReturnsTheTextUntouched() {
        let text = "nothing stashed \u{0001}K0\u{0001} here"
        XCTAssertEqual(LogRedactor.restoreStashed(text, stash: []), text)
    }

    func test_redactStructured_equalsTheLegacyRestoreOnRealPipelineOutput() {
        for seed: UInt64 in [1, 2, 3] {
            let log = fixtureLog(seed: seed, minBytes: 20_000)
            let (work, stash) = LogRedactor.redactStructuredStashed(log)
            XCTAssertFalse(stash.isEmpty, "the fixture must exercise the stash")
            XCTAssertEqual(LogRedactor.redactStructured(log), legacyRestore(work, stash: stash),
                           "seed \(seed)")
        }
    }

    // MARK: - Redaction strength is unchanged (golden lines)

    func test_redactStructured_stillStashesAndStillRedacts() {
        let uuid = "123e4567-e89b-12d3-a456-426614174000"
        let line = "call_id \(uuid) keyfp=0123456789abcdef performAcceptIncomingGroupCall "
            + "end_reason=identity_key_mismatch token=SUPERSECRETVALUE0123456789abcdef from 10.1.2.3:5004"
        let out = LogRedactor.redactStructured(line)
        XCTAssertTrue(out.contains(uuid), out)
        XCTAssertTrue(out.contains("keyfp=0123456789abcdef"), out)
        XCTAssertTrue(out.contains("performAcceptIncomingGroupCall"), out)
        XCTAssertTrue(out.contains("identity_key_mismatch"), out)
        XCTAssertFalse(out.contains("SUPERSECRETVALUE"), out)
        XCTAssertFalse(out.contains("10.1.2.3"), out)
        XCTAssertFalse(out.contains("\u{0001}"), "no sentinel may be left behind: \(out)")
    }

    func test_redactStructured_leavesNoSentinelOnTheFixture() {
        let out = LogRedactor.redactStructured(fixtureLog(seed: 9, minBytes: 30_000))
        XCTAssertFalse(out.contains("\u{0001}"))
    }

    // MARK: - Linear time

    func test_restoreStashed_isLinearOnAMegabyteLog() {
        // 5,000 stashed values spread over ~1.5 MB: the old loop made 5,000 full scans of it
        // (tens of seconds); one pass is a few milliseconds. The bound is loose on purpose.
        let stashCount = 5_000
        var stash: [String] = []
        stash.reserveCapacity(stashCount)
        var text = String()
        text.reserveCapacity(stashCount * 320)
        let filler = String(repeating: "filler text è già ✓ ", count: 14)
        for i in 0..<stashCount {
            stash.append("123e4567-e89b-12d3-a456-4266141\(String(format: "%05ld", i))")
            text += filler + sentinel(i) + "\n"
        }
        XCTAssertGreaterThan(text.utf8.count, 1_400_000)

        let start = Date()
        let restored = LogRedactor.restoreStashed(text, stash: stash)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 3.0, "restore took \(elapsed) s")
        XCTAssertFalse(restored.contains("\u{0001}"))
        XCTAssertTrue(restored.contains(stash[stashCount - 1]))
        XCTAssertTrue(restored.contains(stash[0]))
    }

    func test_buildDiagSummary_onAMegabyteLog_isFastAndRedactsTheTail() {
        var log = fixtureLog(seed: 77, minBytes: 1_400_000)
        log += "2026-10-03T10:58:13.000Z [INFO] [auth] token=LASTLINESECRET0123456789abcdefghij end\n"

        let start = Date()
        let summary = ReportCrypto.buildDiagSummary(logs: log, note: "n", trigger: "manual")
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 3.0, "buildDiagSummary took \(elapsed) s")
        XCTAssertTrue(summary.hasPrefix("trigger=manual note=n logs="), summary)
        XCTAssertFalse(summary.contains("LASTLINESECRET"), summary)
        XCTAssertTrue(summary.contains("***REDACTED***"), summary)
        XCTAssertLessThanOrEqual(summary.count, 500)
    }

    // MARK: - The tail window

    func test_diagTailWindow_returnsAShortLogWhole() {
        let log = "first line\nsecond line\n"
        XCTAssertEqual(String(ReportCrypto.diagTailWindow(of: log)), log)
    }

    func test_diagTailWindow_startsAtALineStartAndKeepsAtLeastTheWindow() {
        let log = fixtureLog(seed: 5, minBytes: 80_000)
        let window = ReportCrypto.diagTailWindow(of: log, windowBytes: 4_096)
        let windowText = String(window)
        XCTAssertTrue(log.hasSuffix(windowText))
        XCTAssertGreaterThanOrEqual(windowText.utf8.count, 4_096)
        // 4,096 bytes plus at most the one line the cut fell inside.
        XCTAssertLessThan(windowText.utf8.count, 4_096 + 1_024)
        // It begins right after a line feed.
        let before = log.utf8.count - windowText.utf8.count
        let idx = log.utf8.index(log.utf8.startIndex, offsetBy: before - 1)
        XCTAssertEqual(log.utf8[idx], 0x0A)
    }

    func test_diagTailWindow_withNoLineFeedBeforeTheCutKeepsTheWholeText() {
        let log = String(repeating: "x", count: 50_000)
        XCTAssertEqual(ReportCrypto.diagTailWindow(of: log, windowBytes: 4_096).count, 50_000)
    }

    func test_buildDiagSummary_equalsRedactingTheWholeLog() {
        // The summary built from the tail window must be byte for byte the one that redacting
        // the whole log gives (the pre-fix behaviour), across logs of different shapes.
        for seed: UInt64 in [11, 12, 13, 14] {
            let log = fixtureLog(seed: seed, minBytes: 120_000 + Int(seed) * 1_000)
            let whole = ReportCrypto.diagSummary(redactedLogs: LogRedactor.redactStructured(log),
                                                 note: "a note", trigger: "manual")
            let tail = ReportCrypto.buildDiagSummary(logs: log, note: "a note", trigger: "manual")
            XCTAssertEqual(tail, whole, "seed \(seed)")
        }
    }

    func test_buildDiagSummary_equalsRedactingTheWholeLogForASmallWindowToo() {
        // Same property with a window of 2 KiB: the window is a pure function of the log tail.
        for seed: UInt64 in [21, 22, 23] {
            let log = fixtureLog(seed: seed, minBytes: 60_000)
            let whole = ReportCrypto.diagSummary(redactedLogs: LogRedactor.redactStructured(log),
                                                 note: "", trigger: "auto")
            let window = String(ReportCrypto.diagTailWindow(of: log, windowBytes: 2_048))
            let viaWindow = ReportCrypto.diagSummary(redactedLogs: LogRedactor.redactStructured(window),
                                                     note: "", trigger: "auto")
            XCTAssertEqual(viaWindow, whole, "seed \(seed)")
        }
    }

    func test_buildDiagSummary_shortLogIsRedactedAsBefore() {
        let log = "2026-10-03T10:58:13.000Z [INFO] [auth] Bearer abcdefghijklmnopqrstuvwxyz0123456789 ok 10.0.0.1\n"
        let summary = ReportCrypto.buildDiagSummary(logs: log, note: "x", trigger: "manual")
        XCTAssertFalse(summary.contains("abcdefghijklmnopqrstuvwxyz0123456789"), summary)
        XCTAssertFalse(summary.contains("10.0.0.1"), summary)
        XCTAssertTrue(summary.hasPrefix("trigger=manual note=x logs="), summary)
    }

    // MARK: - The off-main assembly

    func test_logFormatter_formatsAndRedactsEveryEntry() {
        let entries = (0..<5).map { i in
            LiveLogRawEntry(seq: Int64(i), timestamp: Date(timeIntervalSince1970: 1_790_000_000 + Double(i)),
                            level: "info", tag: "call",
                            message: "line \(i) token=SECRETVALUE0123456789abcdef call_id 123e4567-e89b-12d3-a456-426614174000")
        }
        let text = BugReportLogFormatter.format(entries)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 5)
        for line in lines {
            XCTAssertTrue(line.contains(" [INFO] [call] "), String(line))
            XCTAssertFalse(line.contains("SECRETVALUE"), String(line))
            XCTAssertTrue(line.contains("123e4567-e89b-12d3-a456-426614174000"), String(line))
        }
        XCTAssertTrue(text.hasSuffix("\n"))
    }

    func test_assemble_buildsAnEncryptedMultipartUploadOffTheMainActor() async throws {
        let admin = Curve25519.KeyAgreement.PrivateKey()
        let adminHex = admin.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        let entries = (0..<40).map { i in
            LiveLogRawEntry(seq: Int64(i), timestamp: Date(), level: "warn", tag: "net",
                            message: "entry \(i) token=PLAINTEXTSECRET0123456789abcdef")
        }
        let input = BugReportAssembler.Input(
            adminPubKeyHex: adminHex,
            trigger: "manual",
            appVersion: "1.0.0",
            osVersion: "26.0",
            deviceModel: "iPhone",
            userPrefix: "7b86cad8",
            timestamp: "2026-10-03T10:57:41.350Z",
            callId: "630791ae",
            note: "a note",
            bodyPlaintext: "a note\n\n---DIAG---\n{}",
            logEntries: entries,
            extraFields: ["report_category": "spam"],
            screenshot: nil
        )

        // Compiles and runs only because `assemble` is not main-actor isolated.
        let assembled = await Task.detached(priority: .utility) { BugReportAssembler.assemble(input) }.value
        let output = try XCTUnwrap(assembled)

        XCTAssertTrue(output.boundary.hasPrefix("BugReportBoundary"))
        let body = String(decoding: output.body, as: UTF8.self)
        for name in ["platform", "trigger", "app_version", "os_version", "device_model", "user_id",
                     "timestamp", "call_id", "diag_summary", "report_category",
                     "ephemeral_pub", "logs_ephemeral_pub"] {
            XCTAssertTrue(body.contains("name=\"\(name)\""), name)
        }
        XCTAssertTrue(body.contains("name=\"body_enc\"; filename=\"body.enc\""))
        XCTAssertTrue(body.contains("name=\"logs_enc\"; filename=\"logs.enc\""))
        XCTAssertFalse(body.contains("name=\"screenshot_enc\""), "no screenshot was given")
        XCTAssertTrue(body.contains("trigger=manual note=a note logs="))
        XCTAssertFalse(body.contains("PLAINTEXTSECRET"), "the log text must only travel encrypted")
        XCTAssertTrue(body.hasSuffix("--" + output.boundary + "--\r\n"))
    }

    func test_assemble_withAnInvalidAdminKeyReturnsNil() async {
        let input = BugReportAssembler.Input(
            adminPubKeyHex: "not-hex", trigger: "manual", appVersion: "1", osVersion: "1",
            deviceModel: "iPhone", userPrefix: "", timestamp: "", callId: "", note: "", bodyPlaintext: "",
            logEntries: [], extraFields: [:], screenshot: nil)
        let assembled = await Task.detached(priority: .utility) { BugReportAssembler.assemble(input) }.value
        XCTAssertNil(assembled)
    }
}

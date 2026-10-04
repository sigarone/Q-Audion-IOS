import XCTest
@testable import QAudionApp

/// The stdout/stderr tee must never re-capture the sink's own writes.
///
/// CI incident 2026-10-04: the app-test host of `ios-app-tests.yml` ran with `OS_ACTIVITY_DT_MODE`, so every `Logger`
/// line of the sink's OSLog mirror was echoed to stderr, which is the tee's pipe. The tee recorded the echo as a new
/// line, the record mirrored it again, and every pass nested one more `[runtime] [stdout]` level and was cut into more
/// lines by the 4096-byte reads: the job log reached 3.3 GB and the host was starved long enough to fail a 50 ms
/// deadline test after 502 s. The tests here pin both defences (the tee's lines are never mirrored; the echo of the
/// sink's own mirror is dropped before it is recorded) on the pure functions and end to end in this very host
/// process, which is attached to the tee exactly like the app.
@MainActor
final class RuntimeLogSinkTeeTests: XCTestCase {

    /// The echo of a recorded line, as the CI job log showed it (the message is invented).
    private let echo = "2026-10-04 02:11:05.328185+0000 QAudionApp[6733:26267] [runtime] [call] engine created"

    // MARK: - the echo of the sink's own OSLog mirror

    func test_theEchoOfTheSinksOwnMirror_isRecognised() {
        XCTAssertTrue(StdoutTeeLines.isOwnOSLogMirror(echo))
        XCTAssertTrue(StdoutTeeLines.isOwnOSLogMirror(
            "2026-10-04 12:11:05.444368+0200 QAudionApp[12:345] [runtime] [stdout] first text"))
        XCTAssertTrue(StdoutTeeLines.isOwnOSLogMirror("2026-10-04 12:11:05.444368+0200 QAudionApp[12:345] [runtime]"))
        XCTAssertTrue(StdoutTeeLines.isOwnOSLogMirror(
            "2026-10-04 12:11:05.444368+0200 QAudionApp[12:345] [com.qaudion.app:runtime] [call] with the subsystem"))
    }

    /// XCTest writes the token `XCTestOutputBarrier` (no line feed) after each of its outputs, so under `xcodebuild
    /// test` the next line the process writes arrives with it glued in front: the CI job showed a recorded line's echo
    /// recorded a second time, with its date redacted together with the token (a run of 24 or more word characters).
    /// An echo with something in front of it is still the echo.
    func test_anEchoWithTheXCTestBarrierInFrontOfIt_isStillRecognised() {
        XCTAssertTrue(StdoutTeeLines.isOwnOSLogMirror("XCTestOutputBarrier" + echo))
        XCTAssertTrue(StdoutTeeLines.isOwnOSLogMirror("some bytes" + echo))
        XCTAssertFalse(StdoutTeeLines.isOwnOSLogMirror("XCTestOutputBarrier 2026-10-04 12:11:05 no process and no category"))
    }

    /// A line that was already re-captured once starts with the same echo prefix, so even the nested form of the
    /// incident is dropped, whatever its depth.
    func test_aLineThatWasAlreadyRecapturedOnce_isStillRecognised() {
        let nested = "2026-10-04 02:11:05.431858+0000 QAudionApp[6733:26267] [runtime] [stdout] "
            + "2026-10-04 <ip>.328185+0000 QAudionApp<ip> [runtime] [call] engine created"
        XCTAssertTrue(StdoutTeeLines.isOwnOSLogMirror(nested))
    }

    func test_linesOfOtherSubsystemsAndPlainPrints_areNotTheSinksEcho() {
        let lines = [
            "2026-10-04 02:11:04.828522+0000 QAudionApp[6733:26267] [SwiftUI] Accessing State's value outside of being installed",
            "2026-10-04 02:11:05.429916+0000 QAudionApp[6733:26527] [] Failed to send a 6 message",
            "2026-10-04 02:11:05.328185+0000 QAudionApp[6733:26267] [runtimeX] other category",
            "2026-10-04 02:11:05.328185+0000 QAudionApp[6733:26267] [com.apple.foo:other] another subsystem",
            "[runtime] [call] engine created",
            "[OpusCodec] deep PLC enabled (decoder complexity 5)",
            "Test Case '-[QAudionAppTests.SomeTests test_x]' started.",
            "an ordinary line mentioning [runtime] in the middle",
            "",
        ]
        for line in lines {
            XCTAssertFalse(StdoutTeeLines.isOwnOSLogMirror(line), line)
        }
    }

    /// The filter has to see the RAW line: `LogRedactor` reads the time and the `[pid:tid]` of the prefix as
    /// addresses and rewrites them, after which the echo no longer looks like one.
    func test_aRedactedEcho_isNotRecognised_soTheFilterMustRunOnTheRawLine() {
        XCTAssertTrue(StdoutTeeLines.isOwnOSLogMirror(echo))
        XCTAssertFalse(StdoutTeeLines.isOwnOSLogMirror(LogRedactor.redact(echo)))
    }

    // MARK: - the mirror policy

    func test_theTeesOwnLinesAreNeverMirroredToOSLog() {
        XCTAssertFalse(RuntimeLogSink.mirrorsToOSLog(.stdoutTee))
        XCTAssertTrue(RuntimeLogSink.mirrorsToOSLog(.app))
    }

    // MARK: - complete lines out of the 4096-byte reads

    func test_aLineCutBetweenTwoReads_isOneLine() {
        let assembler = StdoutTeeLines.Assembler()
        XCTAssertEqual(assembler.lines(from: Array("first\nsecond li".utf8)), ["first"])
        XCTAssertEqual(assembler.lines(from: Array("ne\nthird\n".utf8)), ["second line", "third"])
    }

    func test_aMultiByteCharacterCutBetweenTwoReads_isDecodedWhole() {
        let bytes = Array("caffè\n".utf8)
        let cut = bytes.count - 2   // inside the two bytes of "è"
        let assembler = StdoutTeeLines.Assembler()
        XCTAssertEqual(assembler.lines(from: Array(bytes[..<cut])), [])
        XCTAssertEqual(assembler.lines(from: Array(bytes[cut...])), ["caffè"])
    }

    func test_emptyLinesAreDropped_andAnUnfinishedTailWaitsForItsNewline() {
        let assembler = StdoutTeeLines.Assembler()
        XCTAssertEqual(assembler.lines(from: Array("a\n\n\nb".utf8)), ["a"])
        XCTAssertEqual(assembler.lines(from: Array("\n".utf8)), ["b"])
        XCTAssertEqual(assembler.lines(from: [UInt8]()), [])
    }

    func test_anUnterminatedRunPastTheLimit_isFlushedAsALine() {
        let assembler = StdoutTeeLines.Assembler()
        let run = [UInt8](repeating: 0x78, count: StdoutTeeLines.Assembler.maxPendingBytes)
        XCTAssertEqual(assembler.lines(from: run), [], "at the limit it is still held")
        let flushed = assembler.lines(from: Array("y".utf8))
        XCTAssertEqual(flushed.count, 1)
        XCTAssertEqual(flushed.first?.count, StdoutTeeLines.Assembler.maxPendingBytes + 1)
        XCTAssertEqual(assembler.lines(from: Array("z\n".utf8)), ["z"], "nothing is left over")
    }

    // MARK: - end to end, in this host process (attached to the tee like the app)

    /// Letters from g to z only: the log redactors leave such a run alone.
    private func uniqueMarker() -> String {
        "teeprobe" + String((0..<12).map { _ in "ghijklmnopqrstuvwxyz".randomElement() ?? "g" })
    }

    private func lastSeq() -> Int64 { RuntimeLogSink.shared.snapshotEntries.last?.seq ?? 0 }

    private func entries(containing marker: String) -> [RuntimeLogSink.Entry] {
        RuntimeLogSink.shared.snapshotEntries.filter { $0.message.contains(marker) }
    }

    /// The regression the incident was: a recorded line came back through the tee and was recorded again, on every
    /// pass, without end. After a pause that is long next to one pass, the ring has grown by the lines recorded here
    /// plus a handful (the test runner's own lines, an echo or two) and not by hundreds.
    func test_recordedLines_doNotMakeTheRingGrowWithoutEnd() async throws {
        RuntimeLogSink.shared.attachStdoutTee()
        let before = lastSeq()
        let marker = uniqueMarker()
        for index in 0..<5 {
            RuntimeLogSink.shared.record(level: .info, tag: "teeprobe", "line \(index) \(marker)")
        }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let grown = Int(lastSeq() - before)
        XCTAssertGreaterThanOrEqual(grown, 5, "the five recorded lines are in the ring")
        XCTAssertLessThan(grown, 60, "a feedback loop adds hundreds of lines a second; the ring grew by \(grown)")
    }

    /// A line recorded through the sink is in the ring once: the console echo of its own OSLog mirror (present
    /// whenever the process runs with `OS_ACTIVITY_DT_MODE`, as the CI test host does) is not recorded as a second
    /// line. The count is taken before the assertion: a failure message is printed on the streams the tee reads.
    func test_aLineRecordedThroughTheSink_isNotRecordedAgainFromItsConsoleEcho() async throws {
        RuntimeLogSink.shared.attachStdoutTee()
        let marker = uniqueMarker()
        RuntimeLogSink.shared.record(level: .info, tag: "teeprobe", "\(marker) written through the sink")
        let immediately = entries(containing: marker).count
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let after = entries(containing: marker)
        XCTAssertEqual(immediately, 1, "recorded once, synchronously")
        XCTAssertEqual(after.count, 1, "its echo on stderr must not be recorded again")
        XCTAssertEqual(after.first?.tag, "teeprobe")
    }

    /// A line the process prints on stderr is recorded once by the tee. (The space in front keeps the token XCTest
    /// glues to the line from forming a run of 24 or more word characters with the marker, which the redactor would
    /// replace.)
    func test_aLinePrintedOnStderr_isRecordedOnceByTheTee() async throws {
        RuntimeLogSink.shared.attachStdoutTee()
        let marker = uniqueMarker()
        fputs(" \(marker) printed by the process" + "\n", stderr)
        var waited = 0
        while entries(containing: marker).isEmpty && waited < 200 {
            try await Task.sleep(nanoseconds: 50_000_000)
            waited += 1
        }
        let first = entries(containing: marker).count
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let after = entries(containing: marker)
        XCTAssertEqual(first, 1, "captured")
        XCTAssertEqual(after.count, 1, "captured once")
        XCTAssertEqual(after.first?.tag, "stdout")
    }

    // MARK: - wiring

    private func sourceText(_ relativePath: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
        }
        throw XCTSkip("\(relativePath) not found")
    }

    /// The tee drops the echo on the raw line (before the redaction), and records what it keeps with the tee origin.
    func test_theTeeDropsTheEchoBeforeRedactingAndRecordsWithTheTeeOrigin() throws {
        let text = try sourceText("QAudionApp/Services/RuntimeLogSink.swift")
        let start = try XCTUnwrap(text.range(of: "public func attachStdoutTee() {"))
        let tail = text[start.upperBound...]
        let end = try XCTUnwrap(tail.range(of: "public func detachStdoutTee() {"))
        let tee = String(tail[..<end.lowerBound])
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let dropAt = try XCTUnwrap(tee.range(of: "if StdoutTeeLines.isOwnOSLogMirror(line) { continue }"))
        let redactAt = try XCTUnwrap(tee.range(of: "RuntimeLogSink.redact(line)"))
        XCTAssertLessThan(dropAt.lowerBound, redactAt.lowerBound, "the echo is judged on the raw line")
        XCTAssertTrue(tee.contains("origin: .stdoutTee"), "a captured line is never mirrored back to OSLog")
        XCTAssertTrue(tee.contains("assembler.lines(from: buf[0..<n])"), "lines are assembled across reads")
    }
}

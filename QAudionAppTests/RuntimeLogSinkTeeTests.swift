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

    private func entries(containing marker: String) -> [RuntimeLogSink.Entry] {
        RuntimeLogSink.shared.snapshotEntries.filter { $0.message.contains(marker) }
    }

    /// Letters from g to z only: the log redactors leave such a run alone.
    private func uniqueMarker() -> String {
        "teeprobe" + String((0..<12).map { _ in "ghijklmnopqrstuvwxyz".randomElement() ?? "g" })
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// A line the process prints is recorded once. A feedback loop records it again on every pass, so after a pause
    /// that is long compared with one pass the count is the proof.
    func test_aLineTheProcessPrints_isRecordedOnce_andNeverEchoedBackIntoTheRing() async throws {
        RuntimeLogSink.shared.attachStdoutTee()
        let marker = uniqueMarker()
        fputs("\(marker) printed by the process\n", stderr)
        try await waitUntil { !self.entries(containing: marker).isEmpty }
        XCTAssertEqual(entries(containing: marker).count, 1, "captured once")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let after = entries(containing: marker)
        XCTAssertEqual(after.count, 1, "the sink must not re-capture what it recorded")
        XCTAssertEqual(after.first?.tag, "stdout")
    }

    /// A line recorded through the sink is in the ring once: the console echo of its own OSLog mirror (present
    /// whenever the process runs with `OS_ACTIVITY_DT_MODE`, as the CI test host does) is not recorded as a second
    /// line.
    func test_aLineRecordedThroughTheSink_isNotRecordedAgainFromItsConsoleEcho() async throws {
        RuntimeLogSink.shared.attachStdoutTee()
        let marker = uniqueMarker()
        RuntimeLogSink.shared.record(level: .info, tag: "teeprobe", "\(marker) written through the sink")
        XCTAssertEqual(entries(containing: marker).count, 1, "recorded once, synchronously")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let after = entries(containing: marker)
        XCTAssertEqual(after.count, 1, "its echo on stderr must not be recorded again")
        XCTAssertEqual(after.first?.tag, "teeprobe")
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

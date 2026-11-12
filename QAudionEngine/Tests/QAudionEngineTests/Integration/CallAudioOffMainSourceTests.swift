import XCTest

/// Source-order checks (the app target cannot be linked into the engine tests): the call-fallback
/// engage and recover do no audio-session or audio-engine work on the calling (main) thread, and
/// the log pipeline does not wait for the main thread. They read the sources of the repository the
/// tests were built from.
final class CallAudioOffMainSourceTests: XCTestCase {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Integration
            .deletingLastPathComponent()  // QAudionEngineTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // QAudionEngine
            .deletingLastPathComponent()  // repository root
    }

    private func source(_ relativePath: String) throws -> String {
        let url = repoRoot().appendingPathComponent(relativePath)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "source tree not available")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The text of the method that starts with `signature`, up to its closing brace at 4-space indent.
    private func body(of signature: String, in text: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: signature), "missing \(signature)")
        let rest = text[start.lowerBound...]
        let end = try XCTUnwrap(rest.range(of: "\n    }\n"), "unterminated \(signature)")
        // Comment lines are dropped: the checks are about code.
        return String(rest[..<end.upperBound])
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func test_engageAudioSrtpFallback_doesNoAudioWorkOnTheCallingThread() throws {
        let text = try source("QAudionApp/Services/CallService.swift")
        let engage = try body(of: "public func engageAudioSrtpFallback(", in: text)

        // The native unit switch is inside the queue closure, after the submit.
        let submit = try XCTUnwrap(engage.range(of: "audioEngineQueue.submitStart("))
        let unitOff = try XCTUnwrap(engage.range(of: "NativeAudioSessionGate.setNativeAudioActive("))
        XCTAssertLessThan(submit.lowerBound, unitOff.lowerBound,
                          "setNativeAudioActive must only run inside the audio queue closure")
        XCTAssertEqual(engage.components(separatedBy: "setNativeAudioActive(").count - 1, 1)

        // Nothing that reaches AVAudio from the calling thread.
        for forbidden in ["AVAudioSession", "AVAudioEngine", ".start()", ".stop(deactivateSession",
                          "startAudioIOIfReady()", "beginFallbackRelayStart(", "audioCapture"] {
            XCTAssertFalse(engage.contains(forbidden), "engageAudioSrtpFallback must not contain \(forbidden)")
        }
    }

    func test_continuationAndStartPath_runTheRelayStartThroughTheQueue() throws {
        let text = try source("QAudionApp/Services/CallService.swift")
        let attempt = try body(of: "private func dispatchAudioCaptureStart(", in: text)
        XCTAssertTrue(attempt.contains("audioEngineQueue.submitStart("))
        // The AVAudio calls of the start are in the queue-side function, never in the main-thread booking.
        let finish = try body(of: "private func finishAudioCaptureStart(", in: text)
        for forbidden in ["AVAudioSession", "capture.start()", "currentRoute"] {
            XCTAssertFalse(finish.contains(forbidden), "the main-thread booking must not contain \(forbidden)")
        }
        let run = try body(of: "private static func runAudioCaptureStart(", in: text)
        XCTAssertTrue(run.contains("capture.start()"))
        XCTAssertTrue(run.contains("currentRoute"))
    }

    func test_everyCaptureStopGoesThroughTheQueue() throws {
        let text = try source("QAudionApp/Services/CallService.swift")
        XCTAssertFalse(text.contains("audioCapture?.stop("), "a capture stop on the calling thread")
        XCTAssertFalse(text.contains("audioCapture!.stop("))
        let recover = try body(of: "public func recoverAudioSrtpFallback(", in: text)
        XCTAssertTrue(recover.contains("stopCaptureOnAudioQueue("))
        let teardown = try body(of: "private func teardownAudioStack(", in: text)
        XCTAssertTrue(teardown.contains("stopCaptureOnAudioQueue("))
    }

    func test_logPipeline_doesNotWaitForTheMainThread() throws {
        let worker = try source("QAudionApp/Services/LiveLogWorker.swift")
        XCTAssertFalse(worker.contains("MainActor.run {\n            RuntimeLogSink.shared.rawEntriesSince"),
                       "the shipper must read the ring without a hop to the main actor")
        XCTAssertTrue(worker.contains("RuntimeLogSink.rawEntriesSince("))

        let sink = try source("QAudionApp/Services/RuntimeLogSink.swift")
        XCTAssertTrue(sink.contains("nonisolated static func rawEntriesSince("))
        XCTAssertTrue(sink.contains("RuntimeLogSink.recordFromAnyThread("),
                      "RTLog from another thread appends to the ring on that thread")
    }

    func test_stallMonitor_writesTheStartMarkFromItsOwnQueue() throws {
        let monitor = try source("QAudionApp/Services/MainThreadStallMonitor.swift")
        XCTAssertTrue(monitor.contains("hang_start ms="))
        let markStart = try body(of: "private func markStartIfDue()", in: monitor)
        XCTAssertFalse(markStart.contains("DispatchQueue.main"), "the start mark must not wait for the main thread")
    }
}

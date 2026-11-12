import XCTest

/// Source-order checks (the app target cannot be linked into the engine tests): the call-fallback
/// engage and recover do no audio-session or audio-engine work on the calling (main) thread, no
/// engine mutation of the capture exists outside the functions that run on the audio queue, and
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

    private func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The code (comment lines dropped) of the method that starts with `signature`, up to its closing
    /// brace at 4-space indent.
    private func body(of signature: String, in text: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: signature), "missing \(signature)")
        let rest = text[start.lowerBound...]
        let end = try XCTUnwrap(rest.range(of: "\n    }\n"), "unterminated \(signature)")
        return codeOnly(String(rest[..<end.upperBound]))
    }

    /// Every member function (4-space indent) of a type body: name and code.
    private func memberFunctions(in text: String) -> [(name: String, code: String)] {
        let pattern = #"(?m)^    (?:@\w+ )?(?:(?:private|public|fileprivate|internal|static|final) )*(?:func (\w+)|(deinit))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var result: [(String, String)] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let nameRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            let name = ns.substring(with: nameRange)
            let from = match.range.location
            let tail = ns.substring(from: from)
            guard let end = tail.range(of: "\n    }\n") else { continue }
            result.append((name, codeOnly(String(tail[..<end.upperBound]))))
        }
        return result
    }

    // MARK: - CallService

    func test_engageAudioSrtpFallback_doesNoAudioWorkOnTheCallingThread() throws {
        let text = try source("QAudionApp/Services/CallService.swift")
        let engage = try body(of: "public func engageAudioSrtpFallback(", in: text)
        XCTAssertTrue(engage.contains("queueFallbackEngageUnitSwitch("))
        for forbidden in ["AVAudioSession", "AVAudioEngine", ".start()", ".stop(deactivateSession",
                          "applySwitchOnAudioQueue(", "startAudioIOIfReady()", "beginFallbackRelayStart(", "audioCapture"] {
            XCTAssertFalse(engage.contains(forbidden), "engageAudioSrtpFallback must not contain \(forbidden)")
        }

        // The unit switch is inside the queue closure, after the submit.
        let queued = try body(of: "private func queueFallbackEngageUnitSwitch(", in: text)
        let submit = try XCTUnwrap(queued.range(of: "audioEngineQueue.submitStart("))
        let unitOff = try XCTUnwrap(queued.range(of: "NativeAudioSessionGate.applySwitchOnAudioQueue("))
        XCTAssertLessThan(submit.lowerBound, unitOff.lowerBound)
    }

    /// A queued engage that was skipped is neither dropped half done nor left for ever: it goes through
    /// the skip policy (queued again, or the call handed back).
    func test_skippedEngage_isRecovered() throws {
        let text = try source("QAudionApp/Services/CallService.swift")
        let queued = try body(of: "private func queueFallbackEngageUnitSwitch(", in: text)
        XCTAssertTrue(queued.contains("fallbackEngageSkipped("))
        let skipped = try body(of: "private func fallbackEngageSkipped(", in: text)
        XCTAssertTrue(skipped.contains("FallbackEngageSkipPolicy.action("))
        XCTAssertTrue(skipped.contains("queueFallbackEngageUnitSwitch("))
        XCTAssertTrue(skipped.contains("handBackToNativeSender()"))
    }

    /// THE RULE: every switch of WebRTC's audio unit (off or on) is made on the audio queue and is
    /// owner-checked; the only synchronous one is the release of a peer connection's own arm. The switch
    /// takes the RTCAudioSession configuration lock, which the main thread does not wait for.
    func test_everyNativeUnitSwitchRunsOnTheAudioQueue() throws {
        let gate = try source("QAudionEngine/Sources/QAudionEngine/WebRTC/NativeAudioSessionGate.swift")
        XCTAssertFalse(gate.contains("public static func setNativeAudioActive(_ active: Bool, reason: Int)"),
                       "an unowned switch")
        XCTAssertFalse(gate.contains("public static func enableNativeAudio("), "an unowned switch")

        let files = [
            "QAudionApp/Services/CallService.swift",
            "QAudionApp/AppState.swift",
            "QAudionEngine/Sources/QAudionEngine/GroupCall/GroupAudioUnitDriver.swift",
            "QAudionEngine/Sources/QAudionEngine/WebRTC/QAudionWebRtcCallController.swift",
            "QAudionEngine/Sources/QAudionEngine/WebRTC/QAudionPeerConnection.swift",
        ]
        var applied = 0
        for file in files {
            let text = try source(file)
            let lines = codeOnly(text).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                XCTAssertFalse(line.contains("NativeAudioSessionGate.setNativeAudioActive("), "\(file): unowned switch")
                XCTAssertFalse(line.contains("NativeAudioSessionGate.enableNativeAudio("), "\(file): unowned switch")
                if line.contains("NativeAudioSessionGate.setNativeAudioInactive(") {
                    // The one allowed synchronous switch: the peer connection's own arm release.
                    XCTAssertTrue(file.hasSuffix("QAudionPeerConnection.swift"),
                                  "\(file): a synchronous switch outside the peer connection close")
                    let before = lines[max(0, index - 8)..<index].joined(separator: "\n")
                    XCTAssertTrue(text.contains("THE ONE ALLOWED SYNCHRONOUS SWITCH") && !before.isEmpty)
                }
                if line.contains("NativeAudioSessionGate.applySwitchOnAudioQueue(") {
                    applied += 1
                    let window = lines[max(0, index - 10)..<index].joined(separator: "\n")
                    XCTAssertTrue(window.contains("audioEngineQueue.submit"),
                                  "\(file): applySwitchOnAudioQueue outside the audio queue: \(line)")
                }
            }
        }
        XCTAssertGreaterThanOrEqual(applied, 2)

        // The shapes that carry the owner: queued by `submitSwitch` / `switchOnQueue`, owner read on the caller's thread.
        let service = try source("QAudionApp/Services/CallService.swift")
        let teardown = try body(of: "private func teardownAudioStack(", in: service)
        XCTAssertTrue(teardown.contains("switchNativeUnitOffOnQueue("))
        let offSwitch = try body(of: "private func switchNativeUnitOffOnQueue(", in: service)
        XCTAssertTrue(offSwitch.contains("NativeAudioSessionGate.submitSwitch(false, ifCurrent: nativeUnitSwitchOwner()"))
        let deactivated = try body(of: "public func handleAudioSessionDeactivated(", in: service)
        XCTAssertTrue(deactivated.contains("NativeAudioSessionGate.submitSwitch("))
        let driver = try source("QAudionEngine/Sources/QAudionEngine/GroupCall/GroupAudioUnitDriver.swift")
        XCTAssertGreaterThanOrEqual(driver.components(separatedBy: "NativeAudioSessionGate.submitSwitch(").count - 1, 3)
        let controller = try source("QAudionEngine/Sources/QAudionEngine/WebRTC/QAudionWebRtcCallController.swift")
        XCTAssertTrue(controller.contains("NativeAudioSessionGate.switchOnQueue("))
    }

    /// The owner of the enable is recorded on the main thread when the switch is submitted, before it runs.
    func test_enableRecordsTheOwnerAtSubmitTime() throws {
        let service = try source("QAudionApp/Services/CallService.swift")
        let gate = try body(of: "private func applyNativeAudioUnitGate(", in: service)
        let recorded = try XCTUnwrap(gate.range(of: "nativeUnitOwnerToken = owner"))
        let submitted = try XCTUnwrap(gate.range(of: "NativeAudioSessionGate.submitSwitch(true"))
        XCTAssertLessThan(recorded.lowerBound, submitted.lowerBound)
        XCTAssertFalse(gate.contains("self.nativeUnitOwnerToken = token"), "the owner is not assigned after a hop back")
    }

    /// The capture serial is bumped right after the defensive teardown of a new call, before the session is
    /// configured, and the deactivation is decided after the stop.
    func test_backToBackCalls_serialBumpAndLateDecision() throws {
        let service = try source("QAudionApp/Services/CallService.swift")
        let start = try body(of: "func startCall(engine: QAudionEngine, contactId: String) throws {", in: service)
        let teardownAt = try XCTUnwrap(start.range(of: "teardownAudioStack(resetDcCounters: true)"))
        let bumpAt = try XCTUnwrap(start.range(of: "bumpCaptureSerial()"))
        let configureAt = try XCTUnwrap(start.range(of: "configureForVoIP()"))
        XCTAssertLessThan(teardownAt.lowerBound, bumpAt.lowerBound)
        XCTAssertLessThan(bumpAt.lowerBound, configureAt.lowerBound)
        XCTAssertTrue(service.contains("teardownAudioStack(resetSrtpFallback: false, resetDcCounters: true)\n        bumpCaptureSerial()"))

        let stop = try body(of: "private func stopCaptureOnAudioQueue(", in: service)
        let stopAt = try XCTUnwrap(stop.range(of: "capture?.stop(deactivateSession: false)"))
        let decideAt = try XCTUnwrap(stop.range(of: "CaptureStopPolicy.shouldDeactivateSession("))
        XCTAssertLessThan(stopAt.lowerBound, decideAt.lowerBound, "decided after the stop, at the deactivation")
    }

    func test_startPath_runsTheRelayStartThroughTheQueue() throws {
        let text = try source("QAudionApp/Services/CallService.swift")
        let attempt = try body(of: "private func dispatchAudioCaptureStart(", in: text)
        XCTAssertTrue(attempt.contains("audioEngineQueue.submitStart("))
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

    /// The queued stop of an earlier call must not deactivate the session a newer capture configured.
    func test_queuedStop_doesNotDeactivateTheSessionOfANewerCapture() throws {
        let text = try source("QAudionApp/Services/CallService.swift")
        let stop = try body(of: "private func stopCaptureOnAudioQueue(", in: text)
        XCTAssertTrue(stop.contains("CaptureStopPolicy.shouldDeactivateSession("))
        XCTAssertTrue(stop.contains("currentCaptureSerial()"))
        XCTAssertTrue(text.contains("didSet { if audioCapture != nil { bumpCaptureSerial() } }"))
    }

    // MARK: - AudioCapture

    /// No engine mutation outside the functions that run on the audio queue under the engine lock.
    func test_noEngineMutationOutsideTheQueueConfinedFunctions() throws {
        let text = try source("QAudionEngine/Sources/QAudionEngine/Audio/AudioCapture.swift")
        let mutations = ["removeTap(", "engine?.stop()", "playerNode?.stop()", "engine.stop()",
                         "disableVoiceProcessing(on", "enableVoiceProcessing(on", "engine.prepare()",
                         "try engine.start()", "engine = nil", "playerNode = nil", "engine.attach("]
        let confined: Set<String> = ["startLocked", "stopLocked", "restartEngineForRoute", "handleInterruption", "deinit"]
        var seenConfined: Set<String> = []
        for function in memberFunctions(in: text) {
            let mutates = mutations.contains { function.code.contains($0) }
            if mutates {
                XCTAssertTrue(confined.contains(function.name), "\(function.name) mutates the engine outside the audio queue")
                seenConfined.insert(function.name)
            }
        }
        XCTAssertTrue(seenConfined.isSuperset(of: ["startLocked", "stopLocked", "restartEngineForRoute"]))
    }

    /// Nothing that restarts, starts or stops the engine is scheduled on the main queue, and every
    /// notification handler hops to the audio queue.
    func test_engineEntryPoints_runOnTheAudioQueue() throws {
        let text = try source("QAudionEngine/Sources/QAudionEngine/Audio/AudioCapture.swift")
        let engineCallees = ["restartEngineForRoute(", "restartEngineWithRecovery(", "try start()", "try self.start()",
                             "stopLocked(", "handleInterruption(", "handleRouteChange("]
        for function in memberFunctions(in: text) {
            guard engineCallees.contains(where: { function.code.contains($0) }) else { continue }
            XCTAssertFalse(function.code.contains("DispatchQueue.main.async"),
                           "\(function.name) schedules engine work on the main queue")
        }
        XCTAssertTrue(text.contains("self.runOnEngineQueue { $0.handleInterruption(note, observedEpoch: observedEpoch) }"))
        XCTAssertTrue(text.contains("self?.runOnEngineQueue { $0.handleRouteChange(note) }"))
        XCTAssertTrue(text.contains("self?.runOnEngineQueue { $0.noteEngineConfigurationChange(note) }"))
        XCTAssertTrue(text.contains("engineQueue.submitAfter(milliseconds: 350, work)"))
    }

    /// Reads of the engine objects included: only the queue-confined functions (start, stop, restart,
    /// interruption, the watchdog and retry bodies, the beacon, the config-change note), the bounded
    /// diagnostic reader, and the try-locked playout touch `engine`, `playerNode`, `inputSink`, `playFormat`.
    func test_engineObjectsAreReadOnlyInQueueConfinedFunctions() throws {
        let text = try source("QAudionEngine/Sources/QAudionEngine/Audio/AudioCapture.swift")
        let allowed: Set<String> = [
            "startLocked", "stopLocked", "restartEngineForRoute", "handleInterruption", "deinit",
            "noteVpioStarve", "noteEngineConfigurationChange", "noteRunningAtEndNow", "scheduleForPlayout",
            "fireVpioRetry", "emitStateBeacon",
        ]
        let regex = try NSRegularExpression(pattern: #"(?<![\w.])(?:self\.)?(engine|playerNode|inputSink|playFormat)\b(?!\s*:)"#)
        let strings = try NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*""#)
        for function in memberFunctions(in: text) {
            let ns = function.code as NSString
            let noStrings = strings.stringByReplacingMatches(
                in: function.code, range: NSRange(location: 0, length: ns.length), withTemplate: "\"\"")
            let nsClean = noStrings as NSString
            let hits = regex.numberOfMatches(in: noStrings, range: NSRange(location: 0, length: nsClean.length))
            if hits > 0 {
                XCTAssertTrue(allowed.contains(function.name), "\(function.name) touches the engine outside the audio queue")
            }
        }
        // The readers that are not themselves the lifecycle are only called from a queued, locked context.
        let readers = ["noteVpioStarve(", "noteEngineConfigurationChange(", "fireVpioRetry(", "emitStateBeacon("]
        for function in memberFunctions(in: text) {
            for reader in readers where function.code.contains(reader) && !function.name.hasPrefix(String(reader.dropLast())) {
                XCTAssertTrue(
                    function.code.contains("engineOpLock.lock()") || function.code.contains("runOnEngineQueue"),
                    "\(function.name) calls \(reader) outside a locked, queued context")
            }
        }
    }

    /// No timer on the main queue calls the engine (it may only hop to the audio queue).
    func test_noMainQueueTimerCallsTheEngine() throws {
        let text = try source("QAudionEngine/Sources/QAudionEngine/Audio/AudioCapture.swift")
        let callees = ["restartEngineForRoute(", "restartEngineWithRecovery(", "try start()", "try self.start()",
                       "stopLocked(", "handleInterruption(", "handleRouteChange(", "fireVpioRetry(",
                       "noteVpioStarve(", "emitStateBeacon(", "noteEngineConfigurationChange("]
        for function in memberFunctions(in: text) {
            let onMain = function.code.contains("DispatchQueue.main.async") || function.code.contains("queue: .main")
            guard onMain else { continue }
            let direct = function.code.split(separator: "\n").filter { !$0.contains("runOnEngineQueue") }
                .joined(separator: "\n")
            for callee in callees {
                XCTAssertFalse(direct.contains(callee), "\(function.name): the main queue calls \(callee)")
            }
        }
    }

    /// `stopLocked` clears the interrupted flag, and the interruption handler drops a notification that
    /// reaches the queue after a stop.
    func test_interruptionEndedAfterAStop_isDropped() throws {
        let text = try source("QAudionEngine/Sources/QAudionEngine/Audio/AudioCapture.swift")
        let stop = try body(of: "private func stopLocked(", in: text)
        XCTAssertTrue(stop.contains("wasInterrupted = false"))
        let handler = try body(of: "private func handleInterruption(", in: text)
        XCTAssertTrue(handler.contains("InterruptionHandlingGuard.shouldHandle("))
        XCTAssertTrue(handler.contains("interruptionObserver != nil"))
    }

    /// Telemetry on a lock timeout is "unknown", never false.
    func test_runningAtEndTimeoutIsUnknown() throws {
        let text = try source("QAudionEngine/Sources/QAudionEngine/Audio/AudioCapture.swift")
        let note = try body(of: "public func noteRunningAtEndNow()", in: text)
        XCTAssertTrue(note.contains("noteEngineRunningAtEndUnknown()"))
        XCTAssertFalse(note.contains("withBoundedEngineLock(false)"))
    }

    /// The playout path try-locks before it reads or uses any engine object, and drops the frame
    /// when the lock is busy.
    func test_scheduleForPlayout_triesTheLockFirst_andNeverWaits() throws {
        let text = try source("QAudionEngine/Sources/QAudionEngine/Audio/AudioCapture.swift")
        let schedule = try body(of: "private func scheduleForPlayout(", in: text)
        let tryLock = try XCTUnwrap(schedule.range(of: "engineOpLock.`try`()"))
        let firstEngineUse = try XCTUnwrap(schedule.range(of: "playerNode"))
        XCTAssertLessThan(tryLock.lowerBound, firstEngineUse.lowerBound)
        XCTAssertFalse(schedule.contains("engineOpLock.lock()"), "the playout path must not wait for the lock")
        XCTAssertTrue(schedule.contains("PlayoutEngineAccess.decision("))
    }

    /// `stopLocked` marks the capture not running before the slow teardown, and the recovery retry
    /// checks that no stop came since it was scheduled.
    func test_stopMarksNotRunningFirst_andRetryRechecksEpoch() throws {
        let text = try source("QAudionEngine/Sources/QAudionEngine/Audio/AudioCapture.swift")
        let stop = try body(of: "private func stopLocked(", in: text)
        let notRunning = try XCTUnwrap(stop.range(of: "isRunning = false"))
        let slow = try XCTUnwrap(stop.range(of: "disableVoiceProcessing(on"))
        XCTAssertLessThan(notRunning.lowerBound, slow.lowerBound)
        let recovery = try body(of: "private func restartEngineWithRecovery(", in: text)
        XCTAssertTrue(recovery.contains("stopGeneration == retryStopGeneration"))
        XCTAssertTrue(recovery.contains("engineQueue.currentEpoch == retryEpoch"))
    }

    // MARK: - Logs

    func test_logPipeline_doesNotWaitForTheMainThread() throws {
        let worker = try source("QAudionApp/Services/LiveLogWorker.swift")
        XCTAssertFalse(worker.contains("MainActor.run {\n            RuntimeLogSink.shared.rawEntriesSince"),
                       "the shipper must read the ring without a hop to the main actor")
        XCTAssertTrue(worker.contains("RuntimeLogSink.rawEntriesSince("))

        let sink = try source("QAudionApp/Services/RuntimeLogSink.swift")
        XCTAssertTrue(sink.contains("nonisolated static func rawEntriesSince("))
        XCTAssertTrue(sink.contains("RuntimeLogSink.recordFromAnyThread("),
                      "RTLog from another thread appends to the ring on that thread")
        XCTAssertFalse(sink.contains("self?.record(level: .info, tag: \"stdout\""),
                       "the stdout tee must not hop to the main actor to record")
    }

    func test_stallMonitor_writesTheStartMarkFromItsOwnQueue() throws {
        let monitor = try source("QAudionApp/Services/MainThreadStallMonitor.swift")
        XCTAssertTrue(monitor.contains("hang_start ms="))
        let markStart = try body(of: "private func markStartIfDue()", in: monitor)
        XCTAssertFalse(markStart.contains("DispatchQueue.main"), "the start mark must not wait for the main thread")
    }
}

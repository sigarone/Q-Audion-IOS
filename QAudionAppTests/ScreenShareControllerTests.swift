import XCTest
import CoreMedia
import CoreVideo
@testable import QAudionApp

/// The rules that decide when this device's own screen capture is confirmed running and when it is over: the pure
/// state machine, and the controller driven by a fake recorder and a clock of the test's own.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-ci.yml`.
final class ScreenShareLivenessTests: XCTestCase {

    func test_theFirstFrameConfirmsTheCapture() {
        var liveness = ScreenShareLiveness()
        liveness.begin()
        XCTAssertNil(liveness.startCompleted(now: 0, isRecording: true))
        XCTAssertEqual(liveness.phase, .running)
        XCTAssertFalse(liveness.confirmed)

        XCTAssertTrue(liveness.frame(now: 0.1))
        XCTAssertTrue(liveness.confirmed)
        XCTAssertFalse(liveness.frame(now: 0.2), "only the first frame confirms")
    }

    func test_anEndWhileStartingIsKeptAndComesOutWhenTheStartCompletes() {
        var liveness = ScreenShareLiveness()
        liveness.begin()

        XCTAssertFalse(liveness.end(.error), "nothing to report yet")
        XCTAssertEqual(liveness.phase, .starting)
        XCTAssertFalse(liveness.end(.recorderStopped), "the first reason is kept")

        XCTAssertEqual(liveness.startCompleted(now: 0, isRecording: true), .error)
        XCTAssertEqual(liveness.phase, .ended)
        XCTAssertFalse(liveness.confirmed)
        XCTAssertFalse(liveness.frame(now: 1), "a frame after the end confirms nothing")
    }

    func test_aRecorderThatWasNeverSeenRecordingIsNotJudgedByIt() {
        var liveness = ScreenShareLiveness()
        liveness.begin()
        XCTAssertNil(liveness.startCompleted(now: 0, isRecording: false))
        _ = liveness.frame(now: 0.1)

        XCTAssertNil(liveness.check(now: 0.2, isRecording: false))

        // Once it has been seen recording, it ending is an end.
        XCTAssertNil(liveness.check(now: 0.3, isRecording: true))
        XCTAssertEqual(liveness.check(now: 0.4, isRecording: false), .recorderStopped)
    }

    func test_aRunningCaptureEndsOnceWhateverTheNumberOfSignals() {
        var liveness = ScreenShareLiveness()
        liveness.begin()
        _ = liveness.startCompleted(now: 0, isRecording: true)
        _ = liveness.frame(now: 0.1)

        XCTAssertTrue(liveness.end(.error))
        XCTAssertFalse(liveness.end(.error))
        XCTAssertNil(liveness.check(now: 5, isRecording: false))
        XCTAssertFalse(liveness.confirmed)
    }

    func test_theRecorderNoLongerRecordingEndsTheCapture() {
        var liveness = ScreenShareLiveness()
        liveness.begin()
        _ = liveness.startCompleted(now: 0, isRecording: true)
        _ = liveness.frame(now: 0.1)

        XCTAssertNil(liveness.check(now: 0.2, isRecording: true))
        XCTAssertEqual(liveness.check(now: 0.3, isRecording: false), .recorderStopped)
    }

    func test_aCaptureThatNeverProducesAFrameEndsAfterTheSilenceLimit() {
        var liveness = ScreenShareLiveness()
        liveness.begin()
        _ = liveness.startCompleted(now: 10, isRecording: true)

        XCTAssertNil(liveness.check(now: 10 + ScreenShareLiveness.silenceLimit - 0.1, isRecording: true))
        XCTAssertEqual(liveness.check(now: 10 + ScreenShareLiveness.silenceLimit, isRecording: true),
                       .noFirstFrame)
    }

    func test_silenceWhileTheRecorderRecordsIsNotAnEnd() {
        var liveness = ScreenShareLiveness()
        liveness.begin()
        _ = liveness.startCompleted(now: 0, isRecording: true)
        _ = liveness.frame(now: 0.1)

        // The recorder sends a frame only when the screen changes: a still screen is silent for as long as it stays still.
        XCTAssertNil(liveness.check(now: 600, isRecording: true))
        XCTAssertTrue(liveness.confirmed)
    }

    func test_silenceWithARecorderThatIsNotRecordingEndsTheCapture() {
        var liveness = ScreenShareLiveness()
        liveness.begin()
        _ = liveness.startCompleted(now: 0, isRecording: false)
        _ = liveness.frame(now: 1)

        XCTAssertNil(liveness.check(now: 1 + ScreenShareLiveness.silenceLimit - 0.1, isRecording: false))
        XCTAssertEqual(liveness.check(now: 1 + ScreenShareLiveness.silenceLimit, isRecording: false),
                       .nothingCaptured)
        XCTAssertFalse(liveness.confirmed)
    }

    func test_aFailedStartLeavesNothingBehind() {
        var liveness = ScreenShareLiveness()
        liveness.begin()
        _ = liveness.end(.error)
        liveness.startFailed()
        XCTAssertEqual(liveness.phase, .idle)

        liveness.begin()
        XCTAssertNil(liveness.startCompleted(now: 0, isRecording: true), "the end of the failed start is forgotten")
    }
}

#if os(iOS)
@MainActor
private final class FakeCaptureBackend: ScreenCaptureBackend {
    var isAvailable = true
    var isRecording = false
    var startCalls = 0
    var stopCalls = 0
    /// A recorder that never answers a stop.
    var holdStop = false
    /// The code the recorder answers a stop with.
    var stopErrorCode = 0
    /// A recorder that answers the stop and keeps recording.
    var staysRecordingAfterStop = false
    var onEvent: (@Sendable (ScreenCaptureEvent) -> Void)?
    var completion: (@Sendable (Error?) -> Void)?

    func prepare() {}

    func startCapture(onEvent: @escaping @Sendable (ScreenCaptureEvent) -> Void,
                      completion: @escaping @Sendable (Error?) -> Void) {
        startCalls += 1
        self.onEvent = onEvent
        self.completion = completion
    }

    func stopCapture(completion: @escaping @Sendable (Int) -> Void) {
        stopCalls += 1
        if !staysRecordingAfterStop { isRecording = false }
        if !holdStop { completion(stopErrorCode) }
    }
}

private struct RecorderFailure: Error {}

@MainActor
final class ScreenShareControllerTests: XCTestCase {

    private var backend: FakeCaptureBackend!
    private var clock: TimeInterval = 100
    private var controller: ScreenShareController!
    private var confirmed = 0
    private var ended = 0

    override func setUp() {
        super.setUp()
        backend = FakeCaptureBackend()
        clock = 100
        confirmed = 0
        ended = 0
        controller = ScreenShareController(backend: backend, now: { [unowned self] in self.clock }, stopTimeout: 0.05,
                                           verifyWait: 0.2)
        controller.onConfirmed = { [unowned self] in self.confirmed += 1 }
        controller.onEnded = { [unowned self] in self.ended += 1 }
    }

    override func tearDown() async throws {
        await controller.stop()
        controller = nil
        try await super.tearDown()
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    /// Starts the controller and lets the recorder answer.
    private func startRunning() async throws {
        let started = Task { @MainActor in try await controller.start(into: nil) }
        while backend.completion == nil { await Task.yield() }
        backend.isRecording = true
        backend.completion?(nil)
        try await started.value
    }

    func test_aRunningCaptureIsConfirmedByItsFirstFrame() async throws {
        try await startRunning()
        XCTAssertTrue(controller.isRunning)
        XCTAssertFalse(controller.isConfirmed)

        controller.noteFrame()
        controller.noteFrame()

        XCTAssertTrue(controller.isConfirmed)
        XCTAssertEqual(confirmed, 1)
    }

    func test_anErrorThatArrivesBeforeTheStartCompletesMakesTheStartFail() async throws {
        let started = Task { @MainActor in try await controller.start(into: nil) }
        while backend.completion == nil { await Task.yield() }
        backend.isRecording = true

        backend.onEvent?(.failed(RecorderFailure()))
        await settle()
        backend.completion?(nil)

        do {
            try await started.value
            XCTFail("the start must not succeed after the capture ended")
        } catch let error as ScreenShareController.ScreenShareError {
            guard case .notRunning = error else { return XCTFail("unexpected error \(error)") }
        }
        XCTAssertFalse(controller.isRunning)
        XCTAssertFalse(controller.isConfirmed)
        XCTAssertEqual(ended, 0, "the failed start is the report")
        XCTAssertEqual(backend.stopCalls, 1, "the recorder that did start is stopped")

        // A new start is accepted and starts clean.
        backend.completion = nil
        let again = Task { @MainActor in try await controller.start(into: nil) }
        while backend.completion == nil { await Task.yield() }
        backend.isRecording = true
        backend.completion?(nil)
        try await again.value
        XCTAssertTrue(controller.isRunning)
    }

    func test_aStartThatFailsAtTheRecorderThrowsAndLeavesTheControllerIdle() async {
        let started = Task { @MainActor in try await controller.start(into: nil) }
        while backend.completion == nil { await Task.yield() }
        backend.completion?(RecorderFailure())

        do {
            try await started.value
            XCTFail("the start must fail")
        } catch {}
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(ended, 0)
    }

    func test_theRecorderNoLongerRecordingEndsTheCaptureOnTheNextLook() async throws {
        try await startRunning()
        controller.noteFrame()

        backend.isRecording = false
        controller.tick()
        controller.tick()

        XCTAssertEqual(ended, 1, "reported once")
        XCTAssertFalse(controller.isConfirmed)
    }

    func test_anErrorOfARunningCaptureIsReportedOnce() async throws {
        try await startRunning()
        controller.noteFrame()

        backend.onEvent?(.failed(RecorderFailure()))
        await settle()
        backend.onEvent?(.failed(RecorderFailure()))
        await settle()

        XCTAssertEqual(ended, 1)
        XCTAssertFalse(controller.isConfirmed)
    }

    func test_aCaptureThatNeverGetsAFrameEndsAfterTheSilenceLimit() async throws {
        try await startRunning()

        clock += ScreenShareLiveness.silenceLimit - 0.5
        controller.tick()
        XCTAssertEqual(ended, 0)

        clock += 0.5
        controller.tick()
        XCTAssertEqual(ended, 1)
    }

    func test_aStillScreenKeepsItsShareWhileTheRecorderRecords_andAnotherCaptureDoesNotKeepADeadOne() async throws {
        try await startRunning()
        controller.noteFrame()

        clock += 600
        controller.tick()
        XCTAssertEqual(ended, 0, "no frame, but the recorder is recording")
        XCTAssertTrue(controller.isConfirmed)

        // Another recording or mirror may keep the screen captured; it does not matter to our share.
        backend.isRecording = false
        controller.tick()
        XCTAssertEqual(ended, 1)
        XCTAssertFalse(controller.isConfirmed)
    }

    func test_stopAfterAnEndTearsTheCaptureDownEvenIfTheRecorderNeverAnswers() async throws {
        try await startRunning()
        controller.noteFrame()
        backend.isRecording = false
        controller.tick()
        XCTAssertEqual(ended, 1)
        backend.holdStop = true

        await controller.stop()

        XCTAssertEqual(backend.stopCalls, 1)
        XCTAssertFalse(controller.isRunning)
        XCTAssertFalse(controller.isConfirmed)
    }

    func test_stopStopsARunningRecorder_andNothingIsReportedAfterIt() async throws {
        try await startRunning()
        controller.noteFrame()

        await controller.stop()

        XCTAssertEqual(backend.stopCalls, 1)
        XCTAssertFalse(controller.isConfirmed)
        controller.noteFrame()
        controller.captureEnded(.error)
        controller.tick()
        XCTAssertEqual(ended, 0)
        XCTAssertEqual(confirmed, 1)
    }

    func test_aNewStartIsAcceptedAfterAnEndThatWasNotTornDown() async throws {
        try await startRunning()
        controller.noteFrame()
        backend.isRecording = false
        controller.tick()
        XCTAssertEqual(ended, 1)

        backend.completion = nil
        try await startRunning()

        XCTAssertTrue(controller.isRunning)
        XCTAssertFalse(controller.isConfirmed, "the new capture has to be confirmed by its own frame")
    }

    // MARK: - What the system answered to a stop

    func test_stopReportsWhatTheRecorderAnswered() async throws {
        try await startRunning()
        backend.stopErrorCode = -5801

        let report = await controller.stop()

        XCTAssertEqual(report, ScreenCaptureStopReport(errorCode: -5801, stillCapturing: false))
        XCTAssertEqual(controller.lastStopReport, report)
    }

    func test_stopReportsARecorderThatStillRecordsAfterTheStop() async throws {
        try await startRunning()
        backend.staysRecordingAfterStop = true

        let report = await controller.stop()

        XCTAssertEqual(report?.stillCapturing, true)
        XCTAssertFalse(controller.isRunning, "the controller is idle whatever the recorder says")
    }

    func test_aRecorderThatNeverAnswersTheStopIsReportedAsUnanswered() async throws {
        try await startRunning()
        backend.holdStop = true

        let report = await controller.stop()

        XCTAssertEqual(report?.errorCode, ScreenShareController.unansweredStopCode)
    }

    func test_theErrorThatEndedTheCaptureIsInTheStopReport() async throws {
        try await startRunning()
        controller.noteFrame()
        controller.captureEnded(.error, code: -3)
        XCTAssertEqual(ended, 1)

        let report = await controller.stop()

        XCTAssertEqual(report?.errorCode, -3)
    }

    func test_stopOfACaptureThatIsNotRunningIsNilAndAsksNothing() async {
        let report = await controller.stop()
        XCTAssertNil(report)
        XCTAssertEqual(backend.stopCalls, 0)
    }

    func test_aSecondStopDoesNotAskTheRecorderAgain() async throws {
        try await startRunning()
        _ = await controller.stop()
        let second = await controller.stop()
        XCTAssertNil(second)
        XCTAssertEqual(backend.stopCalls, 1)
    }

    // MARK: - Frames

    private func makeSample() throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: try XCTUnwrap(pixelBuffer),
                                                     formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: 1, timescale: 30),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: try XCTUnwrap(pixelBuffer),
                                                 formatDescription: try XCTUnwrap(format), sampleTiming: &timing,
                                                 sampleBufferOut: &sample)
        return try XCTUnwrap(sample)
    }

    func test_framesReachTheSinkWhileRunningAndNoFrameReachesItAfterTheStop() async throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func add() { lock.lock(); value += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        }
        let counter = Counter()
        controller.onFrame = { _, _ in counter.add() }
        try await startRunning()

        backend.onEvent?(.video(try makeSample()))
        XCTAssertEqual(counter.count, 1)

        await controller.stop()
        backend.onEvent?(.video(try makeSample()))
        await settle()

        XCTAssertEqual(counter.count, 1, "a frame that arrives after the stop goes nowhere")
    }

    // MARK: - OS versions that use the system capture

    func test_theInAppRecorderIsNeverStartedFromIos27() async {
        let guarded = ScreenShareController(backend: backend, now: { 0 }, stopTimeout: 0.05, verifyWait: 0.05, osMajor: 27)
        do {
            try await guarded.start(into: nil)
            XCTFail("the recorder of the app must not start on iOS 27")
        } catch let error as ScreenShareController.ScreenShareError {
            guard case .recorderUnavailable = error else { return XCTFail("unexpected error \(error)") }
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(backend.startCalls, 0)
    }
}
#endif

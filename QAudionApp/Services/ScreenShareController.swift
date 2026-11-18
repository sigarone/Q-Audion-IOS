#if os(iOS)
import Foundation
import ReplayKit
import UIKit
import CoreMedia
import CoreVideo
import QAudionEngine
import os

/// What the controller reads from the system recorder, kept apart so a test can drive the controller without ReplayKit.
@MainActor
protocol ScreenCaptureBackend: AnyObject {
    var isAvailable: Bool { get }
    var isRecording: Bool { get }
    /// Video samples only, no microphone and no camera.
    func prepare()
    /// Starts the capture. `onEvent` runs on the recorder's own queue for every video sample and for every error;
    /// `completion` runs once the start has been answered.
    func startCapture(onEvent: @escaping @Sendable (ScreenCaptureEvent) -> Void,
                      completion: @escaping @Sendable (Error?) -> Void)
    /// Stops the capture. `completion` runs once the stop has been answered, with the code of the error the system
    /// answered with (0 when it answered without one).
    func stopCapture(completion: @escaping @Sendable (Int) -> Void)
}

enum ScreenCaptureEvent {
    case video(CMSampleBuffer)
    case failed(Error)
}

/// The system recorder.
@MainActor
final class RPScreenRecorderBackend: ScreenCaptureBackend {
    var isAvailable: Bool { RPScreenRecorder.shared().isAvailable }
    var isRecording: Bool { RPScreenRecorder.shared().isRecording }

    func prepare() {
        let recorder = RPScreenRecorder.shared()
        // The microphone hook is off: only video frames are wanted here. Audio for the call flows through the call's
        // audio session, independent of ReplayKit. The camera preview overlay stays off too.
        recorder.isMicrophoneEnabled = false
        recorder.isCameraEnabled = false
    }

    func startCapture(onEvent: @escaping @Sendable (ScreenCaptureEvent) -> Void,
                      completion: @escaping @Sendable (Error?) -> Void) {
        RPScreenRecorder.shared().startCapture(
            handler: { sampleBuffer, bufferType, error in
                if let error = error {
                    onEvent(.failed(error))
                    return
                }
                // Only the video frames matter; audio sample buffers that slip through are ignored.
                guard bufferType == .video else { return }
                onEvent(.video(sampleBuffer))
            },
            completionHandler: { error in completion(error) }
        )
    }

    func stopCapture(completion: @escaping @Sendable (Int) -> Void) {
        RPScreenRecorder.shared().stopCapture(handler: { error in completion(ScreenShareLifecycle.errorCode(error)) })
    }
}

/// W533 — In-app screen capture via ReplayKit's `RPScreenRecorder`,
/// piped into the existing WebRTC video sender used by camera calls.
///
/// ## Design choice — RPScreenRecorder vs RPBroadcastSampleHandler
///
/// `RPScreenRecorder` (this class) captures the **app's own screen
/// only** and runs in-process — no broadcast extension target
/// required, no per-frame XPC overhead, no system-wide capture
/// permission prompt. This is the equivalent of Chrome's
/// `getDisplayMedia` constrained to the page's own viewport, which is
/// what `qaudion-desktop` uses on the renderer side.
///
/// The alternative — a `RPBroadcastSampleHandler` extension —
/// captures the entire iOS device (across apps) but requires:
///   1. a separate App Group + Broadcast Upload Extension target
///   2. XPC + shared memory plumbing to relay CMSampleBuffer
///      between the extension and the host app
///   3. a system "Start Broadcast" UI flow
///   4. a higher TestFlight review surface (extensions have stricter
///      bundle-id / entitlement constraints)
///
/// For the v1 cross-platform parity sprint we ship in-app capture.
/// A broadcast extension can layer on later without changing the
/// receiver side because both produce CMSampleBuffer with a
/// CVPixelBuffer — the bridge to WebRTC is identical.
///
/// ## Cross-platform reception
///
/// Frames flow as standard WebRTC video RTP through the existing
/// `QAudionWebRtcCallController.webrtcPixelBufferCapturer`. Desktop
/// (`qaudion-desktop` PeerConnectionManager) and Android render it as a
/// normal remote video track — they don't need to know it's a screen
/// instead of a camera. A future "screen-share started" opaque-
/// message signal (W534) can add the explicit badge.
///
/// ## Lifecycle
///
/// 1. AppState.startScreenShare() → ScreenShareController.start(into:)
/// 2. RPScreenRecorder.shared().startCapture(handler:) → CMSampleBuffer
///    arrives on RPScreenRecorder's background queue.
/// 3. Each sample: extract CVPixelBuffer, derive timestamp in ns,
///    push to the WebRTCPixelBufferCapturer the controller exposes.
///    Camera frames stop because AppState rewires
///    `VideoCallPipeline.onCapturedPixelBuffer` to a no-op closure
///    for the duration of the share (avoiding two writers racing
///    into the same RTCVideoSource).
/// 4. AppState.stopScreenShare() → ScreenShareController.stop() +
///    restore the camera-frame closure.
///
/// The capture is confirmed when its first frame arrives (`onConfirmed`). A capture that ends on its own is reported
/// once (`onEnded`), or makes `start` throw when it ends while it is starting. `ScreenShareLiveness` holds the rules.
@MainActor
public final class ScreenShareController: ScreenFrameSource {

    public enum ScreenShareError: Error, LocalizedError {
        case recorderUnavailable
        case alreadyRunning
        case captureFailed(Error)
        case notRunning

        public var errorDescription: String? {
            switch self {
            case .recorderUnavailable:
                return String(localized: "call.screenshare.error.recorder_unavailable", defaultValue: "Cattura schermo non disponibile su questo dispositivo.", comment: "Error when the system screen recorder is not available on this device.")
            case .alreadyRunning:
                return String(localized: "call.screenshare.error.already_active", defaultValue: "La condivisione schermo è già attiva.", comment: "Error when screen sharing is started while it is already running.")
            case .captureFailed(let err):
                return String(localized: "call.screenshare.error.capture_failed", defaultValue: "Avvio cattura schermo fallito: \(err.localizedDescription)", comment: "Error when screen capture could not be started. %@ is the technical reason.")
            case .notRunning:
                return String(localized: "call.screenshare.error.not_active", defaultValue: "La condivisione schermo non è attiva.", comment: "Error when screen sharing is stopped while it is not running.")
            }
        }
    }

    var kind: ScreenFrameSourceKind { .inApp }

    /// True when an active capture is sending frames to the sink.
    public var isRunning: Bool { liveness.phase == .running }

    /// True once the running capture has delivered its first frame.
    public var isConfirmed: Bool { liveness.phase == .running && liveness.confirmed }

    /// The two places a frame goes: the WebRTC capturer (held weakly, the call owns it) and the WS-HEVC sink that
    /// AppState points at `VideoCallPipeline.submitExternalFrame` so an audio-only screen share reaches iOS peers too.
    /// Frames arrive on RPScreenRecorder's private capture queue while AppState sets the sink from the main actor,
    /// so both places and the closed flag sit under one lock, and a frame that arrives after a stop goes nowhere.
    private let sink = ScreenFrameSink()

    /// `nonisolated` because the sink's lock is the synchronization: the capture queue must not be forced through a
    /// main actor hop.
    public nonisolated var onFrame: ((CVPixelBuffer, Int64) -> Void)? {
        get { sink.onFrame }
        set { sink.onFrame = newValue }
    }

    /// First sample timestamp anchor — used to produce monotonically
    /// increasing nanosecond timestamps relative to the start of the
    /// share. WebRTC accepts arbitrary monotonic values; we just
    /// pick one that won't wrap or clash with Date()-based ones.
    private var startReferenceCmTime: CMTime?

    /// Called once, on the main actor, when the running capture ends without a call to `stop()`: ReplayKit reported an
    /// error, the system recorder is no longer recording (the user ended it from the system), or nothing captures the
    /// screen any more. A capture that ends while it is still starting makes `start` throw instead. Cleared by `stop()`.
    public var onEnded: (() -> Void)?

    /// Called once, on the main actor, when the first frame of the running capture has arrived. Cleared by `stop()`.
    public var onConfirmed: (() -> Void)?

    private let backend: ScreenCaptureBackend
    private let now: () -> TimeInterval
    /// The longest the recorder is waited for when it is asked to stop.
    private let stopTimeout: TimeInterval
    /// How long, after the recorder answered a stop, it is looked at to see that it is no longer recording.
    private let verifyWait: TimeInterval
    /// The OS major version that decides whether the in-app recorder may be used at all; 0 for no limit (a test).
    private let osMajor: Int
    private var liveness = ScreenShareLiveness()
    private var tickTimer: Timer?
    private var isStopping = false
    /// The code of the error that ended the capture without a stop from the app, 0 when there was none.
    private var endErrorCode = 0
    private(set) var lastStopReport: ScreenCaptureStopReport?

    /// How often the recorder is looked at while the capture runs.
    private static let tickInterval: TimeInterval = 0.25

    /// The answer recorded for a stop that the recorder never answered.
    static let unansweredStopCode = -2

    public convenience init() {
        self.init(backend: RPScreenRecorderBackend(), now: { ProcessInfo.processInfo.systemUptime },
                  osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    init(backend: ScreenCaptureBackend, now: @escaping () -> TimeInterval, stopTimeout: TimeInterval = 2,
         verifyWait: TimeInterval = 0.6, osMajor: Int = 0) {
        self.backend = backend
        self.now = now
        self.stopTimeout = stopTimeout
        self.verifyWait = verifyWait
        self.osMajor = osMajor
    }

    /// Start streaming the in-app screen into the given WebRTC
    /// capturer (nil on the iOS↔iOS WS-relay path — frames then flow
    /// only through [onFrame]). Returns once `startCapture` has
    /// succeeded (the handler closure is called per-frame from then on).
    /// Throws `.alreadyRunning`, `.recorderUnavailable`, or
    /// `.captureFailed` on the documented failure modes, and `.notRunning`
    /// when the capture ended while it was starting.
    public func start(into capturer: WebRTCPixelBufferCapturer?) async throws {
        if liveness.isActive || isStopping { throw ScreenShareError.alreadyRunning }
        // From iOS 27 the share uses the system capture; the recorder of the app is not used there.
        if osMajor >= ScreenShareLifecycle.systemCaptureMajor { throw ScreenShareError.recorderUnavailable }
        guard backend.isAvailable else {
            throw ScreenShareError.recorderUnavailable
        }
        backend.prepare()
        // What an earlier capture that ended on its own left behind.
        removeWatchers()

        sink.open(capturer: capturer)
        startReferenceCmTime = nil
        endErrorCode = 0
        lastStopReport = nil
        liveness.begin()

        // RPScreenRecorder.startCapture is callback-based and not
        // async/await native — bridge via a continuation. The
        // event handler runs on a private serial queue for every frame
        // and for every error.
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                backend.startCapture(
                    onEvent: { [weak self] event in
                        switch event {
                        case .failed(let error):
                            // Frame-level error from the capture pipeline.
                            // RPScreenRecorder also signals end-of-capture
                            // via this callback when the user revokes
                            // permission mid-stream.
                            print("[ScreenShareController] frame error: \(error.localizedDescription)")
                            let code = ScreenShareLifecycle.errorCode(error)
                            Task { @MainActor [weak self] in self?.captureEnded(.error, code: code) }
                        case .video(let sampleBuffer):
                            self?.dispatchVideoSample(sampleBuffer)
                        }
                    },
                    completion: { error in
                        if let error = error {
                            cont.resume(throwing: ScreenShareError.captureFailed(error))
                        } else {
                            cont.resume(returning: ())
                        }
                    }
                )
            }
        } catch {
            liveness.startFailed()
            sink.close()
            throw error
        }
        // An end that arrived while the capture was starting stops it here: the caller never sees a running capture.
        if liveness.startCompleted(now: now(), isRecording: backend.isRecording) != nil {
            _ = await windDown()
            throw ScreenShareError.notRunning
        }
        watchCapture()
        print("[ScreenShareController] capture started — frames flowing into WebRTC")
    }

    /// Stops the capture and returns what the recorder answered and whether it still reports recording afterwards.
    /// Nil when nothing was capturing.
    @discardableResult
    func stop() async -> ScreenCaptureStopReport? {
        guard liveness.phase == .running || liveness.phase == .ended, !isStopping else { return nil }
        isStopping = true
        defer { isStopping = false }
        onEnded = nil
        onConfirmed = nil
        let report = await windDown()
        print("[ScreenShareController] capture stopped — restoring camera path")
        return report
    }

    // MARK: - Private

    /// Tears the capture down. The state goes back to idle and the sink is closed first, so nothing is confirmed,
    /// reported or delivered from here on. stopCapture is callback-based; bridge similarly. The wait for its answer is
    /// bounded, and the controller flips to idle whatever the recorder answers, so AppState can re-wire the camera
    /// closure. The recorder is looked at afterwards: a recorder that still reports recording is part of the answer.
    private func windDown() async -> ScreenCaptureStopReport {
        removeWatchers()
        liveness.reset()
        sink.close()
        let code = await stopRecorder()
        let still = await recorderStillRecording()
        startReferenceCmTime = nil
        let report = ScreenCaptureStopReport(errorCode: code != 0 ? code : endErrorCode, stillCapturing: still)
        lastStopReport = report
        return report
    }

    /// Asks the recorder to stop and waits for its answer, at most `stopTimeout`. Returns the code the recorder
    /// answered with, or `unansweredStopCode` when it did not answer in time.
    private func stopRecorder() async -> Int {
        let answer = OSAllocatedUnfairLock<Int?>(initialState: nil)
        let limit = stopTimeout
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let finish: @Sendable (Int) -> Void = { code in
                let first = answer.withLock { value -> Bool in
                    if value != nil { return false }
                    value = code
                    return true
                }
                if first { cont.resume(returning: ()) }
            }
            backend.stopCapture(completion: finish)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                finish(Self.unansweredStopCode)
            }
        }
        return answer.withLock { $0 } ?? Self.unansweredStopCode
    }

    /// Whether the recorder still reports recording after the stop, looked at for at most `verifyWait`.
    private func recorderStillRecording() async -> Bool {
        var waited: TimeInterval = 0
        while backend.isRecording, waited < verifyWait {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        return backend.isRecording
    }

    /// While the capture runs, the recorder is looked at on a short timer.
    private func watchCapture() {
        removeWatchers()
        tickTimer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func removeWatchers() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    /// One look at the recorder. Internal so a test can drive it with a clock of its own.
    func tick() {
        guard liveness.check(now: now(), isRecording: backend.isRecording) != nil else { return }
        reportEnd()
    }

    /// The recorder reported that the capture is over.
    func captureEnded(_ reason: ScreenShareLiveness.EndReason, code: Int = 0) {
        if endErrorCode == 0 { endErrorCode = code }
        guard liveness.end(reason) else { return }
        reportEnd()
    }

    /// A video sample arrived; the first one of the capture confirms it.
    func noteFrame() {
        guard liveness.frame(now: now()) else { return }
        onConfirmed?()
    }

    /// A running capture is over: the watchers stop and the owner is told once. The capture itself is torn down by
    /// the owner's `stop()`.
    private func reportEnd() {
        removeWatchers()
        onEnded?()
    }

    /// Extract the CVPixelBuffer and timestamp from a CMSampleBuffer and hand them to the sink. Runs on
    /// RPScreenRecorder's private queue: the sink takes its own lock and `WebRTCPixelBufferCapturer.push` is
    /// thread-safe, so there is no hop to the main actor for the frame. Only the liveness note goes to the main actor.
    private nonisolated func dispatchVideoSample(_ sample: CMSampleBuffer) {
        guard CMSampleBufferIsValid(sample),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sample)
        else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let nanos: Int64 = Int64(CMTimeGetSeconds(pts) * 1_000_000_000)
        guard sink.deliver(pixelBuffer, timestampNs: nanos) else { return }
        Task { @MainActor [weak self] in self?.noteFrame() }
    }
}
#endif

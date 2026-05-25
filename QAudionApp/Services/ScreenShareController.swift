#if os(iOS)
import Foundation
import ReplayKit
import CoreMedia
import CoreVideo
import QAudionEngine

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
/// (`qaudion-desktop` PeerConnectionManager) and Android
/// (`qaudion-android-new` PeerConnectionHolder) render it as a
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
@MainActor
public final class ScreenShareController {

    public enum ScreenShareError: Error, LocalizedError {
        case recorderUnavailable
        case alreadyRunning
        case captureFailed(Error)
        case notRunning

        public var errorDescription: String? {
            switch self {
            case .recorderUnavailable:
                return "Cattura schermo non disponibile su questo dispositivo."
            case .alreadyRunning:
                return "La condivisione schermo è già attiva."
            case .captureFailed(let err):
                return "Avvio cattura schermo fallito: \(err.localizedDescription)"
            case .notRunning:
                return "La condivisione schermo non è attiva."
            }
        }
    }

    /// True when an active capture is sending frames to `targetCapturer`.
    public private(set) var isRunning: Bool = false

    /// Weak so the controller doesn't extend the lifetime of the
    /// WebRTC capturer (which is owned by the QAudionWebRtcCallController).
    private weak var targetCapturer: WebRTCPixelBufferCapturer?

    /// First sample timestamp anchor — used to produce monotonically
    /// increasing nanosecond timestamps relative to the start of the
    /// share. WebRTC accepts arbitrary monotonic values; we just
    /// pick one that won't wrap or clash with Date()-based ones.
    private var startReferenceCmTime: CMTime?

    public init() {}

    /// Start streaming the in-app screen into the given WebRTC
    /// capturer. Returns once `startCapture` has succeeded (the
    /// handler closure is called per-frame from then on).
    /// Throws `.alreadyRunning`, `.recorderUnavailable`, or
    /// `.captureFailed` on the documented failure modes.
    public func start(into capturer: WebRTCPixelBufferCapturer) async throws {
        if isRunning { throw ScreenShareError.alreadyRunning }
        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else {
            throw ScreenShareError.recorderUnavailable
        }
        // The shared recorder's microphone hook is OFF — we want only
        // video frames here. Audio for the call still flows through
        // CallService's AVAudioSession independent of ReplayKit.
        recorder.isMicrophoneEnabled = false
        // Don't show the camera preview overlay either.
        recorder.isCameraEnabled = false

        targetCapturer = capturer
        startReferenceCmTime = nil

        // RPScreenRecorder.startCapture is callback-based and not
        // async/await native — bridge via a continuation. The
        // `handler` runs on a private serial queue for every frame
        // and (optionally) for audio samples we don't request.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            recorder.startCapture(
                handler: { [weak self] sampleBuffer, bufferType, error in
                    if let error = error {
                        // Frame-level error from the capture pipeline.
                        // RPScreenRecorder also signals end-of-capture
                        // via this callback when the user revokes
                        // permission mid-stream.
                        print("[ScreenShareController] frame error: \(error.localizedDescription)")
                        return
                    }
                    // We only care about the video frames — ignore any
                    // mic / app audio sample buffers if they slip
                    // through (microphone is disabled above but the
                    // RPSampleBufferType.audioApp may still ship in
                    // rare cases on iOS 16).
                    guard bufferType == .video else { return }
                    self?.dispatchVideoSample(sampleBuffer)
                },
                completionHandler: { error in
                    if let error = error {
                        cont.resume(throwing: ScreenShareError.captureFailed(error))
                    } else {
                        cont.resume(returning: ())
                    }
                }
            )
        }
        isRunning = true
        print("[ScreenShareController] capture started — frames flowing into WebRTC")
    }

    public func stop() async {
        guard isRunning else { return }
        let recorder = RPScreenRecorder.shared()
        // stopCapture is also callback-based; bridge similarly. We
        // ignore the discarded completion error because failure here
        // means "ReplayKit couldn't stop cleanly", which doesn't
        // unblock the UI restoration — the controller still flips
        // isRunning to false so AppState can re-wire the camera
        // closure.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            recorder.stopCapture(handler: { _ in
                cont.resume(returning: ())
            })
        }
        targetCapturer = nil
        startReferenceCmTime = nil
        isRunning = false
        print("[ScreenShareController] capture stopped — restoring camera path")
    }

    // MARK: - Private

    /// Extract the CVPixelBuffer and timestamp from a CMSampleBuffer
    /// and push to the WebRTC capturer. Runs on RPScreenRecorder's
    /// private queue — `WebRTCPixelBufferCapturer.push` is documented
    /// thread-safe so we don't bounce to MainActor.
    private nonisolated func dispatchVideoSample(_ sample: CMSampleBuffer) {
        guard CMSampleBufferIsValid(sample),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sample)
        else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let nanos: Int64 = Int64(CMTimeGetSeconds(pts) * 1_000_000_000)
        // Hop a read of `targetCapturer` through the actor — this is
        // safe because the property is set only on MainActor and only
        // before/after capture lifecycle transitions. We deliberately
        // tolerate a frame-dropped race in the stop() path.
        Task { @MainActor [weak self] in
            guard let cap = self?.targetCapturer else { return }
            cap.push(pixelBuffer, rotation: ._0, timestampNs: nanos)
        }
    }
}
#endif

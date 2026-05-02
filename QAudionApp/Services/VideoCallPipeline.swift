import Foundation
import AVFoundation
import CoreVideo
import CoreMedia
import CoreImage
import QAudionEngine
#if canImport(UIKit)
import UIKit
#endif

/// W391 — End-to-end video pipeline for 1:1 video calls.
///
/// Closes the "video call media: UI presente ma backend stubbed" gap
/// from PARITY_AUDIT_HONEST.md. This is the iOS-app-side orchestrator
/// that wires together the engine's existing pieces:
///
/// **Outbound (TX):**
///   1. AVCaptureSession (this file) pulls front-camera frames at
///      720p/30fps → CMSampleBuffer.
///   2. CVPixelBuffer extracted → fed to HevcEncoder (engine).
///   3. HevcEncoder.onNal callback → VideoFrameFragmenter.fragment.
///   4. Each fragment is published to `onOutboundFragment` so the
///      transport (BcryptoWsRelay sealed-frame today, RTCVideoSource
///      once the WebRTC binary exposes insertable streams) can ship
///      it to the peer.
///
/// **Inbound (RX):**
///   1. Transport delivers a fragment payload via `acceptInboundFragment`.
///   2. VideoFrameFragmenter.defragment reassembles the NAL.
///   3. HevcDecoder (engine) produces a CVPixelBuffer.
///   4. CVPixelBuffer is published via `onDecodedFrame` so the UI can
///      render it (CIImage → UIImage → SwiftUI `Image`, OR
///      AVSampleBufferDisplayLayer for low-overhead display).
///
/// **WebRTC binary constraint:** the stasel/WebRTC 131.0.0 binary
/// strips the insertable-streams API (W386) so we can't directly
/// install our HEVC encoder/decoder pair into RTCVideoSource /
/// RTCVideoRenderer. The pipeline therefore runs over the
/// BcryptoWsRelay sealed-frame transport (W376) where each fragment
/// is PQC-sealed via `PqcRtpFrameSealer` before transit. When the
/// binary upgrade lands, the same engine pieces plug into the
/// RTCVideoCapturer / RTCVideoRenderer protocol pair without
/// further changes.
@MainActor
public final class VideoCallPipeline: NSObject {

    // MARK: - Public surface

    public typealias FragmentCallback = (Data) -> Void
    public typealias FrameCallback = (CVPixelBuffer) -> Void

    /// Fired once per outbound fragment, on a non-main queue. The
    /// transport must be reentrant.
    /// `nonisolated(unsafe)` — the encoder's VideoToolbox callback
    /// thread invokes this; we never expose mutation from MainActor
    /// after start().
    public nonisolated(unsafe) var onOutboundFragment: FragmentCallback?

    /// Fired once per decoded inbound frame, on a non-main queue. The
    /// UI bridge must hop to MainActor before touching SwiftUI state.
    public nonisolated(unsafe) var onDecodedFrame: FrameCallback?

    /// Camera position. Default front-facing for video calls.
    public var cameraPosition: AVCaptureDevice.Position = .front

    /// Target dimensions / fps. Defaults match VideoConstants engine
    /// numbers so cross-platform interop is symmetrical.
    /// `nonisolated(unsafe)` so the AVCapture / VT callback closures
    /// can read the bitrate without a MainActor hop on every frame.
    /// Configure these BEFORE calling `start()`.
    public nonisolated(unsafe) var targetWidth: Int = VideoConstants.defaultVideoWidth
    public nonisolated(unsafe) var targetHeight: Int = VideoConstants.defaultVideoHeight
    public nonisolated(unsafe) var targetFps: Int = VideoConstants.defaultVideoFps
    public nonisolated(unsafe) var targetBitrateBps: Int = VideoConstants.defaultVideoBitrateBps

    // MARK: - Private state

    /// Public accessor: SwiftUI bridge views (LocalCameraPreview)
    /// attach this to AVCaptureVideoPreviewLayer.
    public let captureSession = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "qaudion.video.capture")
    private let videoOutput = AVCaptureVideoDataOutput()
    private var captureInput: AVCaptureDeviceInput?

    // The engine pieces below are internally thread-safe (their own
    // NSLocks + VideoToolbox session locking). Marking them
    // `nonisolated(unsafe)` lets the AVCapture queue (encoder.encode),
    // the VT decoder thread (decoder.onPixelBuffer), and the WS
    // transport thread (acceptInboundFragment) drive them without a
    // MainActor hop on every frame.
    private nonisolated(unsafe) let encoder = HevcEncoder()
    private nonisolated(unsafe) let decoder = HevcDecoder()
    private nonisolated(unsafe) let outboundFragmenter = VideoFrameFragmenter()
    private nonisolated(unsafe) let inboundFragmenter = VideoFrameFragmenter()

    private var isRunning: Bool = false
    /// Periodic purge timer for stale incomplete inbound frames.
    private var purgeTimer: DispatchSourceTimer?

    // MARK: - Lifecycle

    public override init() {
        super.init()
        wireEngineCallbacks()
    }

    deinit {
        // We can't touch @MainActor state from deinit — assume the
        // caller invoked stop() before releasing.
    }

    /// Start camera + encoder. Throws if AVCaptureSession can't open
    /// the camera (permission denied, simulator without camera, etc.)
    public func start() async throws {
        guard !isRunning else { return }
        try await ensurePermission()
        try setupSession()
        try encoder.start()
        captureSession.startRunning()
        startPurgeTimer()
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        captureSession.stopRunning()
        encoder.invalidate()
        decoder.invalidate()
        outboundFragmenter.reset()
        inboundFragmenter.reset()
        purgeTimer?.cancel()
        purgeTimer = nil
        isRunning = false
    }

    /// Inbound fragment arrival point for the transport layer to call.
    /// Reentrant-safe; fragmenter has its own lock.
    public nonisolated func acceptInboundFragment(_ payload: Data) {
        // Defragment + decode; both have their own locks.
        // Note: this is `nonisolated` so the WS / sealed-frame
        // transport can call it without hopping to MainActor first
        // (tight TX/RX loop budget).
        if let frame = inboundFragmenter.defragment(payload) {
            do {
                try decoder.decode(frame.nalUnit)
            } catch {
                print("[VideoCallPipeline] inbound decode failed: \(error)")
            }
        }
    }

    // MARK: - AVCaptureSession setup

    private func ensurePermission() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            return
        case .notDetermined:
            let ok = await AVCaptureDevice.requestAccess(for: .video)
            if !ok { throw PipelineError.permissionDenied }
        default:
            throw PipelineError.permissionDenied
        }
    }

    private func setupSession() throws {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .hd1280x720

        // Drop any existing inputs/outputs (idempotent).
        captureSession.inputs.forEach { captureSession.removeInput($0) }
        captureSession.outputs.forEach { captureSession.removeOutput($0) }

        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: cameraPosition)
        else {
            captureSession.commitConfiguration()
            throw PipelineError.cameraUnavailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input) else {
            captureSession.commitConfiguration()
            throw PipelineError.cameraUnavailable
        }
        captureSession.addInput(input)
        captureInput = input

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
        guard captureSession.canAddOutput(videoOutput) else {
            captureSession.commitConfiguration()
            throw PipelineError.outputAttachFailed
        }
        captureSession.addOutput(videoOutput)
        captureSession.commitConfiguration()
    }

    private func wireEngineCallbacks() {
        encoder.onNal = { [weak self] nal, isKeyFrame in
            guard let self = self else { return }
            // Fragment the NAL and ship each chunk to the transport.
            // Both fragmenter and the transport callback are reentrant.
            let fragments = self.outboundFragmenter.fragment(
                nalUnit: nal,
                isKeyFrame: isKeyFrame,
                bitrateKbps: self.targetBitrateBps / 1000)
            for f in fragments {
                self.onOutboundFragment?(f)
            }
        }
        decoder.onPixelBuffer = { [weak self] pb, _ in
            self?.onDecodedFrame?(pb)
        }
    }

    private func startPurgeTimer() {
        // Fire every 100ms to evict incomplete inbound frames whose
        // missing fragments never arrived.
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            _ = self?.inboundFragmenter.purgeStaleFrames()
        }
        timer.resume()
        purgeTimer = timer
    }

    // MARK: - Errors

    public enum PipelineError: Error, LocalizedError {
        case permissionDenied
        case cameraUnavailable
        case outputAttachFailed

        public var errorDescription: String? {
            switch self {
            case .permissionDenied:    return "Permesso fotocamera negato"
            case .cameraUnavailable:   return "Fotocamera non disponibile"
            case .outputAttachFailed:  return "Impossibile collegare l'output video"
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension VideoCallPipeline: AVCaptureVideoDataOutputSampleBufferDelegate {
    public nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ns = UInt64(CMTimeGetSeconds(pts) * 1_000_000_000)
        // Encode on the capture queue so we don't bounce threads
        // unnecessarily. The encoder uses VTCompressionSession internally
        // which is thread-safe per session; our `lock` in HevcEncoder
        // guards `frameIndex` updates.
        do {
            try self.encoder.encode(pixelBuffer: pixelBuffer, presentationTimeNs: ns)
        } catch {
            print("[VideoCallPipeline] encode failed: \(error)")
        }
    }
}

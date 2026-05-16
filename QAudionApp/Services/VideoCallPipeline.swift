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

    /// Fired once per raw captured frame BEFORE HEVC encoding, on the
    /// capture queue. Used by AppState to push CVPixelBuffers into the
    /// WebRTC RTCVideoSource for Android interop (Android decodes the
    /// WebRTC RTP track; it doesn't receive BCrypto WS HEVC fragments).
    /// Timestamp is nanoseconds (Int64, compatible with RTCVideoFrame).
    /// `nonisolated(unsafe)` — written from MainActor at setup time,
    /// read from the capture queue per-frame.
    public nonisolated(unsafe) var onCapturedPixelBuffer: ((CVPixelBuffer, Int64) -> Void)?

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
    // NSLocks + VideoToolbox session locking). Each declares
    // `@unchecked Sendable` upstream, so a `let` here is implicitly
    // safe to read from any isolation context — Swift 6 / Xcode 26.4
    // strict mode flags `nonisolated(unsafe)` on Sendable lets as
    // unnecessary (and the build promotes that diagnostic to an
    // error). W401: dropped the annotation.
    private let encoder = HevcEncoder()
    private let decoder = HevcDecoder()
    private let outboundFragmenter = VideoFrameFragmenter()
    private let inboundFragmenter = VideoFrameFragmenter()

    #if canImport(WebRTC)
    /// W394 — current PQC sealer for the video transport. AppState
    /// rotates this when CallSessionKeyBroker fires sasReadyNotification
    /// (i.e. the W389 ML-KEM secret arrives). The closure captures
    /// `self` weakly and reads this property on every fragment so
    /// rekey is observed without rewiring callbacks. Lock-protected
    /// because rotate() is called from MainActor while seal()/open()
    /// run from the encoder/transport queues.
    private nonisolated(unsafe) var pqcEncryptor: PqcFrameEncryptor?
    private nonisolated(unsafe) var pqcDecryptor: PqcFrameDecryptor?
    private let sealerLock = NSLock()
    #endif

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
        // Drop the WebRTC bridge callback before stopping the session so
        // no frames are pushed to a deallocated RTCVideoSource after teardown.
        onCapturedPixelBuffer = nil
        captureSession.stopRunning()
        encoder.invalidate()
        decoder.invalidate()
        outboundFragmenter.reset()
        inboundFragmenter.reset()
        purgeTimer?.cancel()
        purgeTimer = nil
        isRunning = false
    }

    /// W393: flip front ↔ rear camera mid-call. Reconfigures the
    /// AVCaptureSession in a single beginConfiguration/commitConfiguration
    /// transaction so the user only sees a brief freeze, not a full
    /// teardown. No-op if no other camera is available.
    public func flipCamera() {
        let target: AVCaptureDevice.Position = (cameraPosition == .front) ? .back : .front
        guard AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: target) != nil
        else {
            print("[VideoCallPipeline] flipCamera: no \(target == .back ? "rear" : "front") camera available")
            return
        }
        cameraPosition = target
        // Re-run setup. Idempotent: removes existing input, adds the
        // new one. The encoder + fragmenter state survives.
        do {
            try setupSession()
        } catch {
            print("[VideoCallPipeline] flipCamera setup failed: \(error)")
        }
    }

    /// W393: pause / resume the capture pipeline without tearing it
    /// down. Encoder + decoder + transport bindings stay live so when
    /// the user toggles back on, the very next frame from the camera
    /// reaches the peer with no re-init.
    public func setCameraEnabled(_ enabled: Bool) {
        guard isRunning else { return }
        if enabled {
            if !captureSession.isRunning {
                captureSession.startRunning()
            }
        } else {
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
        }
    }

    /// Inbound fragment arrival point for the transport layer to call.
    /// Reentrant-safe; fragmenter has its own lock.
    /// W394: applies PQC unwrap if a decryptor is currently installed.
    public nonisolated func acceptInboundFragment(_ payload: Data) {
        let unwrapped: Data
        #if canImport(WebRTC)
        sealerLock.lock()
        let dec = pqcDecryptor
        sealerLock.unlock()
        if let dec = dec {
            let opened = dec.decryptCiphertext(payload)
            unwrapped = opened.isEmpty ? payload : opened
        } else {
            unwrapped = payload
        }
        #else
        unwrapped = payload
        #endif
        if let frame = inboundFragmenter.defragment(unwrapped) {
            do {
                try decoder.decode(frame.nalUnit)
            } catch {
                print("[VideoCallPipeline] inbound decode failed: \(error)")
            }
        }
    }

    /// W394: PQC seal helper for the outbound path. Caller passes a
    /// raw fragment; gets back a sealed-or-clear payload depending on
    /// whether the rekey has installed a sealer.
    public nonisolated func sealOutboundFragment(_ fragment: Data) -> Data {
        #if canImport(WebRTC)
        sealerLock.lock()
        let enc = pqcEncryptor
        sealerLock.unlock()
        if let enc = enc {
            let sealed = enc.encryptPlaintext(fragment)
            return sealed.isEmpty ? fragment : sealed
        }
        return fragment
        #else
        return fragment
        #endif
    }

    /// W398 — read the inbound fragmenter's loss-window counters.
    /// Returns (received, lost) since the last call. Used by the
    /// AbrController to compute recent loss percentage.
    public nonisolated func consumeInboundAbrSample() -> (received: Int, lost: Int) {
        return inboundFragmenter.consumeAbrSample()
    }

    /// W398 — adjust the HEVC encoder's target bitrate mid-stream.
    /// Called by AbrController based on observed inbound loss rate.
    /// HevcEncoder.setBitrate clamps to [minVideoBitrateBps,
    /// maxVideoBitrateBps] so any value is safe.
    public nonisolated func setEncoderBitrate(_ newBps: Int) {
        encoder.setBitrate(newBps)
    }

    /// W394: install / rotate the PQC sealer. Called when
    /// CallSessionKeyBroker fires sasReadyNotification with a fresh
    /// 32-byte ML-KEM-derived secret. Idempotent — the call site
    /// can fire it on every notification without checking.
    public func rotatePqcSealer(_ newKey: Data?) {
        #if canImport(WebRTC)
        sealerLock.lock()
        defer { sealerLock.unlock() }
        guard let key = newKey, key.count == 32 else {
            pqcEncryptor = nil
            pqcDecryptor = nil
            return
        }
        do {
            let sealer = try PqcRtpFrameSealer(pqcSessionKey: key)
            pqcEncryptor = PqcFrameEncryptor(sealer: sealer)
            pqcDecryptor = PqcFrameDecryptor(sealer: sealer)
        } catch {
            print("[VideoCallPipeline] rotatePqcSealer failed: \(error)")
            pqcEncryptor = nil
            pqcDecryptor = nil
        }
        #endif
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
        // Android interop bridge: push raw frame to WebRTC RTCVideoSource
        // before HEVC encoding. Android receives video via WebRTC RTP (not
        // BCrypto WS video_frame), so this is the only path that delivers
        // iOS camera video to the Android peer.
        let nsInt64 = Int64(CMTimeGetSeconds(pts) * 1_000_000_000)
        self.onCapturedPixelBuffer?(pixelBuffer, nsInt64)
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

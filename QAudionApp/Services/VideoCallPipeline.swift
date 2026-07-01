import Foundation
@preconcurrency import AVFoundation
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

    /// media-consent v1 — what feeds the encoder.
    ///
    /// - `.camera`: classic path — AVCaptureSession owns the frames.
    /// - `.external`: NO camera is ever opened. Frames are injected via
    ///   [submitExternalFrame] (ReplayKit screen share) and/or the pipeline
    ///   is used decode-only (receiving a peer's screen on an audio call).
    ///   `start()` skips the permission prompt and the capture session
    ///   entirely, so an audio-only screen share never touches the camera.
    public enum SourceMode { case camera, external }

    /// Configure BEFORE `start()`. Defaults to `.camera`.
    public var sourceMode: SourceMode = .camera

    /// Target dimensions / fps. Defaults match VideoConstants engine
    /// numbers so cross-platform interop is symmetrical.
    /// `nonisolated(unsafe)` so the AVCapture / VT callback closures
    /// can read the bitrate without a MainActor hop on every frame.
    /// Configure these BEFORE calling `start()`.
    public nonisolated(unsafe) var targetWidth: Int = VideoConstants.defaultVideoWidth
    public nonisolated(unsafe) var targetHeight: Int = VideoConstants.defaultVideoHeight
    public nonisolated(unsafe) var targetFps: Int = VideoConstants.defaultVideoFps
    // W574n — iOS starts video at 1.5 Mbps (vs the 800 kbps cross-platform
    // VideoConstants default) for crisp 720p out of the gate; the ABR
    // controller still climbs toward maxVideoBitrateBps (2.5 Mbps) on a good
    // link and backs off on jitter/latency, so this only sets the STARTING
    // quality (saves ~48 s of +50 kbps/2 s ramp from 800 k). iOS-side only —
    // bitrate is a local encoder choice, not a wire-format value, so Android /
    // Desktop / firmware decode it unchanged.
    public nonisolated(unsafe) var targetBitrateBps: Int = 1_500_000

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
    // The encoder stays a `let` — resolution stepping mutates the
    // VTCompressionSession inside the existing HevcEncoder instance
    // (invalidate + start at new width/height), so the reference
    // doesn't change. That keeps the nonisolated capture delegate's
    // cross-actor `encoder.encode(...)` access pattern valid under
    // Swift 6 strict concurrency.
    // W574n — start the encoder at the iOS 1.5 Mbps target (not the 800 kbps
    // VideoConstants default) so the very first frames are already crisp; ABR
    // adjusts from here.
    private let encoder = HevcEncoder(bitrateBps: 1_500_000)
    private let decoder = HevcDecoder()
    /// W524: when true the captureOutput delegate skips encoding so
    /// no fragments are emitted to the peer. AVCaptureSession keeps
    /// running so the local preview stays live and resuming is
    /// instant (no permission re-prompt). Toggled by setVideoPaused.
    /// `nonisolated(unsafe)` because the capture delegate (running on
    /// captureQueue) reads it cross-actor — a Bool read is atomic on
    /// arm64 so the worst-case race is one stale frame emitted right
    /// at toggle time.
    private nonisolated(unsafe) var paused: Bool = false
    /// media-consent v1 — while a screen share is feeding the encoder via
    /// [submitExternalFrame], camera frames from the capture session are
    /// dropped (one producer at a time; interleaving two sources corrupts
    /// the HEVC stream). The capture session keeps running so the local
    /// camera preview survives the share and resuming is instant.
    public nonisolated(unsafe) var externalFeedActive: Bool = false
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
    /// Task 10 holistic review — rate-limits the drop warnings below so a
    /// sustained pre-handshake/failure window can't spam the log at
    /// 24-30fps. Guarded by `dropWarnLock` (separate from `sealerLock`:
    /// distinct concern, avoids re-entrancy coupling).
    private nonisolated(unsafe) var lastOutboundDropWarnAtMs: Int64 = 0
    private nonisolated(unsafe) var lastInboundDropWarnAtMs: Int64 = 0
    private let dropWarnLock = NSLock()
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
    /// In `.external` source mode the camera/permission steps are skipped
    /// entirely — only the encoder/decoder/purge machinery comes up.
    public func start() async throws {
        guard !isRunning else { return }
        if sourceMode == .external {
            try encoder.start()
            encoder.requestForcedKeyFrame()
            startPurgeTimer()
            isRunning = true
            return
        }
        try await ensurePermission()
        try setupSession()
        try encoder.start()
        // W565 — MUST NOT call startRunning() on the main thread.
        // Apple docs: "Do not call startRunning() on the main thread —
        // it can block until the hardware is ready, stalling the UI and
        // triggering a watchdog kill." AppState.startVideoPipeline() is
        // @MainActor, so without this hop the blocking call lands on the
        // main thread. Hopping to captureQueue makes it non-blocking for
        // the caller AND puts the call on the queue that owns the session.
        let session = captureSession
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            captureQueue.async {
                session.startRunning()
                cont.resume()
            }
        }
        // W567 — request an immediate IDR keyframe on the first captured
        // frame. Without this, the remote decoder receives P-frames and
        // throws "awaitingParameterSets" until the scheduled keyframe
        // (default: every 2 seconds), causing the video to appear frozen
        // or very slow. The forced IDR includes VPS/SPS/PPS so the
        // decoder can bootstrap immediately.
        encoder.requestForcedKeyFrame()
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
        // W565 — same thread-safety fix as start(): never call
        // startRunning/stopRunning on the main thread (watchdog risk).
        let session = captureSession
        captureQueue.async {
            if enabled {
                if !session.isRunning { session.startRunning() }
            } else {
                if session.isRunning { session.stopRunning() }
            }
        }
    }

    /// Inbound fragment arrival point for the transport layer to call.
    /// Reentrant-safe; fragmenter has its own lock.
    ///
    /// W394 / Task 10 holistic-review fix (2026-07-01) — applies PQC unwrap
    /// if a decryptor is currently installed; DROPS the fragment (does not
    /// process it) if no decryptor is installed OR the AEAD open fails.
    /// The previous behaviour (`opened.isEmpty ? payload : opened`) fed the
    /// raw, still-encrypted ciphertext into `defragment`/`decode` as if it
    /// were authenticated plaintext on ANY failure — discarding the
    /// security-relevant signal instead of surfacing it, and processing
    /// attacker/network-corrupted bytes as trusted input. Mirrors Android's
    /// `BcryptoWsVideoRelayTransport.parseAndUnseal`, which has no
    /// pass-through-unsealed mode for video and drops + rate-limited-WARNs
    /// on the exact same two conditions.
    public nonisolated func acceptInboundFragment(_ payload: Data) {
        let unwrapped: Data
        #if canImport(WebRTC)
        sealerLock.lock()
        let dec = pqcDecryptor
        sealerLock.unlock()
        guard let dec = dec else {
            warnInboundDropRateLimited("acceptInboundFragment: no decryptor installed, dropping inbound video fragment")
            return
        }
        let opened = dec.decryptCiphertext(payload)
        guard !opened.isEmpty else {
            warnInboundDropRateLimited("acceptInboundFragment: decryptCiphertext failed, dropping inbound video fragment")
            return
        }
        unwrapped = opened
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

    /// W394 / Task 10 holistic-review fix (2026-07-01) — PQC seal helper
    /// for the outbound path. Returns the sealed payload, or `nil` if no
    /// encryptor is installed OR the seal itself fails — the caller MUST
    /// drop the fragment (not send it) on `nil`. The previous behaviour
    /// (`sealed.isEmpty ? fragment : sealed`, non-optional `Data` return)
    /// shipped the RAW, UNENCRYPTED video fragment over the WS relay on
    /// either failure mode, with no logging — directly contradicting
    /// `PqcFrameEncryptorAdapter.encryptPlaintext`'s own documented
    /// contract ("frame must be dropped, NOT sent as plaintext") and this
    /// project's signal-not-kill philosophy (security failures must warn
    /// and degrade, never silently ship as if nothing happened). Mirrors
    /// Android's `BcryptoWsVideoRelayTransport.sendFrame`, which has no
    /// plaintext-fallback path at all.
    public nonisolated func sealOutboundFragment(_ fragment: Data) -> Data? {
        #if canImport(WebRTC)
        sealerLock.lock()
        let enc = pqcEncryptor
        sealerLock.unlock()
        guard let enc = enc else {
            warnOutboundDropRateLimited("sealOutboundFragment: no encryptor installed, dropping outbound video fragment")
            return nil
        }
        let sealed = enc.encryptPlaintext(fragment)
        guard !sealed.isEmpty else {
            warnOutboundDropRateLimited("sealOutboundFragment: encryptPlaintext failed, dropping outbound video fragment")
            return nil
        }
        return sealed
        #else
        return fragment
        #endif
    }

    #if canImport(WebRTC)
    private nonisolated func warnOutboundDropRateLimited(_ message: String) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        dropWarnLock.lock()
        let shouldLog = now - lastOutboundDropWarnAtMs > 2000
        if shouldLog { lastOutboundDropWarnAtMs = now }
        dropWarnLock.unlock()
        if shouldLog { print("[VideoCallPipeline] \(message)") }
    }

    private nonisolated func warnInboundDropRateLimited(_ message: String) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        dropWarnLock.lock()
        let shouldLog = now - lastInboundDropWarnAtMs > 2000
        if shouldLog { lastInboundDropWarnAtMs = now }
        dropWarnLock.unlock()
        if shouldLog { print("[VideoCallPipeline] \(message)") }
    }
    #endif

    /// W398 — read the inbound fragmenter's loss-window counters.
    /// Returns (received, lost) since the last call. Used by the
    /// AbrController to compute recent loss percentage.
    public nonisolated func consumeInboundAbrSample() -> (received: Int, lost: Int) {
        return inboundFragmenter.consumeAbrSample()
    }

    /// W524 — extended ABR sample with latency + jitter proxies.
    /// The AbrController prefers this over the loss-only variant so it
    /// can match Android's full AdaptiveBitrateController.update path.
    public nonisolated func consumeInboundAbrSampleExtended()
        -> (received: Int, lost: Int, avgLatencyMs: Int64, jitterMs: Double)
    {
        return inboundFragmenter.consumeAbrSampleExtended()
    }

    /// W398 — adjust the HEVC encoder's target bitrate mid-stream.
    /// Called by AbrController based on observed inbound loss rate.
    /// HevcEncoder.setBitrate clamps to [minVideoBitrateBps,
    /// maxVideoBitrateBps] so any value is safe.
    public nonisolated func setEncoderBitrate(_ newBps: Int) {
        encoder.setBitrate(newBps)
    }

    /// W524 — adjust expected frame rate (ABR layer 3). Pure
    /// VTSessionSetProperty call, no restart needed.
    public nonisolated func setEncoderFps(_ newFps: Int) {
        encoder.setFps(newFps)
    }

    /// W524 — pause/resume outbound video without tearing down the
    /// capture session. The local preview stays live; the captureOutput
    /// delegate just stops feeding the encoder. Used by ABR layer 4
    /// when latency + loss enter "give up on video" territory, and by
    /// media-consent v1 to hold camera frames back until the peer accepts
    /// the upgrade (preview-only: nothing leaves the device while paused).
    public nonisolated func setVideoPaused(_ paused: Bool) {
        self.paused = paused
    }

    /// media-consent v1 — external-source injection point (ReplayKit screen
    /// share). Routes through the SAME paused gate / WebRTC bridge / W561
    /// resize / HEVC encode path as camera frames, so the WS-HEVC transport
    /// carries the screen exactly like it carries the camera. Safe to call
    /// from any queue (mirrors the captureOutput delegate's isolation).
    public nonisolated func submitExternalFrame(
        _ pixelBuffer: CVPixelBuffer, presentationTimeNs: Int64
    ) {
        if self.paused { return }
        self.onCapturedPixelBuffer?(pixelBuffer, presentationTimeNs)
        let bw = CVPixelBufferGetWidth(pixelBuffer)
        let bh = CVPixelBufferGetHeight(pixelBuffer)
        if bw > 0, bh > 0, (bw != self.encoder.width || bh != self.encoder.height) {
            do {
                try self.encoder.setResolution(width: bw, height: bh)
                self.targetWidth = bw
                self.targetHeight = bh
            } catch {
                print("[VideoCallPipeline] external frame encoder resize failed: \(error)")
            }
        }
        do {
            try self.encoder.encode(
                pixelBuffer: pixelBuffer,
                presentationTimeNs: UInt64(max(0, presentationTimeNs)))
        } catch {
            print("[VideoCallPipeline] external frame encode failed: \(error)")
        }
    }

    /// W524 — step the encoder + capture session to a new resolution
    /// tier. Mirrors Android's `ResolutionTier` (720/480/360p). Both
    /// the AVCaptureSession preset AND the HEVC encoder session must
    /// be reconfigured atomically; we recreate the encoder and bounce
    /// the capture session preset under a single beginConfiguration
    /// block so no frame in flight reaches a mismatched encoder.
    @MainActor
    public func setEncoderResolution(width: Int, height: Int) {
        do {
            try encoder.setResolution(width: width, height: height)
            captureSession.beginConfiguration()
            captureSession.sessionPreset = preset(forHeight: height)
            captureSession.commitConfiguration()
            print("[VideoCallPipeline] resolution → \(width)x\(height)")
        } catch {
            print("[VideoCallPipeline] setEncoderResolution failed: \(error)")
        }
    }

    /// Maps a target height to the closest AVCaptureSession preset.
    /// 720→.hd1280x720, 480→.vga640x480 (closest standard 480p), 360→.cif352x288.
    private func preset(forHeight h: Int) -> AVCaptureSession.Preset {
        switch h {
        case 720: return .hd1280x720
        case 480: return .vga640x480
        case 360: return .cif352x288
        default:  return .hd1280x720
        }
    }

    /// W394 / Task 10 parity — install / rotate the PQC sealer. Called when
    /// CallSessionKeyBroker fires sasReadyNotification with a fresh
    /// 32-byte ML-KEM-derived secret. Idempotent — the call site
    /// can fire it on every notification without checking.
    ///
    /// **Directional keys, mandatory.** Android's WS-relay video fallback
    /// (shipped 2026-06-30, `CallController.onConnected`) unconditionally
    /// derives a DIRECTIONAL sealer pair for video via
    /// `PqcRtpFrameSealer.createDirectional(sessionKey, "<callId>:video", selfIsRoleA)`
    /// — the `:video` suffix domain-separates this key from audio's own
    /// directional sealers (bare callId), and the a2b/b2a split avoids the
    /// (key, nonce) reuse the legacy single-key scheme is vulnerable to
    /// (see the `createDirectional` kdoc). iOS MUST derive the byte-identical
    /// keys or `open()` fails 100% of the time against a real Android peer —
    /// this is why `callId` and `selfIsRoleA` are now required parameters
    /// instead of the old callId-unbound single-key `init(pqcSessionKey:)`.
    ///
    /// - Parameters:
    ///   - newKey: 32-byte ML-KEM-derived session key, or `nil`/wrong-length
    ///     to clear the sealer (e.g. call ended).
    ///   - callId: the ACTIVE call's lowercase wire call_id (same string
    ///     Android's `outcome.callId` resolves to) — MUST match the peer's
    ///     value or the HKDF info diverges and interop fails silently
    ///     (AEAD auth failure on every frame).
    ///   - selfIsRoleA: `PqcRtpFrameSealer.selfIsRoleA(selfUserId, peerUserId)`
    ///     — same rule Android/Desktop use, so both legs agree without
    ///     extra signalling.
    public func rotatePqcSealer(_ newKey: Data?, callId: String, selfIsRoleA: Bool) {
        #if canImport(WebRTC)
        sealerLock.lock()
        defer { sealerLock.unlock() }
        guard let key = newKey, key.count == 32, !callId.isEmpty else {
            pqcEncryptor = nil
            pqcDecryptor = nil
            return
        }
        do {
            let videoCallId = "\(callId.lowercased()):video"
            let pair = try PqcRtpFrameSealer.createDirectional(
                pqcSessionKey: key, callId: videoCallId, selfIsRoleA: selfIsRoleA)
            pqcEncryptor = PqcFrameEncryptor(sealer: pair.send)
            pqcDecryptor = PqcFrameDecryptor(sealer: pair.recv)
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
        // CRITICAL — do NOT let AVCaptureSession touch the shared AVAudioSession.
        // It defaults to `true`, which means startRunning() reconfigures and
        // re-activates the app's audio session. During a voice call that session
        // is owned by CallKit (CXProvider, .playAndRecord/.voiceChat) and driven
        // by our AVAudioEngine. Letting the camera reconfigure it clobbers the
        // voice route → the call audio corrupts / goes silent the instant video
        // starts (user-reported: "la voce si è corrotta/ammutolita appena video").
        // We add NO audio input to this session (video-only), so we never need
        // it to manage audio. Must be set BEFORE beginConfiguration/startRunning.
        captureSession.automaticallyConfiguresApplicationAudioSession = false

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

        // W523: rotate captured frames to portrait BEFORE handing them to
        // the encoder. Without this the videoOutput connection delivers
        // pixel buffers in the sensor's native landscape orientation —
        // local preview can correct it for display but the encoded
        // HEVC stream goes out landscape, so the remote peer sees a
        // 90° counter-clockwise rotated video (confirmed user-report
        // v1.0.522 iPad↔iPhone). For the front camera we ALSO need to
        // mirror so the encoded stream matches what the user sees in
        // their local self-view (otherwise the peer sees a mirrored
        // image too, which Android does NOT do).
        if let conn = videoOutput.connection(with: .video) {
            if #available(iOS 17.0, *) {
                // 90° = portrait (home button down equivalent on legacy hw).
                if conn.isVideoRotationAngleSupported(90) {
                    conn.videoRotationAngle = 90
                }
            } else {
                if conn.isVideoOrientationSupported {
                    conn.videoOrientation = .portrait
                }
            }
            // Front camera: undo the sensor mirror so the peer sees the
            // un-mirrored image (faces correct, text readable).
            if cameraPosition == .front, conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = false
            }
        }
        captureSession.commitConfiguration()
    }

    private func wireEngineCallbacks() {
        encoder.onNal = { [weak self] nal, isKeyFrame in
            guard let self = self else { return }
            // Fragment the NAL and ship each chunk to the transport.
            // Both fragmenter and the transport callback are reentrant.
            // Task 10 holistic-review fix — `fragment` now throws instead
            // of silently truncating an oversized NAL to 255 fragments
            // (which corrupted large keyframes with zero signal). Drop the
            // WHOLE frame and log on rejection, mirroring Android's
            // BcryptoWsVideoRelayTransport.sendFrame catch block for the
            // same condition.
            do {
                let fragments = try self.outboundFragmenter.fragment(
                    nalUnit: nal,
                    isKeyFrame: isKeyFrame,
                    bitrateKbps: self.targetBitrateBps / 1000)
                for f in fragments {
                    self.onOutboundFragment?(f)
                }
            } catch {
                print("[VideoCallPipeline] outbound fragment rejected, dropping frame: \(error)")
            }
        }
        decoder.onPixelBuffer = { [weak self] pb, _ in
            self?.onDecodedFrame?(pb)
        }
    }

    private func startPurgeTimer() {
        // W571 — fire every 200ms (was 100ms) to evict incomplete inbound frames
        // whose missing fragments never arrived. 100ms was too aggressive for
        // cellular jitter buffers where frame reassembly can legitimately take
        // 120-180ms; bumping to 200ms gives the fragmenter a larger window to
        // receive straggling fragments while still evicting truly lost frames
        // well within the 2s keyframe interval. Recommendation from multi-LLM
        // review: typical VoIP jitter buffers use 150-300ms eviction window.
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))
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
        // W524: ABR layer 4 — video paused under extreme network
        // conditions. Skip BOTH the WebRTC bridge and the HEVC
        // encoder so the peer sees a clean stall, not garbled
        // partial frames at the bottom of the bitrate floor.
        if self.paused { return }
        // Screen share owns the encoder while active — drop camera frames
        // (see externalFeedActive docs).
        if self.externalFeedActive { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ns = UInt64(CMTimeGetSeconds(pts) * 1_000_000_000)
        // Android interop bridge: push raw frame to WebRTC RTCVideoSource
        // before HEVC encoding. Android receives video via WebRTC RTP (not
        // BCrypto WS video_frame), so this is the only path that delivers
        // iOS camera video to the Android peer.
        let nsInt64 = Int64(CMTimeGetSeconds(pts) * 1_000_000_000)
        self.onCapturedPixelBuffer?(pixelBuffer, nsInt64)
        // W561 — the HEVC encoder dimensions MUST match the actual captured
        // pixel-buffer dimensions. The capture connection rotates frames to
        // PORTRAIT (videoRotationAngle=90 → 720x1280), but the encoder was
        // created at LANDSCAPE 1280x720 (VideoConstants default). VTCompression
        // Session SCALES a mismatched input to its configured WxH ignoring
        // aspect ratio, squishing portrait content into a landscape frame → the
        // peer saw a STRETCHED/distorted image ("formato sbagliato, stretchato").
        // Reconfigure the encoder to the real buffer size on the first frame
        // (and whenever it changes, e.g. an ABR preset switch or orientation
        // flip). setResolution recreates the VTCompressionSession at the new
        // dims; its first output is a fresh IDR keyframe, so the peer's decoder
        // re-bootstraps with the correct SPS. Validated by external review:
        // matching encoder-to-buffer is the robust fix for a mixed iOS/Android
        // fleet (no reliance on optional rotation signaling).
        let bw = CVPixelBufferGetWidth(pixelBuffer)
        let bh = CVPixelBufferGetHeight(pixelBuffer)
        if bw > 0, bh > 0, (bw != self.encoder.width || bh != self.encoder.height) {
            do {
                try self.encoder.setResolution(width: bw, height: bh)
                self.targetWidth = bw
                self.targetHeight = bh
                print("[VideoCallPipeline] W561 encoder resized to match capture \(bw)x\(bh)")
            } catch {
                print("[VideoCallPipeline] W561 encoder resize failed: \(error)")
            }
        }
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

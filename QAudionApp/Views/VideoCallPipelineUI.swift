import SwiftUI
import AVFoundation
import CoreVideo
import CoreMedia
#if canImport(UIKit)
import UIKit
#endif

/// W391 — SwiftUI bridges for the W391 video pipeline.
///
/// `LocalCameraPreview`: renders the local camera feed via
/// AVCaptureVideoPreviewLayer attached to the pipeline's
/// AVCaptureSession. Zero-copy hardware path.
///
/// `RemoteVideoDisplay`: renders decoded CVPixelBuffer frames from
/// the pipeline's HEVC decoder via AVSampleBufferDisplayLayer. Same
/// low-overhead path the system video player uses.

#if canImport(UIKit)

/// SwiftUI wrapper that hosts an AVCaptureVideoPreviewLayer bound to
/// the supplied pipeline's capture session.
public struct LocalCameraPreview: UIViewRepresentable {
    public let pipeline: VideoCallPipeline

    public init(pipeline: VideoCallPipeline) {
        self.pipeline = pipeline
    }

    public func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.attach(to: pipeline.captureSession)
        return v
    }

    public func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.attach(to: pipeline.captureSession)
    }

    // W-CRASH-AVF2 — production crash (v1.0.798, iOS 26.5.2, call 7212ec21,
    // right after a rapid video downgrade→reupgrade): EXC_CRASH/SIGABRT in
    // `-[AVCaptureSession dealloc]` → `_makeConfigurationLive:` →
    // `detachFromFigCaptureSession:`, triggered from a SwiftUI view-array
    // deinit cascade on the main thread. Root cause: this view never
    // implemented `dismantleUIView`, so when SwiftUI tears the view out of
    // the hierarchy (e.g. `startVideoPipeline` swaps in a fresh
    // `VideoCallPipeline` on upgrade — see AppState.swift), `PreviewUIView`
    // deallocates with `previewLayer.session` still pointing at the old,
    // dying `AVCaptureSession`. AVFoundation's own dealloc-time safety net
    // tries to force-detach the still-attached preview layer and asserts
    // because that happens re-entrantly inside the SwiftUI deinit chain
    // instead of a clean, ordered teardown. Explicitly nil-ing the session
    // here — guaranteed by SwiftUI to run BEFORE the UIView is released —
    // makes the detach happen on our terms, ahead of any dealloc.
    public static func dismantleUIView(_ uiView: PreviewUIView, coordinator: ()) {
        uiView.previewLayer.session = nil
    }

    public final class PreviewUIView: UIView {
        public override class var layerClass: AnyClass {
            AVCaptureVideoPreviewLayer.self
        }
        var previewLayer: AVCaptureVideoPreviewLayer {
            return layer as! AVCaptureVideoPreviewLayer
        }
        func attach(to session: AVCaptureSession) {
            if previewLayer.session !== session {
                previewLayer.session = session
            }
            previewLayer.videoGravity = .resizeAspectFill
        }
    }
}

/// SwiftUI wrapper around AVSampleBufferDisplayLayer that consumes
/// decoded CVPixelBuffers from the pipeline.
public struct RemoteVideoDisplay: UIViewRepresentable {
    public let pipeline: VideoCallPipeline

    public init(pipeline: VideoCallPipeline) {
        self.pipeline = pipeline
    }

    public func makeUIView(context: Context) -> DisplayUIView {
        let v = DisplayUIView()
        v.contentMode = .scaleAspectFit   // prevent SwiftUI from stretching the UIView
        v.backgroundColor = .black
        v.attach(pipeline: pipeline)
        return v
    }

    public func updateUIView(_ uiView: DisplayUIView, context: Context) {
        uiView.attach(pipeline: pipeline)
    }

    /// W574m — CADisplayLink needs a target; referencing the view directly
    /// creates a retain cycle (link↔view) that leaks the timer. A weak proxy
    /// breaks it so the view deinits and `invalidate()` actually runs.
    final class DisplayLinkProxy: NSObject {
        weak var view: DisplayUIView?
        init(_ v: DisplayUIView) { self.view = v }
        @objc func onTick(_ link: CADisplayLink) { view?.onDisplayTick(link) }
    }

    public final class DisplayUIView: UIView {
        public override class var layerClass: AnyClass {
            AVSampleBufferDisplayLayer.self
        }
        var displayLayer: AVSampleBufferDisplayLayer {
            return layer as! AVSampleBufferDisplayLayer
        }
        private weak var pipeline: VideoCallPipeline?

        // W574m — receive-side jitter buffer + paced presentation. The HEVC
        // pipeline delivers decoded frames in BURSTS: the sealed-relay path
        // rides a TCP WebSocket (head-of-line blocking) and each frame is
        // reassembled from ~1200-byte fragments, so inter-arrival time is
        // highly irregular. The previous code enqueued every frame with
        // `.invalid` PTS + `DisplayImmediately`, so the on-screen cadence
        // equalled the (jittery) network arrival cadence → visible stutter
        // ("scatti"). We now buffer a few frames and release them on a
        // CADisplayLink at a steady ~targetFps, absorbing the jitter.
        // Safety: an EMPTY buffer simply holds the last shown frame (never
        // freezes/blacks), and an OVERFULL buffer (we fell behind) drains
        // fast to bound added latency. Render-side only — no wire change.
        private var pending: [CVPixelBuffer] = []
        private let bufLock = NSLock()
        private var displayLink: CADisplayLink?
        private var linkProxy: DisplayLinkProxy?
        private var lastPresent: CFTimeInterval = 0
        private var targetInterval: CFTimeInterval = 1.0 / 24.0
        private var warmedUp = false
        /// Frames to pre-buffer before the first present — the steady-state
        /// jitter cushion (~2 frames ≈ 83 ms @ 24 fps). Kept small so we don't
        /// hold too many of the HEVC decoder's pixel-buffer pool (starving it
        /// would stall decode — worse than the jitter we're smoothing).
        private static let warmupDepth = 2
        /// Hard cap on buffered frames (~167 ms @ 24 fps) — beyond this we
        /// drop the oldest to keep latency bounded and the decoder pool free.
        private static let maxDepth = 4

        func attach(pipeline: VideoCallPipeline) {
            self.pipeline = pipeline
            displayLayer.videoGravity = .resizeAspect   // preserve aspect ratio — no distortion on iPad
            let fps = max(1, pipeline.targetFps)
            targetInterval = 1.0 / CFTimeInterval(fps)
            // Buffer each decoded frame (fires on the decoder queue); the
            // display link paces presentation on the main thread.
            pipeline.onDecodedFrame = { [weak self] pixelBuffer in
                self?.ingest(pixelBuffer)
            }
            if displayLink == nil {
                let proxy = DisplayLinkProxy(self)
                let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.onTick(_:)))
                link.add(to: .main, forMode: .common)
                self.linkProxy = proxy
                self.displayLink = link
            }
        }

        deinit {
            displayLink?.invalidate()
        }

        /// Buffer a freshly decoded frame. Runs on the decoder queue, so the
        /// buffer is lock-guarded (the display-link tick reads it on main).
        /// Drops the oldest beyond the latency cap so a burst can't grow lag.
        private func ingest(_ pixelBuffer: CVPixelBuffer) {
            bufLock.lock()
            pending.append(pixelBuffer)
            if pending.count > Self.maxDepth {
                pending.removeFirst(pending.count - Self.maxDepth)
            }
            bufLock.unlock()
        }

        /// CADisplayLink tick on the MAIN thread (added to .main run loop).
        /// Releases at most one frame per `targetInterval`, except when the
        /// buffer overgrew the cushion (we fell behind) — then it drains
        /// faster to catch up. Empty buffer = hold the last frame (never
        /// freezes to black).
        func onDisplayTick(_ link: CADisplayLink) {
            let now = link.timestamp
            bufLock.lock()
            if pending.isEmpty { bufLock.unlock(); return }
            // Pre-buffer the jitter cushion before the very first present.
            if !warmedUp {
                if pending.count < Self.warmupDepth { bufLock.unlock(); return }
                warmedUp = true
            }
            let behind = pending.count > Self.warmupDepth   // grew past cushion → catch up
            if !behind && (now - lastPresent) < targetInterval { bufLock.unlock(); return }
            lastPresent = now
            let pb = pending.removeFirst()
            bufLock.unlock()
            enqueue(pixelBuffer: pb)   // UIKit/displayLayer — we are on main here
        }

        private func enqueue(pixelBuffer: CVPixelBuffer) {
            // Wrap the CVPixelBuffer in a CMSampleBuffer with .invalid
            // timing — the display layer plays "as fast as it gets"
            // for the live-streaming case.
            var fmt: CMVideoFormatDescription?
            let fmtStatus = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &fmt)
            guard fmtStatus == noErr, let fmt = fmt else { return }

            var timing = CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: .invalid,
                decodeTimeStamp: .invalid)
            var sampleBuffer: CMSampleBuffer?
            let sbStatus = CMSampleBufferCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: fmt,
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer)
            guard sbStatus == noErr, let sample = sampleBuffer else { return }

            // Tell the display layer to play this immediately.
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sample, createIfNecessary: true) as? [CFMutableDictionary],
               let first = attachments.first {
                CFDictionarySetValue(
                    first,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            if displayLayer.status == .failed {
                displayLayer.flush()
            }
            displayLayer.enqueue(sample)
        }
    }
}

#endif

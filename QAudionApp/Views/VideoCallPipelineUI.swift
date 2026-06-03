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
        v.attach(pipeline: pipeline)
        return v
    }

    public func updateUIView(_ uiView: DisplayUIView, context: Context) {
        uiView.attach(pipeline: pipeline)
    }

    public final class DisplayUIView: UIView {
        public override class var layerClass: AnyClass {
            AVSampleBufferDisplayLayer.self
        }
        var displayLayer: AVSampleBufferDisplayLayer {
            return layer as! AVSampleBufferDisplayLayer
        }
        private weak var pipeline: VideoCallPipeline?

        func attach(pipeline: VideoCallPipeline) {
            self.pipeline = pipeline
            displayLayer.videoGravity = .resizeAspect   // preserve aspect ratio — no distortion on iPad
            // Chain a closure that drops each decoded pixel buffer
            // into our display layer. Wrap in CMSampleBuffer per the
            // AVSampleBufferDisplayLayer contract.
            pipeline.onDecodedFrame = { [weak self] pixelBuffer in
                guard let self = self else { return }
                Task { @MainActor in
                    self.enqueue(pixelBuffer: pixelBuffer)
                }
            }
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

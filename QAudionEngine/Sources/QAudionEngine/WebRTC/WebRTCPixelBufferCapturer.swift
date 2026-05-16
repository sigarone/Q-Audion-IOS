#if canImport(WebRTC) && os(iOS)
import Foundation
import WebRTC
import CoreVideo

/// RTCVideoCapturer subclass that accepts CVPixelBuffer frames pushed
/// from an external source (VideoCallPipeline's AVCaptureSession) and
/// forwards them to the RTCVideoCapturerDelegate (RTCVideoSource).
///
/// Rationale: when useExternalVideoSource == true on
/// QAudionWebRtcCallController, the controller skips RTCCameraVideoCapturer
/// to avoid a dual-AVCaptureSession conflict. VideoCallPipeline owns the
/// camera; it calls push(_:rotation:timestampNs:) on every captured frame
/// so WebRTC still receives raw video over RTP for Android interop.
///
/// Thread-safety: push() is safe from any queue — RTCVideoSource handles
/// the delegate call internally.
public final class WebRTCPixelBufferCapturer: RTCVideoCapturer {

    public func push(_ pixelBuffer: CVPixelBuffer,
                     rotation: RTCVideoRotation = ._0,
                     timestampNs: Int64) {
        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let frame = RTCVideoFrame(buffer: rtcBuffer,
                                  rotation: rotation,
                                  timeStampNs: timestampNs)
        delegate?.capturer(self, didCapture: frame)
    }
}
#endif

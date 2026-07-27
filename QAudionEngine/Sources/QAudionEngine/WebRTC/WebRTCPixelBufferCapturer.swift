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

    /// W-CAPTUREDIAG (2026-07-28) — throttled alongside VideoCallPipeline's
    /// own frame counter (same cadence: first push + every ~30th) to catch
    /// `delegate == nil` here specifically. `delegate` on RTCVideoCapturer
    /// is typically a weak reference to the RTCVideoSource; if whatever
    /// retains that source elsewhere in QAudionWebRtcCallController were to
    /// drop it, push() would keep getting called from the capture queue
    /// (so VideoCallPipeline's own diagnostic would look completely healthy)
    /// while every frame silently vanishes right here — the peer would see
    /// exactly the "SDP fine, transport connected, zero frames arrived"
    /// signature this is chasing.
    private var pushCount: Int = 0

    public func push(_ pixelBuffer: CVPixelBuffer,
                     rotation: RTCVideoRotation = ._0,
                     timestampNs: Int64) {
        pushCount += 1
        if pushCount == 1 || pushCount % 30 == 0 {
            print("[WebRTCPixelBufferCapturer] W-CAPTUREDIAG push=\(pushCount) delegateSet=\(delegate != nil)")
        }
        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let frame = RTCVideoFrame(buffer: rtcBuffer,
                                  rotation: rotation,
                                  timeStampNs: timestampNs)
        delegate?.capturer(self, didCapture: frame)
    }
}
#endif

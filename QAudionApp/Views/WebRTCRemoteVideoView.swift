#if canImport(WebRTC)
import SwiftUI
import WebRTC

/// SwiftUI wrapper around RTCMTLVideoView (Metal-backed) for displaying a
/// remote WebRTC video track. Used by VideoCallView when the peer (Android)
/// sends video via WebRTC RTP rather than the BCrypto WS HEVC pipeline.
///
/// Lifecycle:
///   - `track` is wired from AppState.remoteWebRtcVideoTrack (set by the
///     onRemoteVideoTrack callback in the WebRTC controller)
///   - The Coordinator attaches ONE renderer to the track: the VIDEODIAG
///     forwarding wrapper (DiagForwardingVideoRenderer) around the real
///     RTCMTLVideoView — count-then-forward. The rendered-hop counter and
///     the on-screen renderer therefore attach/detach IN LOCKSTEP: view
///     dismantled ⇒ wrapper removed ⇒ counter stops ⇒ the §8.7 watchdog
///     can latch a detached-renderer black-video stall and rung 2 (track
///     re-publish → SwiftUI rebuilds this view) can heal it.
///   - When `track` changes the old wrapper is detached and a fresh one
///     attached via the Coordinator's `connect` helper.
struct WebRTCRemoteVideoView: UIViewRepresentable {
    let track: RTCVideoTrack
    /// AppState's per-call VIDEODIAG counters (rendered hop).
    let diag: VideoPathDiag

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = .scaleAspectFit   // preserve aspect ratio — no distortion on iPad/iPhone
        context.coordinator.connect(track: track, to: view, diag: diag)
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        context.coordinator.connect(track: track, to: uiView, diag: diag)
    }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.disconnect()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private weak var currentView: RTCMTLVideoView?
        private var currentTrack: RTCVideoTrack?
        /// The ONE renderer attached to `currentTrack` (owns the weak
        /// reference to `currentView` and forwards frames to it).
        private var currentWrapper: DiagForwardingVideoRenderer?

        func connect(track: RTCVideoTrack, to view: RTCMTLVideoView, diag: VideoPathDiag) {
            // Already wired to this exact (track, view) pair — no-op so the
            // per-update SwiftUI call stays cheap and libwebrtc never sees
            // duplicate adds.
            if currentTrack?.trackId == track.trackId,
               currentView === view,
               currentWrapper != nil {
                return
            }
            if let oldTrack = currentTrack, let oldWrapper = currentWrapper {
                oldTrack.remove(oldWrapper)
            }
            let wrapper = DiagForwardingVideoRenderer(diag: diag, forwarding: view)
            currentTrack = track
            currentView = view
            currentWrapper = wrapper
            track.add(wrapper)
        }

        func disconnect() {
            if let track = currentTrack, let wrapper = currentWrapper {
                track.remove(wrapper)
            }
            currentTrack = nil
            currentView = nil
            currentWrapper = nil
        }
    }
}
#endif

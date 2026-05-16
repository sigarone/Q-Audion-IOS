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
///   - The view calls track.add(renderer) on appear and track.remove(renderer)
///     on disappear so frames are only delivered while the view is on-screen.
///   - When `track` changes the old renderer is detached and the new one
///     attached via the Coordinator's `connect` helper.
struct WebRTCRemoteVideoView: UIViewRepresentable {
    let track: RTCVideoTrack

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = .scaleAspectFill
        context.coordinator.connect(track: track, to: view)
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        context.coordinator.connect(track: track, to: uiView)
    }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.disconnect(from: uiView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private weak var currentView: RTCMTLVideoView?
        private var currentTrack: RTCVideoTrack?

        func connect(track: RTCVideoTrack, to view: RTCMTLVideoView) {
            if let old = currentTrack, old.trackId != track.trackId,
               let oldView = currentView {
                old.remove(oldView)
            }
            if currentTrack?.trackId != track.trackId {
                currentTrack = track
                currentView = view
                track.add(view)
            }
        }

        func disconnect(from view: RTCMTLVideoView) {
            currentTrack?.remove(view)
            currentTrack = nil
            currentView = nil
        }
    }
}
#endif

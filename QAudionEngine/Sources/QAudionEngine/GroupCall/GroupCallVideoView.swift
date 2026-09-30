import Foundation
import SwiftUI

#if canImport(WebRTC) && canImport(UIKit)
import UIKit
import WebRTC

/// SwiftUI renderer for a group-call video track: the un-erasing counterpart of
/// the `AnyObject` track callbacks of `GroupCallController`
/// (`onRemoteVideoTrack` / `onLocalVideoTrack`). It wraps the Metal-backed
/// `RTCMTLVideoView` of the strict M150 WebRTC build, so the app layer never
/// needs the WebRTC module itself.
///
/// Lifecycle: the coordinator keeps exactly ONE renderer attached to the current
/// track; a track change detaches the old one first, and dismantling the view
/// detaches it (a dangling renderer would keep the decoder running for a tile
/// that no longer exists).
public struct GroupCallVideoView: UIViewRepresentable {
    private let track: AnyObject
    private let mirrored: Bool

    /// `mirrored`: the self preview of the front camera is shown mirrored.
    public init(track: AnyObject, mirrored: Bool = false) {
        self.track = track
        self.mirrored = mirrored
    }

    public func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = .scaleAspectFill
        view.transform = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        context.coordinator.connect(track: track as? RTCVideoTrack, to: view)
        return view
    }

    public func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        uiView.transform = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        context.coordinator.connect(track: track as? RTCVideoTrack, to: uiView)
    }

    public static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.disconnect()
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator {
        private var currentTrack: RTCVideoTrack?
        private weak var currentView: RTCMTLVideoView?

        func connect(track: RTCVideoTrack?, to view: RTCMTLVideoView) {
            if currentTrack === track, currentView === view { return }
            disconnect()
            guard let track = track else { return }
            track.add(view)
            currentTrack = track
            currentView = view
        }

        func disconnect() {
            if let track = currentTrack, let view = currentView { track.remove(view) }
            currentTrack = nil
            currentView = nil
        }
    }
}

#else

/// Builds without the WebRTC module (macOS package build): inert placeholder so
/// the app layer always compiles.
public struct GroupCallVideoView: View {
    public init(track: AnyObject, mirrored: Bool = false) {}
    public var body: some View { Color.black }
}

#endif

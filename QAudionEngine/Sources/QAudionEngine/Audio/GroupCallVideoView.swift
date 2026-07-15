import Foundation
import SwiftUI

#if canImport(LiveKit)
import LiveKit

/// SwiftUI renderer for a group-call video track — the un-erasing
/// counterpart of `LiveKitGroupCallRoom`'s `AnyObject` track callbacks
/// (`onRemoteVideoTrack`/`onLocalVideoTrack`). Renders either a subscribed
/// remote participant's camera (`RemoteVideoTrack`) or our own self-preview
/// (`LocalVideoTrack`) — both conform to LiveKit's `VideoTrack` protocol, so
/// one view handles both.
///
/// Lives HERE (QAudionEngine, which already depends on `client-sdk-swift`)
/// rather than in QAudionApp, so the app layer never needs its own `import
/// LiveKit` / SPM product dependency — mirrors `LiveKitGroupCallRoom`'s own
/// doc comment on why its track callbacks type-erase to `AnyObject`. This
/// struct is the ONE place group-call video pixels get bound to a concrete
/// LiveKit type.
public struct GroupCallVideoView: View {
    private let track: AnyObject

    public init(track: AnyObject) {
        self.track = track
    }

    public var body: some View {
        if let videoTrack = track as? VideoTrack {
            SwiftUIVideoView(videoTrack, layoutMode: .fill, mirrorMode: .auto)
        } else {
            Color.black
        }
    }
}

#else

/// LiveKit SPM dependency did not resolve/compile in this build
/// environment — inert stub so QAudionApp always compiles, mirroring
/// `LiveKitGroupCallRoom`'s own `#else` branch.
public struct GroupCallVideoView: View {
    public init(track: AnyObject) {}
    public var body: some View { Color.black }
}

#endif

import Foundation

/// Group calls v2 — the seam between `GroupCallController` (call state, E2EE
/// epochs, recovery policy, tiles) and everything WebRTC-shaped. The real
/// implementation is `WebRtcGroupMediaBackend` (strict M150 build, the ONE
/// `RTCPeerConnectionFactory` of the app); unit tests plug in a fake, so the
/// orchestration is pinned without a PeerConnection.

/// A remote stream appeared, moved or went away.
public struct GroupRemoteTrack: @unchecked Sendable {
    public enum Kind: Sendable { case audio, video }

    /// Publisher pseudonym (the Janus feed).
    public let feedId: String
    /// Subscriber-side mid.
    public let mid: String
    public let kind: Kind
    public let isScreenShare: Bool
    /// The `RTCMediaStreamTrack`, type-erased so the app layer never needs the
    /// WebRTC module for anything but rendering (`GroupCallVideoView`). nil =
    /// the stream went away.
    public let track: AnyObject?

    public init(feedId: String, mid: String, kind: Kind, isScreenShare: Bool, track: AnyObject?) {
        self.feedId = feedId
        self.mid = mid
        self.kind = kind
        self.isScreenShare = isScreenShare
        self.track = track
    }
}

public enum GroupCameraResult: Equatable, Sendable {
    case started
    case stopped
    case permissionDenied
    case noCamera
    case notReady
}

/// One live media session (a `media_ready` hand-out): Janus session, publisher
/// and subscriber PeerConnections. Closed and rebuilt on every rejoin.
public protocol GroupMediaLink: AnyObject {
    var onEvent: ((GroupMediaSession.Event) -> Void)? { get set }
    var onRemoteTrack: ((GroupRemoteTrack) -> Void)? { get set }
    /// Our own camera track (nil = camera off), for the self tile.
    var onLocalVideoTrack: ((AnyObject?) -> Void)? { get set }
    /// Which publisher pseudonyms may be subscribed (current call members).
    var publisherFilter: ((String) -> Bool)? { get set }

    /// Connects, joins the room, publishes. Throws `JanusClientError` /
    /// `GroupMediaSession.Failure`.
    func start(publishVideo: Bool) async throws
    func setTile(pseudonym: String, tile: GroupLayerPolicy.TileClass, visible: Bool)
    func setBackgrounded(_ value: Bool)
    func refreshPublisherFilter()
    func setPublishVideo(_ on: Bool) async
    func setMicrophoneEnabled(_ enabled: Bool)
    func setCameraEnabled(_ enabled: Bool) async -> GroupCameraResult
    /// 0...3 simulcast encodings kept active (`GroupPublishPolicy`).
    func setActiveLayers(_ count: Int)
    func requestPublisherKeyFrame() async
    func networkPathChanged(reason: String) async
    func close()
}

/// Per-call media services: the frame-crypto key store (it outlives a media
/// restart, spec §2.5) and the factory of `GroupMediaLink`s.
public protocol GroupMediaBackend: AnyObject {
    /// A receiver cryptor reported a missing key / a decrypt failure for this
    /// participant (a publisher pseudonym).
    var onMissingKey: ((String) -> Void)? { get set }
    var onDecryptFailure: ((String) -> Void)? { get set }

    /// Fresh key store for a new call.
    func beginCall()
    /// `K[M,E]` of `participantId` (a pseudonym) into ring slot `index`.
    func installKey(_ key: Data, index: Int32, participantId: String)
    /// Points our own sender cryptors at ring slot `index`.
    func setSendKeyIndex(_ index: Int32)
    func makeLink(ready: GroupCallWire.MediaReady) async throws -> GroupMediaLink
    /// The call is over: drops every key.
    func endCall()
}

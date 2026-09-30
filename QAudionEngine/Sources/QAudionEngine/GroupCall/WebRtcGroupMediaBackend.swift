import Foundation
#if canImport(WebRTC)
import WebRTC

/// Group calls v2 — the real `GroupMediaBackend`: the strict M150 WebRTC build
/// through the ONE `RTCPeerConnectionFactory` the 1:1 path uses
/// (`QAudionPeerConnectionFactory.shared`), one `GroupFrameCryptorHub` per call
/// (its key ring outlives a media restart), and per `media_ready` a Janus
/// session with a publisher and a lazily created multistream subscriber.
public final class WebRtcGroupMediaBackend: GroupMediaBackend, @unchecked Sendable {

    public var onMissingKey: ((String) -> Void)?
    public var onDecryptFailure: ((String) -> Void)?

    private let lock = NSLock()
    private var hub = GroupFrameCryptorHub()

    public init() {
        wireHub()
    }

    private func wireHub() {
        let current = currentHub
        current.onMissingKey = { [weak self] participant in self?.onMissingKey?(participant) }
        current.onDecryptFailure = { [weak self] participant in self?.onDecryptFailure?(participant) }
    }

    private var currentHub: GroupFrameCryptorHub {
        lock.lock(); defer { lock.unlock() }
        return hub
    }

    public func beginCall() {
        let fresh = GroupFrameCryptorHub()
        lock.lock()
        let old = hub
        hub = fresh
        lock.unlock()
        wireHub()
        old.dispose()
    }

    public func installKey(_ key: Data, index: Int32, participantId: String) {
        currentHub.installKey(key, index: index, participantId: participantId)
    }

    public func setSendKeyIndex(_ index: Int32) {
        currentHub.setSendKeyIndex(index)
    }

    public func makeLink(ready: GroupCallWire.MediaReady) async throws -> GroupMediaLink {
        guard let url = URL(string: ready.wsUrl) else { throw GroupPeerError.factoryRefused }
        let factory = await QAudionPeerConnectionFactory.shared.factory()
        let cryptors = currentHub
        cryptors.bind(factory: factory)
        let iceServers = ready.iceServers.map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }
        let publisher = GroupPublisherPeer(factory: factory, iceServers: iceServers,
                                           cryptors: cryptors, selfPseudonym: ready.pseudonym)
        let janus = JanusClient(makeSocket: { URLSessionJanusSocket(url: url) },
                                token: { ready.sessionToken })
        let room = VideoRoomClient(janus: janus, room: ready.room, pseudonym: ready.pseudonym,
                                   joinToken: ready.joinToken)
        let link = WebRtcGroupMediaLink(publisher: publisher)
        let session = GroupMediaSession(
            janus: janus, room: room, publisher: publisher,
            makeSubscriber: { [weak link] in
                let peer = GroupSubscriberPeer(factory: factory, iceServers: iceServers, cryptors: cryptors)
                peer.onRemoteTrack = { remote in link?.forward(remote) }
                return peer
            },
            dtlsFingerprint: ready.dtlsFingerprint)
        link.attach(session: session)
        return link
    }

    public func endCall() {
        lock.lock()
        let old = hub
        lock.unlock()
        old.dispose()
    }
}

/// `GroupMediaLink` over a `GroupMediaSession` + its `GroupPublisherPeer`.
final class WebRtcGroupMediaLink: GroupMediaLink, @unchecked Sendable {

    var onEvent: ((GroupMediaSession.Event) -> Void)? {
        didSet { session?.onEvent = onEvent }
    }
    var onRemoteTrack: ((GroupRemoteTrack) -> Void)?
    var onLocalVideoTrack: ((AnyObject?) -> Void)? {
        didSet { publisher.onLocalVideoTrack = { [weak self] track in self?.onLocalVideoTrack?(track) } }
    }
    var publisherFilter: ((String) -> Bool)? {
        didSet { session?.publisherFilter = publisherFilter }
    }

    private let publisher: GroupPublisherPeer
    private var session: GroupMediaSession?

    init(publisher: GroupPublisherPeer) {
        self.publisher = publisher
    }

    func attach(session: GroupMediaSession) {
        self.session = session
        session.onEvent = onEvent
        session.publisherFilter = publisherFilter
    }

    func forward(_ remote: GroupSubscriberPeer.RemoteTrack) {
        onRemoteTrack?(GroupRemoteTrack(
            feedId: remote.feedId, mid: remote.mid,
            kind: remote.kind == .video ? .video : .audio,
            isScreenShare: remote.isScreenShare, track: remote.track))
    }

    func start(publishVideo: Bool) async throws {
        guard let session = session else { throw GroupPeerError.notStarted }
        try await session.start(publishVideo: publishVideo)
    }

    func setTile(pseudonym: String, tile: GroupLayerPolicy.TileClass, visible: Bool) {
        session?.setTile(pseudonym: pseudonym, tile: tile, visible: visible)
    }

    func setBackgrounded(_ value: Bool) { session?.setBackgrounded(value) }
    func refreshPublisherFilter() { session?.refreshPublisherFilter() }
    func setPublishVideo(_ on: Bool) async { await session?.setPublishVideo(on) }
    func setMicrophoneEnabled(_ enabled: Bool) { publisher.setMicrophoneEnabled(enabled) }
    func setCameraEnabled(_ enabled: Bool) async -> GroupCameraResult { await publisher.setCameraEnabled(enabled) }
    func setActiveLayers(_ count: Int) { publisher.setActiveLayers(count) }
    func requestPublisherKeyFrame() async { await session?.requestPublisherKeyFrame() }
    func networkPathChanged(reason: String) async { await session?.networkPathChanged(reason: reason) }

    func close() {
        if let session = session {
            session.close()
        } else {
            publisher.close()
        }
    }
}

#endif

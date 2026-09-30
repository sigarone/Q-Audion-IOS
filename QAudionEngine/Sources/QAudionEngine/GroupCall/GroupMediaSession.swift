import Foundation

// MARK: - Links

public enum GroupPcState: String, Sendable {
    case new, connecting, connected, disconnected, failed, closed
}

public struct GroupIceCandidate: Equatable, Sendable {
    public let sdpMid: String?
    public let sdpMLineIndex: Int32
    /// Never logged: it carries addresses.
    public let candidate: String

    public init(sdpMid: String?, sdpMLineIndex: Int32, candidate: String) {
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
        self.candidate = candidate
    }
}

public struct GroupInboundVideoStat: Equatable, Sendable {
    /// Subscriber-side mid.
    public let mid: String
    public let packetsLost: Int
    public let packetsReceived: Int

    public init(mid: String, packetsLost: Int, packetsReceived: Int) {
        self.mid = mid
        self.packetsLost = packetsLost
        self.packetsReceived = packetsReceived
    }
}

public struct GroupSubscriberStats: Equatable, Sendable {
    public let videos: [GroupInboundVideoStat]
    public let availableIncomingBps: Double?
    /// Subscriber mid -> decoded audio level (0...1), measured AFTER the
    /// frame decryption: the audio-level RTP extension is not negotiated, so
    /// "who is speaking" is computed here on the receiver (spec §4.4).
    public let audioLevels: [String: Double]

    public init(videos: [GroupInboundVideoStat], availableIncomingBps: Double?, audioLevels: [String: Double] = [:]) {
        self.videos = videos
        self.availableIncomingBps = availableIncomingBps
        self.audioLevels = audioLevels
    }
}

/// What `GroupMediaSession` needs from a PeerConnection wrapper. The real
/// implementations (`GroupPublisherPeer` / `GroupSubscriberPeer`) sit on the
/// strict M150 WebRTC build; tests use fakes.
public protocol GroupPeerLink: AnyObject {
    /// A local ICE candidate; `nil` marks the end of gathering.
    var onCandidate: ((GroupIceCandidate?) -> Void)? { get set }
    var onState: ((GroupPcState) -> Void)? { get set }
    /// Creates the PeerConnection (and, for the publisher, its transceivers
    /// with the frame cryptors attached BEFORE any offer exists).
    func start() async throws
    /// The `transport` stats row, for the §4.5 self-check.
    func transportObservation() async -> GroupTransportPolicy.Observed?
    func addRemoteCandidate(_ candidate: GroupIceCandidate?) async
    func close()
}

public protocol GroupPublisherLink: GroupPeerLink {
    /// The local offer, already munged (`GroupSdpRules.mungeLocal`).
    func createOffer(iceRestart: Bool) async throws -> String
    func applyAnswer(_ sdp: String) async throws
}

public protocol GroupSubscriberLink: GroupPeerLink {
    /// Applies Janus' offer, attaches the frame cryptors of the streams
    /// (participantId = publisher pseudonym) BEFORE any track renders, and
    /// returns the munged answer.
    func acceptOffer(_ sdp: String, streams: [VideoRoomStream]) async throws -> String
    func inboundStats() async -> GroupSubscriberStats?
}

// MARK: - Session

/// Group calls v2 (spec §4) — one media session of one call: the Janus
/// session, the publisher handle + PeerConnection and the lazily created
/// multistream subscriber handle + PeerConnection, with
///
///  * serialized renegotiation per PC (`GroupSerialQueue`, debounce 150 ms),
///  * the DTLS pin on every SDP that comes from qjanus,
///  * the §4.5 transport self-check after each PC connects,
///  * the §4.6 layer / subscription policy,
///  * ICE restart on a network change and the §4.7 failure ladder (WebSocket
///    reclaim, then a request for a full rejoin).
///
/// It knows nothing about WebRTC types or about the app: the controller wires
/// PeerConnection wrappers in through `GroupPublisherLink` /
/// `GroupSubscriberLink` and reacts to `Event`s.
public final class GroupMediaSession: @unchecked Sendable {

    public enum State: Equatable, Sendable {
        case idle
        case connecting
        case active
        case reconnecting
        case closed
    }

    public enum Failure: Error, Equatable, Sendable {
        case dtlsPinMismatch(pc: GroupTelemetry.PcRole)
        case transportPolicy(pc: GroupTelemetry.PcRole, fields: [String])
        case protocolViolation(String)
    }

    public enum Event: @unchecked Sendable {
        case state(State)
        /// The full set of remote publishers now in the room (self excluded).
        case remotePublishers([VideoRoomPublisher])
        case pcState(GroupTelemetry.PcRole, GroupPcState)
        /// The session cannot recover on its own: the controller asks the
        /// server for a fresh `group_call_media_rejoin`.
        case needsRejoin(String)
        /// Unrecoverable (pin mismatch, transport policy, refused request).
        case failed(Failure)
        /// A Janus request error that `JanusErrorPolicy` says to surface.
        case janusFailure(JanusClientError)
        /// The server removed us from the Janus room.
        case kicked
        /// Janus reported a slow uplink for the publisher.
        case uplinkCongested
        /// Decoded audio level per publisher pseudonym, every stats tick.
        case audioLevels([String: Double])
        case telemetry(GroupTelemetryEvent)
    }

    public struct Config: Sendable {
        public var reconnectBackoffSeconds: [Double] = [0.5, 1, 2, 4]
        /// "DTLS/ICE not connected within 10 s of a restart -> rejoin" (§4.7).
        public var restartWatchdogSeconds: Double = 10
        public var statsIntervalSeconds: Double = 1
        public var transportCheckAttempts = 12
        public var transportCheckIntervalMs: UInt64 = 250
        public var debounceMs: UInt64 = GroupSerialQueue.defaultDebounceMs

        public init() {}
    }

    public var onEvent: ((Event) -> Void)?
    /// Decides which publishers the session may subscribe to: the controller
    /// only lets pseudonyms of current call members through, so a stranger who
    /// somehow shows up in the Janus room is never rendered. Call
    /// `refreshPublisherFilter()` after the roster changes.
    public var publisherFilter: ((String) -> Bool)?

    public let config: Config

    private let janus: JanusClient
    private let room: VideoRoomClient
    private let publisher: GroupPublisherLink
    private let makeSubscriber: () -> GroupSubscriberLink
    private let dtlsFingerprint: String
    private let policy: GroupLayerPolicy
    private let nowMs: () -> Int64

    private let pubQueue: GroupSerialQueue
    private let subQueue: GroupSerialQueue

    private let lock = NSLock()
    private var state: State = .idle
    private var pubHandle: Int64?
    private var subHandle: Int64?
    private var privateId: Int64?
    private var subscriber: GroupSubscriberLink?
    private var remotePublishers: [String: VideoRoomPublisher] = [:]
    /// Every publisher Janus reported, before `publisherFilter`.
    private var rawPublishers: [String: VideoRoomPublisher] = [:]
    /// Subscribed (feed, feed mid) pairs, as acknowledged by Janus.
    private var subscribed: Set<String> = []
    /// Subscriber mid -> stream, from the last `attached` / `updated`.
    private var subscriberStreams: [String: VideoRoomStream] = [:]
    private var desiredLayers: [String: (substream: Int, temporal: Int)] = [:]
    private var appliedLayers: [String: (substream: Int, temporal: Int)] = [:]
    private var lastStats: [String: GroupInboundVideoStat] = [:]
    private var pcStates: [GroupTelemetry.PcRole: GroupPcState] = [:]
    private var statsTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var disconnectTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var closed = false

    public init(janus: JanusClient,
                room: VideoRoomClient,
                publisher: GroupPublisherLink,
                makeSubscriber: @escaping () -> GroupSubscriberLink,
                dtlsFingerprint: String,
                layerPolicy: GroupLayerPolicy = GroupLayerPolicy(),
                config: Config = Config(),
                nowMs: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.janus = janus
        self.room = room
        self.publisher = publisher
        self.makeSubscriber = makeSubscriber
        self.dtlsFingerprint = dtlsFingerprint
        self.policy = layerPolicy
        self.config = config
        self.nowMs = nowMs
        self.pubQueue = GroupSerialQueue(debounceMs: config.debounceMs)
        self.subQueue = GroupSerialQueue(debounceMs: config.debounceMs)
    }

    public var currentState: State {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    // MARK: - Bring-up

    /// Connects, joins, publishes. Throws `JanusClientError` or `Failure`.
    public func start(publishVideo: Bool) async throws {
        setState(.connecting)
        janus.onEvent = { [weak self] message in self?.handle(message) }
        janus.onTransportClosed = { [weak self] error in self?.transportClosed(error) }
        publisher.onState = { [weak self] pcState in self?.pcStateChanged(.pub, pcState) }
        do {
            _ = try await janus.connect()
            let handle = try await janus.attach()
            lock.lock(); pubHandle = handle; lock.unlock()
            let joined = try await withTimeoutRetry { try await self.room.joinPublisher(handle: handle) }
            lock.lock(); privateId = joined.privateId; lock.unlock()

            publisher.onCandidate = { [weak self] candidate in self?.forwardCandidate(handle: handle, candidate) }
            try await publisher.start()
            let offer = try await publisher.createOffer(iceRestart: false)
            let descriptions = GroupSdpRules.videoMids(in: offer).map { (mid: $0, description: "camera") }
            let answer = try await withTimeoutRetry {
                try await self.room.publish(handle: handle, offer: offer, audio: true, video: publishVideo,
                                            descriptions: descriptions)
            }
            try checkPin(answer, pc: .pub)
            try await publisher.applyAnswer(answer)

            adoptPublishers(joined.publishers)
            setState(.active)
            startStatsLoop()
        } catch {
            close()
            throw error
        }
    }

    // MARK: - Inputs from the controller

    /// Tile / visibility of every video stream of `pseudonym`.
    public func setTile(pseudonym: String, tile: GroupLayerPolicy.TileClass, visible: Bool) {
        lock.lock()
        let publisherEntry = remotePublishers[pseudonym]
        lock.unlock()
        guard let entry = publisherEntry else { return }
        lock.lock()
        for stream in entry.streams where stream.isVideo {
            policy.setTile(key: Self.key(feed: pseudonym, mid: stream.mid),
                           tile: stream.isScreenShare ? .fullscreen : tile, visible: visible)
        }
        lock.unlock()
        evaluatePolicy()
    }

    /// App backgrounded: unsubscribe every remote video (§4.6). The caller
    /// pauses the local video publish itself (`setPublishVideo(false)`).
    public func setBackgrounded(_ value: Bool) {
        lock.lock()
        policy.setBackgrounded(value)
        lock.unlock()
        evaluatePolicy()
    }

    /// `configure video:true|false` on the publisher (camera on / off, or the
    /// congestion policy stopping the video publish).
    public func setPublishVideo(_ on: Bool) async {
        guard let handle = currentPubHandle() else { return }
        await pubQueue.run {
            _ = try? await self.room.configurePublisher(handle: handle, video: on)
        }
    }

    /// Asks the publisher (through Janus) for a video key frame: the frame that
    /// makes a rotated key usable on every receiver (§5.4).
    public func requestPublisherKeyFrame() async {
        guard let handle = currentPubHandle() else { return }
        _ = try? await room.configurePublisher(handle: handle, keyframe: true)
    }

    /// Wi-Fi <-> cellular / IP change: ICE restart on BOTH PCs (§4.7).
    public func networkPathChanged(reason: String) async {
        guard currentState == .active || currentState == .reconnecting else { return }
        emit(.telemetry(GroupTelemetry.iceRestart(reason: reason)))
        armRestartWatchdog()
        await restartPublisherIce()
        await restartSubscriberIce()
    }

    public func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        state = .closed
        let tasks = [statsTask, watchdogTask, disconnectTask, reconnectTask]
        statsTask = nil
        watchdogTask = nil
        disconnectTask = nil
        reconnectTask = nil
        let sub = subscriber
        subscriber = nil
        lock.unlock()
        for task in tasks { task?.cancel() }
        Task { [pubQueue, subQueue] in
            await pubQueue.cancelPending()
            await subQueue.cancelPending()
        }
        janus.onEvent = nil
        janus.onTransportClosed = nil
        publisher.onState = nil
        publisher.onCandidate = nil
        sub?.onState = nil
        sub?.onCandidate = nil
        janus.close()
        publisher.close()
        sub?.close()
        emit(.state(.closed))
    }

    // MARK: - Publishers / subscriptions

    static func key(feed: String, mid: String) -> String { "\(feed)|\(mid)" }

    private func adoptPublishers(_ list: [VideoRoomPublisher]) {
        lock.lock()
        rawPublishers = [:]
        for entry in list { rawPublishers[entry.id] = entry }
        let snapshot = applyPublisherFilterLocked()
        lock.unlock()
        emit(.remotePublishers(snapshot))
        evaluatePolicy()
        scheduleReconcile()
    }

    private func mergePublishers(_ list: [VideoRoomPublisher]) {
        lock.lock()
        for entry in list where entry.id != room.pseudonym { rawPublishers[entry.id] = entry }
        let snapshot = applyPublisherFilterLocked()
        lock.unlock()
        emit(.remotePublishers(snapshot))
        evaluatePolicy()
        scheduleReconcile()
    }

    private func removePublisher(_ id: String) {
        lock.lock()
        rawPublishers[id] = nil
        // Janus drops the departed publisher's streams from the subscriber
        // itself (an unsolicited `updated` + offer): no `unsubscribe` is sent.
        forgetSubscriptionsLocked(of: id)
        let snapshot = applyPublisherFilterLocked()
        lock.unlock()
        emit(.remotePublishers(snapshot))
        scheduleReconcile()
    }

    /// Re-applies `publisherFilter` (the roster changed).
    public func refreshPublisherFilter() {
        lock.lock()
        let snapshot = applyPublisherFilterLocked()
        lock.unlock()
        emit(.remotePublishers(snapshot))
        evaluatePolicy()
        scheduleReconcile()
    }

    /// Rebuilds `remotePublishers` from `rawPublishers` through the filter.
    private func applyPublisherFilterLocked() -> [VideoRoomPublisher] {
        let filter = publisherFilter
        var accepted: [String: VideoRoomPublisher] = [:]
        for (id, entry) in rawPublishers where filter?(id) ?? true { accepted[id] = entry }
        for (id, entry) in remotePublishers where accepted[id] == nil {
            for stream in entry.streams where stream.isVideo {
                policy.unregister(key: Self.key(feed: id, mid: stream.mid))
            }
        }
        for id in remotePublishers.keys where accepted[id] == nil { forgetSubscriptionsLocked(of: id) }
        remotePublishers = accepted
        registerVideoStreamsLocked()
        return Array(accepted.values)
    }

    private func forgetSubscriptionsLocked(of id: String) {
        let prefix = id + "|"
        subscribed = subscribed.filter { !$0.hasPrefix(prefix) }
        desiredLayers = desiredLayers.filter { !$0.key.hasPrefix(prefix) }
        appliedLayers = appliedLayers.filter { !$0.key.hasPrefix(prefix) }
    }

    private func registerVideoStreamsLocked() {
        for entry in remotePublishers.values {
            for stream in entry.streams where stream.isVideo && !stream.disabled {
                policy.register(key: Self.key(feed: entry.id, mid: stream.mid))
            }
        }
    }

    /// (feed, feed mid) pairs we want subscribed right now: every audio stream,
    /// every video stream the policy wants.
    private func desiredTargetsLocked() -> Set<String> {
        var out = Set<String>()
        for entry in remotePublishers.values {
            for stream in entry.streams where !stream.disabled {
                let key = Self.key(feed: entry.id, mid: stream.mid)
                if stream.isAudio || (stream.isVideo && policy.isSubscribed(key: key)) { out.insert(key) }
            }
        }
        return out
    }

    private func scheduleReconcile() {
        Task { [subQueue] in
            await subQueue.debounce(key: "reconcile") { [weak self] in
                await self?.reconcileSubscriptions()
            }
        }
    }

    private func reconcileSubscriptions() async {
        if isClosed { return }
        lock.lock()
        let desired = desiredTargetsLocked()
        let toAdd = desired.subtracting(subscribed)
        let toRemove = subscribed.subtracting(desired)
        let privateIdValue = privateId
        lock.unlock()
        guard !toAdd.isEmpty || !toRemove.isEmpty, let privateIdValue = privateIdValue else {
            await applyDesiredLayers()
            return
        }
        do {
            if !toAdd.isEmpty {
                try await subscribe(targets: toAdd, privateId: privateIdValue)
            }
            if !toRemove.isEmpty {
                try await unsubscribe(targets: toRemove)
            }
            await applyDesiredLayers()
        } catch {
            handleRequestError(error, context: "subscribe")
        }
    }

    private static func target(from key: String) -> VideoRoomSubscribeTarget {
        let parts = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        return VideoRoomSubscribeTarget(feed: String(parts[0]), mid: parts.count > 1 ? String(parts[1]) : nil)
    }

    private func subscribe(targets: Set<String>, privateId: Int64) async throws {
        let list = targets.sorted().map { Self.target(from: $0) }
        var handle = currentSubHandle()
        let reply: JanusMessage
        if handle == nil {
            let newHandle = try await janus.attach()
            let link = makeSubscriber()
            link.onState = { [weak self] pcState in self?.pcStateChanged(.sub, pcState) }
            link.onCandidate = { [weak self] candidate in self?.forwardCandidate(handle: newHandle, candidate) }
            lock.lock()
            subHandle = newHandle
            subscriber = link
            lock.unlock()
            try await link.start()
            handle = newHandle
            reply = try await withTimeoutRetry { try await self.room.joinSubscriber(handle: newHandle, privateId: privateId, targets: list) }
        } else {
            reply = try await withTimeoutRetry { try await self.room.subscribe(handle: handle!, targets: list) }
        }
        lock.lock()
        subscribed.formUnion(targets)
        lock.unlock()
        try await processSubscriberReply(reply, handle: handle!)
    }

    private func unsubscribe(targets: Set<String>) async throws {
        guard let handle = currentSubHandle() else { return }
        let list = targets.sorted().map { Self.target(from: $0) }
        let reply: JanusMessage
        do {
            reply = try await withTimeoutRetry { try await self.room.unsubscribe(handle: handle, targets: list) }
        } catch JanusClientError.plugin(let code, _) where code == 428 {
            // The feed is already gone on the node: only our bookkeeping is left.
            lock.lock()
            subscribed.subtract(targets)
            lock.unlock()
            return
        }
        lock.lock()
        subscribed.subtract(targets)
        for (mid, stream) in subscriberStreams {
            if let feed = stream.feedId, let feedMid = stream.feedMid,
               targets.contains(Self.key(feed: feed, mid: feedMid)) {
                subscriberStreams[mid] = nil
                appliedLayers[Self.key(feed: feed, mid: feedMid)] = nil
            }
        }
        lock.unlock()
        try await processSubscriberReply(reply, handle: handle)
    }

    /// Takes the stream mapping of an `attached` / `updated` event and, if it
    /// carries Janus' offer, answers it. Always runs inside the subscriber
    /// queue's critical section or directly under a request that owns it.
    private func processSubscriberReply(_ message: JanusMessage, handle: Int64) async throws {
        let event = VideoRoomEvent.parse(message.pluginData ?? [:])
        switch event {
        case .attached(let streams), .updated(let streams):
            lock.lock()
            for stream in streams {
                if stream.feedId != nil { subscriberStreams[stream.mid] = stream }
            }
            lock.unlock()
        default:
            break
        }
        guard let jsep = message.jsep, jsep.type == "offer" else { return }
        try checkPin(jsep.sdp, pc: .sub)
        guard let link = currentSubscriber() else { throw Failure.protocolViolation("no_subscriber") }
        lock.lock()
        let streams = Array(subscriberStreams.values)
        lock.unlock()
        let answer = try await link.acceptOffer(jsep.sdp, streams: streams)
        try await withTimeoutRetry { try await self.room.start(handle: handle, answer: answer) }
    }

    // MARK: - Layer policy

    private func evaluatePolicy() {
        lock.lock()
        let actions = policy.evaluate(nowMs: nowMs())
        var changed = false
        for action in actions {
            switch action {
            case .subscribe, .unsubscribe:
                changed = true
            case .configure(let key, let substream, let temporal, let from, let reason):
                desiredLayers[key] = (substream: substream, temporal: temporal)
                appliedLayers[key] = nil
                emitLocked(.telemetry(GroupTelemetry.layer(mid: key.split(separator: "|").last.map(String.init) ?? key,
                                                            from: from, to: substream, reason: reason)))
            }
        }
        lock.unlock()
        if changed { scheduleReconcile() } else if !actions.isEmpty { scheduleLayerApply() }
    }

    private func scheduleLayerApply() {
        Task { [subQueue] in
            await subQueue.debounce(key: "layers") { [weak self] in
                await self?.applyDesiredLayers()
            }
        }
    }

    private func applyDesiredLayers() async {
        guard let handle = currentSubHandle() else { return }
        lock.lock()
        var pendingKeys: [String] = []
        var configs: [VideoRoomLayerConfig] = []
        for (key, layer) in desiredLayers {
            if let applied = appliedLayers[key], applied.substream == layer.substream, applied.temporal == layer.temporal { continue }
            // Find the subscriber-side mid of this (feed, feed mid).
            guard let entry = subscriberStreams.first(where: { item in
                guard let feed = item.value.feedId, let feedMid = item.value.feedMid else { return false }
                return Self.key(feed: feed, mid: feedMid) == key
            }) else { continue }
            configs.append(VideoRoomLayerConfig(mid: entry.key, substream: layer.substream, temporal: layer.temporal))
            pendingKeys.append(key)
        }
        lock.unlock()
        guard !configs.isEmpty else { return }
        do {
            _ = try await withTimeoutRetry { try await self.room.configureSubscriber(handle: handle, layers: configs) }
            lock.lock()
            for key in pendingKeys { appliedLayers[key] = desiredLayers[key] }
            lock.unlock()
        } catch {
            handleRequestError(error, context: "configure")
        }
    }

    private func startStatsLoop() {
        let interval = config.statsIntervalSeconds
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.pollStats()
            }
        }
        lock.lock()
        statsTask?.cancel()
        statsTask = task
        lock.unlock()
    }

    private func pollStats() async {
        guard let link = currentSubscriber(), let stats = await link.inboundStats() else {
            evaluatePolicy()
            return
        }
        let now = nowMs()
        lock.lock()
        for video in stats.videos {
            guard let stream = subscriberStreams[video.mid], let feed = stream.feedId, let feedMid = stream.feedMid else { continue }
            let key = Self.key(feed: feed, mid: feedMid)
            if let previous = lastStats[video.mid] {
                policy.onLossSample(key: key,
                                    packetsLostDelta: video.packetsLost - previous.packetsLost,
                                    packetsReceivedDelta: video.packetsReceived - previous.packetsReceived,
                                    nowMs: now)
            }
            lastStats[video.mid] = video
        }
        if let bps = stats.availableIncomingBps { policy.onBandwidthSample(availableBps: bps, nowMs: now) }
        var levelsByFeed: [String: Double] = [:]
        for (mid, level) in stats.audioLevels {
            if let feed = subscriberStreams[mid]?.feedId { levelsByFeed[feed] = max(levelsByFeed[feed] ?? 0, level) }
        }
        lock.unlock()
        if !levelsByFeed.isEmpty { emit(.audioLevels(levelsByFeed)) }
        evaluatePolicy()
    }

    // MARK: - Janus events

    private func handle(_ message: JanusMessage) {
        if isClosed { return }
        let pub = currentPubHandle()
        let sub = currentSubHandle()
        switch message.kind {
        case .event:
            let event = VideoRoomEvent.parse(message.pluginData ?? [:])
            if message.sender == sub, let sub = sub {
                switch event {
                case .attached, .updated:
                    Task { [subQueue] in
                        await subQueue.run {
                            do {
                                try await self.processSubscriberReply(message, handle: sub)
                            } catch {
                                self.handleRequestError(error, context: "offer")
                            }
                        }
                    }
                default:
                    break
                }
                return
            }
            switch event {
            case .publishers(let list): mergePublishers(list)
            case .unpublished(let id), .leaving(let id): if id != "ok" { removePublisher(id) }
            case .kicked: emit(.kicked)
            case .destroyed: emit(.needsRejoin("room_destroyed"))
            default: break
            }
        case .slowlink:
            if message.sender == sub {
                lock.lock()
                policy.onSlowlink(nowMs: nowMs())
                lock.unlock()
                evaluatePolicy()
            } else if message.sender == pub {
                emit(.uplinkCongested)
            }
        case .hangup:
            if message.sender == pub || message.sender == sub { emit(.needsRejoin("janus_hangup")) }
        case .timeout:
            emit(.needsRejoin("janus_timeout"))
        case .trickle:
            if let dict = message.raw["candidate"] as? [String: Any] {
                let candidate: GroupIceCandidate?
                if let text = dict["candidate"] as? String, dict["completed"] == nil {
                    candidate = GroupIceCandidate(
                        sdpMid: dict["sdpMid"] as? String,
                        sdpMLineIndex: Int32((dict["sdpMLineIndex"] as? NSNumber)?.intValue ?? 0),
                        candidate: text)
                } else {
                    candidate = nil
                }
                let link: GroupPeerLink? = message.sender == sub ? currentSubscriber() : publisher
                if let link = link { Task { await link.addRemoteCandidate(candidate) } }
            }
        default:
            break
        }
    }

    private func forwardCandidate(handle: Int64, _ candidate: GroupIceCandidate?) {
        if isClosed { return }
        if let c = candidate {
            janus.trickle(handle: handle, candidate: (sdpMid: c.sdpMid, sdpMLineIndex: c.sdpMLineIndex, candidate: c.candidate))
        } else {
            janus.trickle(handle: handle, candidate: nil)
        }
    }

    // MARK: - PC state, self-check, watchdogs

    private func pcStateChanged(_ role: GroupTelemetry.PcRole, _ pcState: GroupPcState) {
        if isClosed { return }
        lock.lock()
        pcStates[role] = pcState
        let disconnect = disconnectTask
        if pcState == .connected {
            disconnectTask = nil
        }
        lock.unlock()
        emit(.pcState(role, pcState))
        emit(.telemetry(GroupTelemetry.pcState(role, state: pcState.rawValue)))
        switch pcState {
        case .connected:
            disconnect?.cancel()
            lock.lock()
            let bothConnected = pcStates[.pub] == .connected && (subscriber == nil || pcStates[.sub] == .connected)
            let watchdog = bothConnected ? watchdogTask : nil
            if bothConnected { watchdogTask = nil }
            lock.unlock()
            watchdog?.cancel()
            verifyTransport(role)
        case .failed:
            emit(.needsRejoin("pc_failed"))
        case .disconnected:
            armDisconnectTimer()
        default:
            break
        }
    }

    private func armDisconnectTimer() {
        let seconds = config.restartWatchdogSeconds
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return }
            self?.emit(.needsRejoin("pc_disconnected"))
        }
        lock.lock()
        disconnectTask?.cancel()
        disconnectTask = task
        lock.unlock()
    }

    private func armRestartWatchdog() {
        let seconds = config.restartWatchdogSeconds
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return }
            guard let self = self else { return }
            // A restart that completes without the PeerConnection ever leaving
            // `connected` raises no new state event: look at the states now.
            self.lock.lock()
            let connected = self.pcStates[.pub] == .connected
                && (self.subscriber == nil || self.pcStates[.sub] == .connected)
            self.lock.unlock()
            if !connected { self.emit(.needsRejoin("ice_restart_timeout")) }
        }
        lock.lock()
        watchdogTask?.cancel()
        watchdogTask = task
        lock.unlock()
    }

    private func verifyTransport(_ role: GroupTelemetry.PcRole) {
        let link: GroupPeerLink? = role == .pub ? publisher : currentSubscriber()
        guard let link = link else { return }
        let attempts = config.transportCheckAttempts
        let intervalMs = config.transportCheckIntervalMs
        Task { [weak self] in
            for _ in 0..<attempts {
                guard let self = self, !self.isClosed else { return }
                guard let observed = await link.transportObservation() else {
                    try? await Task.sleep(nanoseconds: intervalMs * 1_000_000)
                    continue
                }
                switch GroupTransportPolicy.evaluate(observed) {
                case .ok:
                    self.emit(.telemetry(GroupTelemetry.transport(observed)))
                    return
                case .violation(let fields):
                    self.emit(.telemetry(GroupTelemetry.transport(observed)))
                    self.emit(.telemetry(GroupTelemetry.transportPolicyViolation(role, fields: fields)))
                    self.failHard(.transportPolicy(pc: role, fields: fields))
                    return
                case .notReady:
                    try? await Task.sleep(nanoseconds: intervalMs * 1_000_000)
                }
            }
            // The stats never filled in: nothing proves the level, so refuse.
            guard let self = self, !self.isClosed else { return }
            self.emit(.telemetry(GroupTelemetry.transportPolicyViolation(role, fields: ["stats"])))
            self.failHard(.transportPolicy(pc: role, fields: ["stats"]))
        }
    }

    private func checkPin(_ sdp: String, pc: GroupTelemetry.PcRole) throws {
        switch GroupSdpRules.checkPin(sdp: sdp, expected: dtlsFingerprint) {
        case .match:
            return
        case .mismatch, .missing:
            emit(.telemetry(GroupTelemetry.dtlsPinMismatch(pc)))
            throw Failure.dtlsPinMismatch(pc: pc)
        }
    }

    /// Both PeerConnections are closed and the failure is reported.
    private func failHard(_ failure: Failure) {
        emit(.failed(failure))
        close()
    }

    // MARK: - ICE restart

    private func restartPublisherIce() async {
        guard let handle = currentPubHandle() else { return }
        await pubQueue.run {
            do {
                let offer = try await self.publisher.createOffer(iceRestart: true)
                guard let answer = try await self.room.configurePublisher(handle: handle, restartOffer: offer) else { return }
                try self.checkPin(answer, pc: .pub)
                try await self.publisher.applyAnswer(answer)
            } catch let failure as Failure {
                self.failHard(failure)
            } catch {
                self.handleRequestError(error, context: "ice_restart")
            }
        }
    }

    private func restartSubscriberIce() async {
        guard let handle = currentSubHandle() else { return }
        await subQueue.run {
            do {
                let reply = try await self.room.configureSubscriber(handle: handle, layers: [], restart: true)
                try await self.processSubscriberReply(reply, handle: handle)
            } catch let failure as Failure {
                self.failHard(failure)
            } catch {
                self.handleRequestError(error, context: "ice_restart")
            }
        }
    }

    // MARK: - WebSocket loss (§4.7)

    private func transportClosed(_ error: Error?) {
        lock.lock()
        if closed || reconnectTask != nil {
            lock.unlock()
            return
        }
        let backoff = config.reconnectBackoffSeconds
        let task = Task { [weak self] in
            for seconds in backoff {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard let self = self, !Task.isCancelled, !self.isClosed else { return }
                do {
                    try await self.janus.reclaim()
                    self.lock.lock()
                    self.reconnectTask = nil
                    self.lock.unlock()
                    self.setState(.active)
                    self.evaluatePolicy()
                    self.scheduleReconcile()
                    return
                } catch let error as JanusClientError {
                    // Session gone: nothing to reclaim, go straight to a rejoin.
                    if error.code == 458 { break }
                } catch {
                    continue
                }
            }
            guard let self = self, !self.isClosed else { return }
            self.emit(.needsRejoin("ws_lost"))
        }
        reconnectTask = task
        lock.unlock()
        setState(.reconnecting)
    }

    // MARK: - Errors

    /// One retry on a timeout, as spec §8 requires; everything else throws.
    private func withTimeoutRetry<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch JanusClientError.timeout {
            return try await operation()
        }
    }

    private func handleRequestError(_ error: Error, context: String) {
        if isClosed { return }
        if let failure = error as? Failure {
            failHard(failure)
            return
        }
        guard let janusError = error as? JanusClientError else {
            emit(.needsRejoin("error_\(context)"))
            return
        }
        switch janusError {
        case .timeout, .closed, .notConnected:
            // While the WebSocket is being reclaimed the reconnect logic owns
            // recovery; the requests it cut off are re-driven afterwards.
            if currentState == .reconnecting { return }
            // Second timeout in a row: recover by rejoining.
            emit(.needsRejoin("timeout_\(context)"))
        case .malformed:
            emit(.needsRejoin("malformed_\(context)"))
        case .janus, .plugin:
            switch JanusErrorPolicy.action(for: janusError) {
            case .retryMediaJoin: emit(.needsRejoin("janus_\(janusError.code ?? 0)"))
            case .fail: emit(.janusFailure(janusError))
            }
        }
    }

    // MARK: - Small helpers

    private var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    private func currentPubHandle() -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return pubHandle
    }

    private func currentSubHandle() -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return subHandle
    }

    private func currentSubscriber() -> GroupSubscriberLink? {
        lock.lock(); defer { lock.unlock() }
        return subscriber
    }

    private func setState(_ newState: State) {
        lock.lock()
        if closed && newState != .closed {
            lock.unlock()
            return
        }
        let changed = state != newState
        state = newState
        lock.unlock()
        if changed { emit(.state(newState)) }
    }

    private func emit(_ event: Event) {
        onEvent?(event)
    }

    /// `emit` for call sites that hold `lock`: the handler runs later, off the
    /// lock, so it can never re-enter this object while it is held.
    private func emitLocked(_ event: Event) {
        let handler = onEvent
        DispatchQueue.global(qos: .utility).async { handler?(event) }
    }
}

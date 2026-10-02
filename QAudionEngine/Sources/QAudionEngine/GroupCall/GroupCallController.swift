import Foundation

/// Group calls v2 — the client-side call controller: one call at a time, over
/// qjanus (Janus VideoRoom) with two PeerConnections per call (spec §0).
///
/// Responsibilities:
///  1. Bridge `BCryptoGroupCallManager` (roster, invites, `group_call_media_*`)
///     to the media layer: on `media_ready` build a `GroupMediaLink` (Janus
///     session + publisher + multistream subscriber) through the
///     `GroupMediaBackend`, and rebuild it on every rejoin.
///  2. E2EE v2 (spec §5): drive `GroupE2eeCoordinator` — a fresh random key per
///     member per server epoch, distributed over the existing pairwise sealed
///     control channel (`onSendControlEnvelope` / `onGroupCallControlEnvelope`),
///     installed into the native FrameCryptor key ring by the backend.
///  3. Failure ladder (spec §4.7 / §8) through `GroupMediaRecoveryPolicy`:
///     rejoin with backoff, one automatic media join for a retryable Janus
///     error, a visible error otherwise. There is NO relay fallback.
///  4. Tiles keyed by user id: Janus feeds are pseudonyms, the roster's
///     pseudonym map turns them back into users for the view layer.
///  5. Audio unit (`GroupAudioUnitControlling`), camera / microphone, the thermal
///     and congestion publish policy, reactions / raised hands / mute requests.
///
/// Logging rule (spec §7): call ids and pseudonyms at most 8 characters, never
/// keys, tokens, fingerprints, ICE credentials or addresses.
public final class GroupCallController: @unchecked Sendable {

    public enum State: Equatable {
        case idle
        case connecting(callId: String)
        case active(callId: String, participants: [String])
        case failed(reason: String)
    }

    private var _state: State = .idle
    public var state: State { lock.lock(); defer { lock.unlock() }; return _state }
    public var onStateChange: ((State) -> Void)?

    // MARK: - Dependencies

    private var manager: BCryptoGroupCallManager
    private let backend: GroupMediaBackend?
    private let audio: GroupAudioUnitControlling
    private let pathMonitor: GroupPathMonitoring
    private let nowMs: () -> Int64
    /// How long a refresh request waits for its answer before it is asked again.
    private let iceRefreshRetrySeconds: Double
    /// How long a `group_call_media_join` / `group_call_media_rejoin` waits for its
    /// `group_call_media_ready`. The server answers nothing to a member that is over its
    /// request budget, so an unanswered request is waited out, never hammered.
    private let mediaReadyTimeoutSeconds: Double
    /// How long a `group_call_media_refresh` waits for its `group_call_media_token`. The
    /// server answers nothing to a member over its budget, so a missing answer is the only
    /// sign of a lost request.
    private let tokenReplyTimeoutSeconds: Double
    /// Waits between the attempts of one token-refresh round (so a round is
    /// `tokenRetryBackoffSeconds.count + 1` attempts), each +-25 % jittered: always above the
    /// server's 5 s per-(call, member) interval and far below its 12 per minute.
    private let tokenRetryBackoffSeconds: [Double]
    private static let iceRefreshMaxAttempts = 3
    /// A late answer (after the retries) of a refresh is still a refresh, not a new path.
    private static let iceRefreshAnswerWindowMs: Int64 = 300_000
    private let lock = NSLock()
    /// Every `GroupE2eeCoordinator` call runs here (the coordinator is not
    /// thread-safe, and its send completions come back on this queue).
    private let e2eeQueue = DispatchQueue(label: "com.bcrypto.qaudion.groupcall.e2ee", qos: .userInitiated)

    // MARK: - Per-call state (guarded by `lock`)

    private var activeCallId: String?
    private var createdLocally = false
    private var wantsVideo = false
    private var muted = false
    private var cameraOn = false
    private var lastUpdate: GroupCallWire.Update?
    private var currentReady: GroupCallWire.MediaReady?
    private var link: GroupMediaLink?
    /// Bumped whenever the link is replaced or closed: events of an older link
    /// are ignored.
    private var linkGeneration = 0
    private var coordinator: GroupE2eeCoordinator?
    /// `media_key` envelopes that arrived before this call began (a push-woken accept
    /// joins asynchronously while the peers already sent their keys): replayed into the
    /// coordinator of the call they belong to, dropped after 15 s.
    private var earlyKeys: [(envelope: GroupKeyEnvelope, user: String, atMs: Int64)] = []
    private var recovery = GroupMediaRecoveryPolicy()
    private var speaking = GroupSpeakingDetector()
    private var mediaJoinRequested = false
    private var mediaJoinRequestedAtMs: Int64 = 0
    private var mediaReadyTimeout: DispatchWorkItem?
    private var mediaReadyRetried = false
    /// The reason of the `group_call_media_rejoin` whose answer is awaited, nil while a plain
    /// `group_call_media_join` is. An unanswered request is asked again AS THE SAME KIND: a
    /// join sent for a Janus session that died can hit Janus 436 (the old participant is
    /// still in the room), a rejoin makes the server clean that up first.
    private var rejoinReasonInFlight: String?
    private var mediaConnected = false
    private var connectedTelemetrySent = false
    private var congestionSteps = 0
    private var congestionReset: DispatchWorkItem?
    /// An hourly TURN-credential refresh (`group_call_media_join`) is awaiting its answer.
    private var iceRefreshPending = false
    private var iceRefreshAttempts = 0
    private var iceRefreshRetry: DispatchWorkItem?
    /// When the last refresh request went out (0 = none this call): an answer with the
    /// same media identity within `iceRefreshAnswerWindowMs` of it is applied in place.
    private var iceRefreshRequestedAtMs: Int64 = 0
    /// A Janus-session token refresh (`group_call_media_refresh`) is awaiting its answer, for
    /// the link of `tokenRefreshGeneration` (a stale one of an older link counts as none).
    private var tokenRefreshPending = false
    private var tokenRefreshGeneration = 0
    private var tokenRefreshAttempt = 0
    private var tokenRefreshTimer: DispatchWorkItem?
    private var videoStoppedByPolicy = false
    private var backgrounded = false
    private var desiredTiles: [String: (tile: GroupLayerPolicy.TileClass, visible: Bool)] = [:]
    private var lastAudioActivation: AudioSessionActivationSource?
    private var thermalObserver: NSObjectProtocol?
    private var powerObserver: NSObjectProtocol?
    /// Bug-report snapshot of this call (`diagSnapshot()`): the last media error shown,
    /// each PeerConnection's state code, and the last diagnosis values per slot
    /// ("ice", "tx", "video", "rx:<mid>"). Numbers only.
    private var diagLastErrorCode = 0
    private var diagPcStates: [String: Int] = [:]
    private var diagSlots: [String: [String: Int]] = [:]

    // Tier-1: transient reactions + raised-hand state (in memory only).
    private var _reactionEvents: [ReactionEvent] = []
    private var _raisedHands: Set<String> = []

    // MARK: - Callbacks to the app layer

    /// Remote stream callbacks. `identity` is the USER id (mapped from the Janus
    /// pseudonym); a nil track means the stream went away. Tracks are type-erased
    /// `RTCMediaStreamTrack`s, rendered by `GroupCallVideoView`; remote audio
    /// plays through WebRTC's own audio unit, the audio callback only exists so
    /// the app can re-assert the speaker route.
    public var onRemoteAudioTrack: ((_ identity: String, _ track: AnyObject?) -> Void)?
    public var onRemoteVideoTrack: ((_ identity: String, _ track: AnyObject?) -> Void)?
    public var onRemoteScreenShareTrack: ((_ identity: String, _ track: AnyObject?) -> Void)?
    /// Our own camera track (nil = camera off), for the self tile.
    public var onLocalVideoTrack: ((_ track: AnyObject?) -> Void)?
    /// User ids currently speaking, loudest first (receiver-side, decoded audio
    /// level: the audio-level RTP extension is not negotiated, spec §4.4).
    public var onActiveSpeakersChanged: (([String]) -> Void)?
    public var onMuteRequested: ((_ requesterId: String) -> Void)?
    /// The microphone switch changed, whatever moved it: the button, a peer's mute
    /// request, CallKit, the state a call begins with (a 1:1 -> group hand-over starts
    /// muted when the 1:1 leg was) or the reset when the call ends. Fired once per
    /// CHANGE, never for a repeat of the current value, so the app layer can mirror it
    /// to the roster badge and to the system call UI without looping.
    public var onMutedChanged: ((_ muted: Bool) -> Void)?
    /// A clear, user-visible media error (spec §2.4 / §8). Fatal ones end the
    /// call right after; a camera problem does not.
    public var onMediaError: ((GroupCallMediaError) -> Void)?
    /// Both directions of the media path are up (fires on every (re)connect).
    public var onMediaConnected: (() -> Void)?
    /// The server ended the call we are in (`group_call_ended` with its reason).
    public var onCallEnded: ((_ callId: String, _ reason: String) -> Void)?
    /// The audio unit needs a session activation (after a 1:1 call released it).
    public var onNeedsAudioSessionActivation: (() -> Void)?
    /// Passthroughs of the manager's roster callbacks (single-slot on the manager,
    /// owned by this controller).
    public var onManagerStateChanged: ((BCryptoGroupCallManager.State) -> Void)?
    public var onParticipantsChanged: (([BCryptoGroupCallManager.Participant]) -> Void)?

    /// Forwards this call's media telemetry to the app layer (QAudionEngine cannot
    /// import QAudionApp). Kinds: the spec §7 `group.*` set plus the
    /// `call.media.connected` / `call.media.ended` pair the shared per-call
    /// tracker consumes.
    public var groupTelemetry: ((_ kind: String, _ callId: String?, _ attrs: [String: Any]) -> Void)?

    /// Diagnosis lines for the phone log (`GroupDiagnostics`: enum codes and counters
    /// only, shapes the log shipper keeps verbatim). The app writes them with RTLog tag
    /// "group". Called from any thread.
    public var diagLog: ((_ line: String) -> Void)?

    /// Sends one sealed control envelope to `peer` over the pairwise control
    /// channel (AppState owns the ratchet / KMS pre-bootstrap). true = handed off.
    public var onSendControlEnvelope: ((_ peer: String, _ selfId: String, _ envelopeJson: String) async -> Bool)?

    // MARK: - Reactions / raised hands

    public struct ReactionEvent: Identifiable, Equatable {
        public let id: UUID
        public let senderId: String
        public let emoji: String
        public let receivedAt: Date

        public init(senderId: String, emoji: String) {
            self.id = UUID()
            self.senderId = senderId
            self.emoji = emoji
            self.receivedAt = Date()
        }
    }

    public var reactionEvents: [ReactionEvent] { lock.lock(); defer { lock.unlock() }; return _reactionEvents }
    public var raisedHands: Set<String> { lock.lock(); defer { lock.unlock() }; return _raisedHands }
    public var onReactionEventsChanged: (([ReactionEvent]) -> Void)?
    public var onRaisedHandsChanged: ((Set<String>) -> Void)?

    // MARK: - Init

    public init(manager: BCryptoGroupCallManager,
                backend: GroupMediaBackend? = GroupCallController.defaultBackend(),
                audio: GroupAudioUnitControlling? = nil,
                pathMonitor: GroupPathMonitoring? = nil,
                nowMs: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                iceRefreshRetrySeconds: Double = 60,
                mediaReadyTimeoutSeconds: Double = 10,
                tokenReplyTimeoutSeconds: Double = 8,
                tokenRetryBackoffSeconds: [Double] = [6, 12, 24, 48]) {
        self.manager = manager
        self.iceRefreshRetrySeconds = iceRefreshRetrySeconds
        self.mediaReadyTimeoutSeconds = mediaReadyTimeoutSeconds
        self.tokenReplyTimeoutSeconds = tokenReplyTimeoutSeconds
        self.tokenRetryBackoffSeconds = tokenRetryBackoffSeconds
        self.backend = backend
        self.audio = audio ?? GroupCallController.defaultAudioUnit()
        self.pathMonitor = pathMonitor ?? GroupNetworkPathWatcher()
        self.nowMs = nowMs
        self.audio.onNeedsSessionActivation = { [weak self] in self?.onNeedsAudioSessionActivation?() }
        backend?.onMissingKey = { [weak self] pseudonym in
            self?.e2eeQueue.async { self?.coordinatorSnapshot()?.onMissingKey(pseudonym: pseudonym) }
        }
        backend?.onDecryptFailure = { [weak self] pseudonym in
            self?.e2eeQueue.async { self?.coordinatorSnapshot()?.onDecryptFailure(pseudonym: pseudonym) }
        }
        backend?.onCryptorOk = { [weak self] pseudonym in
            self?.e2eeQueue.async { self?.coordinatorSnapshot()?.onCryptorOk(pseudonym: pseudonym) }
        }
        wireManagerCallbacks()
    }

    public static func defaultBackend() -> GroupMediaBackend? {
        #if canImport(WebRTC)
        return WebRtcGroupMediaBackend()
        #else
        return nil
        #endif
    }

    static func defaultAudioUnit() -> GroupAudioUnitControlling {
        #if canImport(WebRTC)
        return GroupAudioUnitDriver()
        #else
        return NoopGroupAudioUnit()
        #endif
    }

    /// `connectPersistentSocket` builds a fresh manager against every fresh
    /// socket: re-point this long-lived controller at it (W-GRPSTALEMGR) and
    /// clear the old manager's slots so a zombie socket cannot double-deliver.
    public func rebind(manager newManager: BCryptoGroupCallManager) {
        guard newManager !== manager else {
            print("[GroupCallController] rebind NOOP — called with the SAME manager instance already held")
            return
        }
        print("[GroupCallController] rebind SWAPPED manager instance (old WS's handlers cleared)")
        let old = manager
        old.onStateChanged = nil
        old.onParticipantsChanged = nil
        old.onGroupUpdate = nil
        old.onMediaReady = nil
        old.onMediaUnavailable = nil
        old.onMediaMoved = nil
        old.onMediaToken = nil
        old.onActiveCallEnded = nil
        old.onServerError = nil
        old.onGroupCallReactionReceived = nil
        old.onGroupCallRaiseHandReceived = nil
        old.onGroupCallMuteRequestReceived = nil
        manager = newManager
        wireManagerCallbacks()
    }

    /// The signaling socket reconnected: re-send `group_call_join` for the
    /// in-flight call (a dropped WS gets the member reaped from the roster once
    /// the server's ghost grace expires). A strict no-op unless a call is
    /// `.connecting` / `.active`. If the media link is gone meanwhile, the next
    /// `group_call_update` re-requests it.
    public func rejoinAfterReconnect() {
        lock.lock()
        let cid = activeCallId
        let st = _state
        lock.unlock()
        guard let callId = cid else { return }
        switch st {
        case .connecting, .active:
            print("[GroupCallController] rejoinAfterReconnect: re-sending group_call_join call=\(callId.prefix(8))…")
            manager.joinGroupCall(callId: callId)
        case .idle, .failed:
            break
        }
    }

    // MARK: - Public API

    /// Create a new group call and invite the listed peers. Returns the call id
    /// (also held internally), or nil if the manager refused (already in a call).
    @discardableResult
    public func createCall(
        invitees: [String],
        title: String = "",
        callType: String = "audio",
        groupId: String = "",
        groupName: String = "",
        /// W-CALLPROMOTE: set when this call is a live promotion of a 1:1 call.
        promotedFromCallId: String = "",
        /// The microphone state the call begins with: a promotion carries the mute of
        /// the 1:1 leg over (see `beginCall`).
        startMuted: Bool = false
    ) -> String? {
        guard let callId = manager.createGroupCall(
            recipients: invitees, title: title, callType: callType,
            groupId: groupId, groupName: groupName, promotedFromCallId: promotedFromCallId
        ) else {
            return nil
        }
        beginCall(callId: callId, video: callType == "video", created: true, startMuted: startMuted)
        setState(.connecting(callId: callId))
        // The creator is a participant from the moment the server has the create, and a
        // server need not send it any `group_call_update` until somebody joins (an older one
        // does not; a newer one sends the epoch-1 roster at create): waiting for one would
        // hold this phone's media back until the first invitee has accepted. Android and
        // desktop start their media at once; so does this. Both frames go out on the one
        // socket, in order. Setting `mediaJoinRequested` here also keeps the first update
        // from asking a second time.
        requestMediaJoin(force: false)
        return callId
    }

    /// - Parameter video: whether the invite this joins was a video call; the
    ///   camera is published from the start once the media path is up.
    /// - Parameter startMuted: the microphone state the call begins with: joining the
    ///   group a 1:1 call is promoted into carries the mute of the 1:1 leg over.
    public func join(callId: String, video: Bool = false, startMuted: Bool = false) {
        beginCall(callId: callId, video: video, created: false, startMuted: startMuted)
        manager.joinGroupCall(callId: callId)
        setState(.connecting(callId: callId))
    }

    public func leave() {
        manager.leaveGroupCall()
        teardown(reason: "user_left")
    }

    public func endCallForAll() {
        manager.endGroupCall()
        teardown(reason: "ended_for_all")
    }

    /// Whether the call was created / joined as a video call.
    public var callWantsVideo: Bool { lock.lock(); defer { lock.unlock() }; return wantsVideo }
    /// This call was created by us (not joined from an invite).
    public var isCreatedLocally: Bool { lock.lock(); defer { lock.unlock() }; return createdLocally }
    /// The id of the call this controller is in, if any.
    public var currentCallId: String? { lock.lock(); defer { lock.unlock() }; return activeCallId }
    /// Both PeerConnections' media path is up right now.
    public var isMediaConnected: Bool { lock.lock(); defer { lock.unlock() }; return mediaConnected }
    /// A media link exists (connecting or connected): the UI gates the camera on it.
    public var hasMediaLink: Bool { lock.lock(); defer { lock.unlock() }; return link != nil }

    // MARK: - Mute / camera

    public func setMuted(_ muted: Bool) {
        lock.lock()
        let changed = self.muted != muted
        self.muted = muted
        let current = link
        lock.unlock()
        current?.setMicrophoneEnabled(!muted)
        if changed { onMutedChanged?(muted) }
    }

    public var isMuted: Bool { lock.lock(); defer { lock.unlock() }; return muted }

    /// The real mic switch (`setMuted` keeps the state, this is the async form the
    /// view model awaits). Returns false without a live link.
    @discardableResult
    public func setMicrophoneEnabled(_ enabled: Bool) async -> Bool {
        setMuted(!enabled)
        lock.lock()
        let current = link
        lock.unlock()
        return current != nil
    }

    /// Camera on / off: capture, then `configure video:true|false` on the
    /// publisher (no renegotiation). false = it did not change.
    ///
    /// Every step goes to the phone log (`GroupDiagnostics.videoLine`): the request,
    /// the capturer's outcome here, the `configure` and the first encoded frame in
    /// `GroupMediaSession`. Before, a camera that never published left no trace.
    @discardableResult
    public func setVideoEnabled(_ enabled: Bool) async -> Bool {
        diagVideo(camera: enabled, phase: .requested, ok: true)
        lock.lock()
        let current = link
        lock.unlock()
        guard let current = current else {
            print("[GroupCallController] setVideoEnabled(\(enabled)) — no media link")
            diagVideo(camera: enabled, phase: .noLink, ok: false)
            return false
        }
        if !enabled {
            let stopped = await current.setCameraEnabled(false)
            diagVideo(camera: false, phase: .camera, ok: stopped == .stopped, code: GroupDiagnostics.cameraCode(stopped))
            await current.setPublishVideo(false)
            lock.lock()
            cameraOn = false
            videoStoppedByPolicy = false
            lock.unlock()
            return true
        }
        let startedAtMs = nowMs()
        let result = await current.setCameraEnabled(true)
        diagVideo(camera: true, phase: .camera, ok: result == .started,
                  code: GroupDiagnostics.cameraCode(result), ms: Int(nowMs() - startedAtMs))
        switch result {
        case .started:
            lock.lock()
            cameraOn = true
            videoStoppedByPolicy = false
            lock.unlock()
            await current.setPublishVideo(true)
            applyPublishPolicy()
            return true
        case .stopped:
            return false
        case .permissionDenied:
            reportMediaError(.cameraPermissionDenied)
            return false
        case .noCamera, .notReady:
            reportMediaError(.cameraUnavailable)
            return false
        }
    }

    // MARK: - Diagnosis

    /// A camera step for the phone log, also kept as the "video" slot of `diagSnapshot()`.
    private func diagVideo(camera: Bool, phase: GroupDiagnostics.VideoPhase, ok: Bool, code: Int = 0, ms: Int = 0) {
        lock.lock()
        diagSlots["video"] = ["camera": camera ? 1 : 0, "phase": phase.rawValue, "ok": ok ? 1 : 0, "code": code, "ms": ms]
        lock.unlock()
        diagLog?(GroupDiagnostics.videoLine(camera: camera, phase: phase, ok: ok, code: code, ms: ms))
    }

    /// A media error the user is about to be shown: remembered for the bug report, then
    /// reported (the app logs `grp error code=<n>` and shows the toast).
    private func reportMediaError(_ error: GroupCallMediaError) {
        lock.lock()
        diagLastErrorCode = GroupDiagnostics.errorCode(error)
        lock.unlock()
        onMediaError?(error)
    }

    /// A diagnosis line from the media session (`GroupTelemetry.Kind.diagLine`): kept
    /// under its slot for the bug report, then handed to `diagLog`. Never telemetry.
    private func noteDiagLine(_ event: GroupTelemetryEvent) {
        guard let line = event.attrs["line"] as? String else { return }
        if let slot = event.attrs["slot"] as? String, let values = event.attrs["values"] as? [String: Int] {
            var key = slot
            if slot == "rx", let mid = values["mid"] { key = "rx:\(mid)" }
            lock.lock()
            diagSlots[key] = values
            lock.unlock()
        }
        diagLog?(line)
    }

    /// The group media state for the bug report (`AppState.buildDiagSnapshotJSON`):
    /// booleans and numbers only, never an id, a key or a pseudonym.
    public func diagSnapshot() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        var snapshot: [String: Any] = [
            "in_call": activeCallId != nil,
            "has_link": link != nil,
            "link_generation": linkGeneration,
            "media_connected": mediaConnected,
            "media_join_requested": mediaJoinRequested,
            "camera_on": cameraOn,
            "wants_video": wantsVideo,
            "video_stopped_by_policy": videoStoppedByPolicy,
            "muted": muted,
            "created_locally": createdLocally,
            "backgrounded": backgrounded,
            "last_error_code": diagLastErrorCode,
        ]
        if !diagPcStates.isEmpty { snapshot["pc_states"] = diagPcStates }
        if !diagSlots.isEmpty { snapshot["last"] = diagSlots }
        return snapshot
    }

    // MARK: - Tiles

    /// What the tile of `identity` (a user id) currently shows: drives the
    /// simulcast substream and the subscription (spec §4.6).
    public func setRemoteVideoRenderPriority(identity: String, priority: RemoteVideoRenderPriority) {
        lock.lock()
        desiredTiles[identity] = (tile: priority.tileClass, visible: priority.isVisible)
        let current = link
        let pseudonym = lastUpdate?.pseudonyms[identity]
        lock.unlock()
        guard let link = current, let pseudonym = pseudonym else { return }
        link.setTile(pseudonym: pseudonym, tile: priority.tileClass, visible: priority.isVisible)
    }

    /// App backgrounded: remote video is unsubscribed and the local video
    /// publish paused (spec §4.6); audio is never touched.
    public func setAppBackgrounded(_ value: Bool) {
        lock.lock()
        backgrounded = value
        let current = link
        let camera = cameraOn
        let stopped = videoStoppedByPolicy
        lock.unlock()
        current?.setBackgrounded(value)
        guard camera, !stopped, let link = current else { return }
        Task { await link.setPublishVideo(!value) }
    }

    // MARK: - Network / audio session

    /// Wi-Fi <-> cellular / IP change (NWPathMonitor): ICE restart on both
    /// PeerConnections at once (spec §4.7).
    public func networkPathChanged(reason: String) {
        lock.lock()
        let current = link
        lock.unlock()
        guard let link = current else { return }
        Task { await link.networkPathChanged(reason: reason) }
    }

    /// The shared AVAudioSession was activated (CallKit `didActivate`, or the app's
    /// own activation). Remembered so a call that begins AFTER the activation
    /// (accept -> join is asynchronous) still finds it.
    public func audioSessionActivated(source: AudioSessionActivationSource) {
        lock.lock()
        lastAudioActivation = source
        let live = activeCallId != nil
        lock.unlock()
        if live { audio.sessionActivated(source: source) }
    }

    public func audioSessionDeactivated() {
        lock.lock()
        lastAudioActivation = nil
        let live = activeCallId != nil
        lock.unlock()
        if live { audio.sessionDeactivated() }
    }

    /// The 1:1 call this group call was promoted from has ended and released the
    /// shared audio unit: take it over (make-before-break).
    public func oneToOneEnded() {
        lock.lock()
        let live = activeCallId != nil
        lock.unlock()
        if live { audio.oneToOneEnded() }
    }

    // MARK: - Reactions / raised hands

    public func sendReaction(emoji: String) {
        manager.sendGroupCallReaction(emoji: emoji)
        appendReactionEvent(senderId: manager.selfUserId, emoji: emoji)
    }

    public func setHandRaised(_ raised: Bool) {
        manager.sendGroupCallRaiseHand(raised: raised)
        let selfId = manager.selfUserId
        lock.lock()
        if raised { _raisedHands.insert(selfId) } else { _raisedHands.remove(selfId) }
        let snapshot = _raisedHands
        lock.unlock()
        onRaisedHandsChanged?(snapshot)
    }

    /// A peer asked us to mute: applied at once, fully reversible in one tap.
    private func handleMuteRequest(fromSenderId: String) {
        setMuted(true)
        onMuteRequested?(fromSenderId)
    }

    private func appendReactionEvent(senderId: String, emoji: String) {
        let event = ReactionEvent(senderId: senderId, emoji: emoji)
        lock.lock()
        _reactionEvents.append(event)
        let snapshot = _reactionEvents
        lock.unlock()
        onReactionEventsChanged?(snapshot)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self._reactionEvents.removeAll { $0.id == event.id }
            let after = self._reactionEvents
            self.lock.unlock()
            self.onReactionEventsChanged?(after)
        }
    }

    // MARK: - Control envelopes (E2EE v2)

    /// A decrypted `qa_grpcall_ctrl` payload from `fromUserId`. Only `qa_grp:2`
    /// envelopes exist; anything else (a removed v1 envelope) is dropped.
    public func onGroupCallControlEnvelope(json: String, fromUserId: String) {
        switch GroupKeyEnvelope.parse(json: json) {
        case .notV2:
            print("[GroupCallController][telemetry] ctrl envelope from \(fromUserId.prefix(8)) ignored: not qa_grp:2")
        case .malformed(let reason):
            print("[GroupCallController][telemetry] ctrl envelope from \(fromUserId.prefix(8)) failed: \(reason)")
        case .envelope(let envelope):
            lock.lock()
            let live = coordinator
            if live == nil, case .mediaKey = envelope {
                let now = nowMs()
                earlyKeys.removeAll { now - $0.atMs > Self.earlyKeyTtlMs }
                if earlyKeys.count >= Self.earlyKeyLimit { earlyKeys.removeFirst() }
                earlyKeys.append((envelope: envelope, user: fromUserId, atMs: now))
                lock.unlock()
                return
            }
            lock.unlock()
            guard let coordinator = live else {
                print("[GroupCallController][telemetry] ctrl envelope from \(fromUserId.prefix(8)) dropped: no active call")
                return
            }
            e2eeQueue.async { coordinator.onEnvelope(envelope, from: fromUserId) }
        }
    }

    private static let earlyKeyTtlMs: Int64 = 15_000
    private static let earlyKeyLimit = 16

    fileprivate func coordinatorSnapshot() -> GroupE2eeCoordinator? {
        lock.lock(); defer { lock.unlock() }
        return coordinator
    }

    // MARK: - Call lifecycle

    /// `startMuted` is the microphone state of the WHOLE call, rejoins included (the
    /// link wiring reads `muted` before the publisher exists): a muted 1:1 call that is
    /// promoted to a group must not open the microphone, not even for one frame, so the
    /// state is set here, under the same lock that publishes the call id, long before
    /// any media hand-out can build a link.
    private func beginCall(callId: String, video: Bool, created: Bool, startMuted: Bool = false) {
        lock.lock()
        let previousLink = link
        let previousCoordinator = coordinator
        let mutedBefore = muted
        link = nil
        linkGeneration += 1
        activeCallId = callId
        createdLocally = created
        wantsVideo = video
        muted = startMuted
        cameraOn = false
        lastUpdate = nil
        currentReady = nil
        recovery = GroupMediaRecoveryPolicy()
        speaking = GroupSpeakingDetector()
        mediaJoinRequested = false
        mediaReadyRetried = false
        mediaConnected = false
        connectedTelemetrySent = false
        congestionSteps = 0
        videoStoppedByPolicy = false
        iceRefreshPending = false
        iceRefreshAttempts = 0
        iceRefreshRequestedAtMs = 0
        let staleRefreshRetry = iceRefreshRetry
        iceRefreshRetry = nil
        tokenRefreshPending = false
        tokenRefreshAttempt = 0
        let staleTokenTimer = tokenRefreshTimer
        tokenRefreshTimer = nil
        rejoinReasonInFlight = nil
        desiredTiles.removeAll()
        diagLastErrorCode = 0
        diagPcStates.removeAll()
        diagSlots.removeAll()
        let newCoordinator = GroupE2eeCoordinator(
            callId: callId, selfUserId: manager.selfUserId, environment: GroupCallE2eeEnvironment(controller: self, queue: e2eeQueue))
        coordinator = newCoordinator
        let now = nowMs()
        let early = earlyKeys.filter { $0.envelope.callId == callId && now - $0.atMs <= Self.earlyKeyTtlMs }
        earlyKeys.removeAll()
        let replay = lastAudioActivation
        lock.unlock()
        if mutedBefore != startMuted { onMutedChanged?(startMuted) }
        if !early.isEmpty {
            e2eeQueue.async { for item in early { newCoordinator.onEnvelope(item.envelope, from: item.user) } }
        }
        staleRefreshRetry?.cancel()
        staleTokenTimer?.cancel()
        previousLink?.close()
        e2eeQueue.async { previousCoordinator?.stop() }
        backend?.beginCall()
        audio.begin()
        if let source = replay { audio.sessionActivated(source: source) }
        startPolicyObservers()
        pathMonitor.start { [weak self] reason in self?.networkPathChanged(reason: reason) }
    }

    private func teardown(reason: String) {
        lock.lock()
        guard let endedCallId = activeCallId else {
            lock.unlock()
            return
        }
        activeCallId = nil
        createdLocally = false
        let oldLink = link
        link = nil
        linkGeneration += 1
        let oldCoordinator = coordinator
        coordinator = nil
        let wasMuted = muted
        muted = false
        cameraOn = false
        wantsVideo = false
        lastUpdate = nil
        currentReady = nil
        mediaJoinRequested = false
        mediaConnected = false
        congestionSteps = 0
        videoStoppedByPolicy = false
        desiredTiles.removeAll()
        lastAudioActivation = nil
        let timeout = mediaReadyTimeout
        mediaReadyTimeout = nil
        let reset = congestionReset
        congestionReset = nil
        iceRefreshPending = false
        iceRefreshAttempts = 0
        iceRefreshRequestedAtMs = 0
        let refreshRetry = iceRefreshRetry
        iceRefreshRetry = nil
        tokenRefreshPending = false
        tokenRefreshAttempt = 0
        let tokenTimer = tokenRefreshTimer
        tokenRefreshTimer = nil
        _reactionEvents.removeAll()
        _raisedHands.removeAll()
        let hadConnected = connectedTelemetrySent
        connectedTelemetrySent = false
        lock.unlock()
        timeout?.cancel()
        reset?.cancel()
        refreshRetry?.cancel()
        tokenTimer?.cancel()
        stopPolicyObservers()
        pathMonitor.stop()
        oldLink?.close()
        e2eeQueue.async { oldCoordinator?.stop() }
        backend?.endCall()
        audio.end()
        if hadConnected || oldLink != nil {
            groupTelemetry?("call.media.ended", endedCallId, ["reason": reason])
        }
        setState(.idle)
        if wasMuted { onMutedChanged?(false) }
        onReactionEventsChanged?([])
        onRaisedHandsChanged?([])
        onLocalVideoTrack?(nil)
    }

    private func setState(_ newState: State) {
        lock.lock(); _state = newState; lock.unlock()
        onStateChange?(newState)
    }

    // MARK: - Manager wiring

    private func wireManagerCallbacks() {
        manager.onStateChanged = { [weak self] s in
            guard let self = self else { return }
            self.onManagerStateChanged?(s)
            switch s {
            case .creating:
                if case .connecting = self.state { /* keep */ } else if let cid = self.manager.callId {
                    self.setState(.connecting(callId: cid))
                }
            case .active:
                if let cid = self.manager.callId {
                    self.setState(.active(callId: cid, participants: self.manager.participants.map(\.id)))
                }
            case .ended:
                self.teardown(reason: "remote_ended")
            case .idle:
                self.setState(.idle)
            }
        }
        manager.onParticipantsChanged = { [weak self] list in
            self?.onParticipantsChanged?(list)
        }
        manager.onGroupUpdate = { [weak self] update in self?.handleUpdate(update) }
        manager.onMediaReady = { [weak self] ready in self?.handleMediaReady(ready) }
        manager.onMediaUnavailable = { [weak self] callId, reason in
            self?.handleMediaUnavailable(callId: callId, reason: reason)
        }
        manager.onMediaMoved = { [weak self] callId, _ in
            self?.handleTrigger(.mediaMoved, forCall: callId)
        }
        manager.onMediaToken = { [weak self] token in self?.handleMediaToken(token) }
        manager.onActiveCallEnded = { [weak self] callId, reason in
            self?.onCallEnded?(callId, reason)
        }
        manager.onServerError = { [weak self] code, callId in
            self?.handleServerError(code: code, callId: callId)
        }
        manager.onGroupCallReactionReceived = { [weak self] callId, senderId, emoji in
            guard let self = self, self.isActive(callId) else { return }
            self.appendReactionEvent(senderId: senderId, emoji: emoji)
        }
        manager.onGroupCallRaiseHandReceived = { [weak self] callId, senderId, raised in
            guard let self = self else { return }
            self.lock.lock()
            guard callId == self.activeCallId else { self.lock.unlock(); return }
            if raised { self._raisedHands.insert(senderId) } else { self._raisedHands.remove(senderId) }
            let snapshot = self._raisedHands
            self.lock.unlock()
            self.onRaisedHandsChanged?(snapshot)
        }
        manager.onGroupCallMuteRequestReceived = { [weak self] callId, senderId in
            guard let self = self, self.isActive(callId) else { return }
            self.handleMuteRequest(fromSenderId: senderId)
        }
    }

    private func isActive(_ callId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return callId == activeCallId
    }

    // MARK: - Roster / E2EE

    /// A `group_call_update`: roster, epoch, pseudonym map. Feeds the E2EE state
    /// machine, re-filters the subscribable publishers and (first time) asks for
    /// the media hand-out.
    private func handleUpdate(_ update: GroupCallWire.Update) {
        lock.lock()
        guard update.callId == activeCallId else {
            lock.unlock()
            return
        }
        lastUpdate = update
        let readyPseudonym = currentReady?.pseudonym
        let selfId = manager.selfUserId
        let current = link
        let needsMedia = !mediaJoinRequested && link == nil
        let coordinator = self.coordinator
        lock.unlock()

        var pseudonyms = update.pseudonyms
        if pseudonyms[selfId] == nil, let own = readyPseudonym { pseudonyms[selfId] = own }
        e2eeQueue.async {
            coordinator?.onRoster(epoch: update.epoch, members: update.participants, pseudonyms: pseudonyms)
        }
        current?.refreshPublisherFilter()
        if needsMedia { requestMediaJoin(force: false) }
    }

    /// The coordinator's outward calls. Kept off the coordinator queue's lock.
    fileprivate func e2eeInstallKey(_ key: Data, index: Int32, participantId: String) {
        backend?.installKey(key, index: index, participantId: participantId)
    }

    fileprivate func e2eeSetSendKeyIndex(_ index: Int32) {
        backend?.setSendKeyIndex(index)
    }

    fileprivate func e2eeRequestKeyFrame() {
        lock.lock()
        let current = link
        lock.unlock()
        guard let link = current else { return }
        Task { await link.requestPublisherKeyFrame() }
    }

    fileprivate func e2eeSend(to user: String, json: String, completion: @escaping (Bool) -> Void) {
        guard let send = onSendControlEnvelope else {
            completion(false)
            return
        }
        let selfId = manager.selfUserId
        Task {
            let ok = await send(user, selfId, json)
            completion(ok)
        }
    }

    fileprivate func emitTelemetry(_ event: GroupTelemetryEvent) {
        lock.lock()
        let callId = activeCallId
        lock.unlock()
        groupTelemetry?(event.kind, callId.map(GroupTelemetry.id8), event.attrs)
    }

    // MARK: - Media join / ready

    /// `group_call_media_join`, with a timeout that retries once and then hands
    /// the failure to the recovery ladder.
    private func requestMediaJoin(force: Bool) {
        lock.lock()
        guard let callId = activeCallId else {
            lock.unlock()
            return
        }
        if mediaJoinRequested && !force {
            lock.unlock()
            return
        }
        mediaJoinRequested = true
        mediaJoinRequestedAtMs = nowMs()
        rejoinReasonInFlight = nil
        let previousTimeout = mediaReadyTimeout
        let item = DispatchWorkItem { [weak self] in self?.mediaReadyTimedOut(callId: callId) }
        mediaReadyTimeout = item
        lock.unlock()
        previousTimeout?.cancel()
        manager.requestMediaJoin(callId: callId)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + mediaReadyTimeoutSeconds, execute: item)
    }

    private func mediaReadyTimedOut(callId: String) {
        lock.lock()
        guard callId == activeCallId, currentReady == nil || link == nil, mediaReadyTimeout != nil else {
            lock.unlock()
            return
        }
        let retried = mediaReadyRetried
        mediaReadyRetried = true
        let rejoinReason = rejoinReasonInFlight
        lock.unlock()
        if !retried {
            // The same kind of request again: a rejoin that got no answer is a rejoin.
            if let reason = rejoinReason { requestMediaRejoin(reason: reason) } else { requestMediaJoin(force: true) }
        } else {
            handleTrigger(.needsRejoin("media_ready_timeout"), forCall: callId)
        }
    }

    private func handleMediaReady(_ ready: GroupCallWire.MediaReady) {
        lock.lock()
        guard ready.callId == activeCallId, let backend = backend else {
            lock.unlock()
            return
        }
        // The same room, node, pseudonym and certificate while a link exists, shortly
        // after we asked for a refresh: this is the answer of the hourly TURN refresh,
        // NOT a new path. It is applied in place; the running media is never torn
        // down for it. (Any other hand-out replaces the link, as it always did.)
        let refreshAnswer = iceRefreshRequestedAtMs > 0 && nowMs() - iceRefreshRequestedAtMs < Self.iceRefreshAnswerWindowMs
        if refreshAnswer, let live = link, let known = currentReady, Self.sameMedia(known, ready) {
            currentReady = ready
            iceRefreshPending = false
            iceRefreshAttempts = 0
            let retry = iceRefreshRetry
            iceRefreshRetry = nil
            let timeout = mediaReadyTimeout
            mediaReadyTimeout = nil
            mediaReadyRetried = false
            lock.unlock()
            retry?.cancel()
            timeout?.cancel()
            live.updateIceServers(ready.iceServers)
            live.updateSessionToken(ready.sessionToken)
            return
        }
        iceRefreshPending = false
        iceRefreshAttempts = 0
        iceRefreshRequestedAtMs = 0
        currentReady = ready
        let timeout = mediaReadyTimeout
        mediaReadyTimeout = nil
        mediaReadyRetried = false
        let previous = link
        link = nil
        linkGeneration += 1
        let generation = linkGeneration
        let startedAtMs = mediaJoinRequestedAtMs
        let publishVideo = wantsVideo
        let coordinator = self.coordinator
        let update = lastUpdate
        lock.unlock()
        timeout?.cancel()
        previous?.close()
        // The own pseudonym may be the last piece the key distribution waited for.
        if let update = update {
            var pseudonyms = update.pseudonyms
            if pseudonyms[manager.selfUserId] == nil { pseudonyms[manager.selfUserId] = ready.pseudonym }
            e2eeQueue.async {
                coordinator?.onRoster(epoch: update.epoch, members: update.participants, pseudonyms: pseudonyms)
            }
        }
        Task { [weak self] in
            do {
                let newLink = try await backend.makeLink(ready: ready)
                guard let self = self else {
                    newLink.close()
                    return
                }
                self.lock.lock()
                let stillCurrent = generation == self.linkGeneration && ready.callId == self.activeCallId
                if stillCurrent { self.link = newLink }
                self.lock.unlock()
                guard stillCurrent else {
                    newLink.close()
                    return
                }
                self.wire(link: newLink, generation: generation)
                try await newLink.start(publishVideo: publishVideo)
                self.mediaStarted(generation: generation, nodeId: ready.nodeId, startedAtMs: startedAtMs)
            } catch {
                self?.mediaStartFailed(error, generation: generation, callId: ready.callId)
            }
        }
    }

    /// Same media identity: everything that pins the PeerConnections to one node and
    /// one room. Tokens and TURN credentials are allowed to differ (that is a refresh).
    static func sameMedia(_ a: GroupCallWire.MediaReady, _ b: GroupCallWire.MediaReady) -> Bool {
        a.room == b.room && a.pseudonym == b.pseudonym && a.nodeId == b.nodeId
            && a.wsUrl == b.wsUrl && a.dtlsFingerprint == b.dtlsFingerprint
    }

    /// `group_call_media_unavailable`: every reason is final for this attempt (a clear
    /// error, no retry); the server never answers a request that is over its budget.
    private func handleMediaUnavailable(callId: String, reason: GroupCallWire.UnavailableReason) {
        handleTrigger(.mediaUnavailable(reason), forCall: callId)
    }

    /// A server `error` envelope (iOS deviation 19): the answer of a refused create / join /
    /// media request. The server names the call (`call_id`, server D25): only an error that
    /// names the live call is its answer. An error WITHOUT a call id is about something else
    /// (the `error` envelope is shared by every feature: a chat, a 1:1 call that is being
    /// promoted) and never ends a group attempt. While no media path exists (a first join, a
    /// rejoin, a creator's start) it ends the attempt at once instead of waiting out the
    /// 10-30 s timeouts; with a running media path an `error` is not about this call and
    /// changes nothing.
    private func handleServerError(code: String, callId: String?) {
        lock.lock()
        guard let active = activeCallId, link == nil, callId == active else {
            lock.unlock()
            return
        }
        lock.unlock()
        print("[GroupCallController] server error during media setup code=\(code.prefix(24)) call=\(active.prefix(8))…")
        failMedia(code == "entitlement_required" ? .entitlementRequired : .other("server_error"))
    }

    /// Spec 2.3: the per-call TURN credentials live about 2 h. Every hour a plain
    /// `group_call_media_join` fetches a fresh hand-out; `handleMediaReady` applies
    /// it in place (desktop parity). Asked again after `iceRefreshRetrySeconds` if
    /// no answer came, at most `iceRefreshMaxAttempts` times per round.
    private func requestIceRefresh() {
        lock.lock()
        guard let callId = activeCallId, link != nil, iceRefreshAttempts < Self.iceRefreshMaxAttempts else {
            iceRefreshPending = false
            iceRefreshAttempts = 0
            lock.unlock()
            return
        }
        iceRefreshPending = true
        iceRefreshAttempts += 1
        iceRefreshRequestedAtMs = nowMs()
        let generation = linkGeneration
        let previous = iceRefreshRetry
        let item = DispatchWorkItem { [weak self] in self?.iceRefreshTimedOut(callId: callId, generation: generation) }
        iceRefreshRetry = item
        lock.unlock()
        previous?.cancel()
        manager.requestMediaJoin(callId: callId)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + iceRefreshRetrySeconds, execute: item)
    }

    private func iceRefreshTimedOut(callId: String, generation: Int) {
        lock.lock()
        let stillWaiting = callId == activeCallId && generation == linkGeneration && iceRefreshPending
        lock.unlock()
        if stillWaiting { requestIceRefresh() }
    }

    /// `group_call_media_token` (spec §11): the fresh Janus session token replaces
    /// the old one for every later request of the live link. A token for another
    /// call, or one that arrives while no link exists, changes nothing (a new
    /// `group_call_media_ready` carries its own).
    private func handleMediaToken(_ token: GroupCallWire.MediaToken) {
        lock.lock()
        guard token.callId == activeCallId else {
            lock.unlock()
            return
        }
        let current = link
        // The answer ends the round: no more attempts, the next refresh is the periodic one.
        tokenRefreshPending = false
        tokenRefreshAttempt = 0
        let timer = tokenRefreshTimer
        tokenRefreshTimer = nil
        lock.unlock()
        timer?.cancel()
        current?.updateSessionToken(token.sessionToken)
    }

    /// Asks the server for a fresh Janus session token (answered by `group_call_media_token`).
    /// Single-flight: a round that is already running covers every later trigger (the 300 s
    /// loop, a lost media WebSocket). Janus re-validates the token on EVERY request and it
    /// lives 600 s, so a lost request (the server drops one over its budget without an
    /// answer, and the app socket is prone to suspension around CallKit) must not wait for the
    /// next 300 s tick: each attempt waits `tokenReplyTimeoutSeconds` for its answer and is
    /// repeated after a growing, jittered pause; a round that never gets one rejoins the
    /// media while the old token is still good, instead of dying at its expiry.
    private func requestMediaToken() {
        lock.lock()
        guard let callId = activeCallId, link != nil else {
            lock.unlock()
            return
        }
        if tokenRefreshPending && tokenRefreshGeneration == linkGeneration {
            lock.unlock()
            return
        }
        tokenRefreshPending = true
        tokenRefreshGeneration = linkGeneration
        tokenRefreshAttempt = 0
        let generation = linkGeneration
        lock.unlock()
        sendTokenRefresh(callId: callId, generation: generation)
    }

    private func sendTokenRefresh(callId: String, generation: Int) {
        lock.lock()
        guard callId == activeCallId, generation == linkGeneration, tokenRefreshPending,
              tokenRefreshGeneration == generation else {
            lock.unlock()
            return
        }
        tokenRefreshAttempt += 1
        let attempt = tokenRefreshAttempt
        let previous = tokenRefreshTimer
        let item = DispatchWorkItem { [weak self] in
            self?.tokenRefreshTimedOut(callId: callId, generation: generation, attempt: attempt)
        }
        tokenRefreshTimer = item
        lock.unlock()
        previous?.cancel()
        manager.requestMediaRefresh(callId: callId)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + tokenReplyTimeoutSeconds, execute: item)
    }

    private func tokenRefreshTimedOut(callId: String, generation: Int, attempt: Int) {
        lock.lock()
        guard callId == activeCallId, generation == linkGeneration, tokenRefreshPending,
              tokenRefreshGeneration == generation, attempt == tokenRefreshAttempt else {
            lock.unlock()
            return
        }
        guard attempt <= tokenRetryBackoffSeconds.count else {
            // Every attempt went unanswered: the token is about to expire.
            tokenRefreshPending = false
            tokenRefreshAttempt = 0
            tokenRefreshTimer = nil
            lock.unlock()
            print("[GroupCallController] no media token after \(attempt) attempts call=\(callId.prefix(8))… - rejoining")
            handleTrigger(.needsRejoin("token_refresh"), forCall: callId)
            return
        }
        let pause = tokenRetryBackoffSeconds[attempt - 1] * Double.random(in: 0.75...1.25)
        let item = DispatchWorkItem { [weak self] in self?.sendTokenRefresh(callId: callId, generation: generation) }
        tokenRefreshTimer = item
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + pause, execute: item)
    }

    private func wire(link newLink: GroupMediaLink, generation: Int) {
        newLink.publisherFilter = { [weak self] pseudonym in self?.isSubscribable(pseudonym) ?? false }
        newLink.onEvent = { [weak self] event in self?.handle(event, generation: generation) }
        newLink.onRemoteTrack = { [weak self] remote in self?.handleRemoteTrack(remote, generation: generation) }
        newLink.onLocalVideoTrack = { [weak self] track in
            guard let self = self, self.isCurrent(generation) else { return }
            self.onLocalVideoTrack?(track)
        }
        applyMicrophoneState(to: newLink)
    }

    /// Runs BEFORE the publisher exists (`start` creates the audio track with whatever
    /// this set), so a muted call never has a live microphone. The state is applied and
    /// then checked again: a mute that lands between the read and the apply (its own
    /// `setMicrophoneEnabled` already ran on this link, the stale apply here would come
    /// after it) must win.
    private func applyMicrophoneState(to target: GroupMediaLink) {
        while true {
            lock.lock()
            let wanted = muted
            lock.unlock()
            target.setMicrophoneEnabled(!wanted)
            lock.lock()
            let settled = wanted == muted
            lock.unlock()
            if settled { return }
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == linkGeneration
    }

    /// Current call members only: a stranger who somehow appears in the Janus room
    /// is never subscribed nor rendered.
    private func isSubscribable(_ pseudonym: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let update = lastUpdate else { return false }
        let own = currentReady?.pseudonym
        return pseudonym != own && update.userByPseudonym[pseudonym] != nil
    }

    private func mediaStarted(generation: Int, nodeId: String, startedAtMs: Int64) {
        guard isCurrent(generation) else { return }
        let elapsed = max(0, nowMs() - startedAtMs)
        emitTelemetry(GroupTelemetry.mediaJoin(nodeId: nodeId, ms: Int(elapsed)))
        lock.lock()
        let current = link
        let tiles = desiredTiles
        let update = lastUpdate
        let camera = wantsVideo
        let bg = backgrounded
        lock.unlock()
        if let current = current {
            if bg { current.setBackgrounded(true) }
            applyTiles(tiles, to: current, update: update)
        }
        if camera {
            Task { [weak self] in _ = await self?.setVideoEnabled(true) }
        }
    }

    private func applyTiles(_ tiles: [String: (tile: GroupLayerPolicy.TileClass, visible: Bool)],
                            to target: GroupMediaLink, update: GroupCallWire.Update?) {
        guard let update = update else { return }
        for (user, entry) in tiles {
            if let pseudonym = update.pseudonyms[user] {
                target.setTile(pseudonym: pseudonym, tile: entry.tile, visible: entry.visible)
            }
        }
    }

    private func mediaStartFailed(_ error: Error, generation: Int, callId: String) {
        guard isCurrent(generation) else { return }
        if let failure = error as? GroupMediaSession.Failure {
            handleFailure(failure, forCall: callId)
        } else if let janusError = error as? JanusClientError {
            switch janusError {
            case .janus, .plugin:
                switch JanusErrorPolicy.action(for: janusError) {
                case .retryMediaJoin:
                    handleTrigger(.retryableJanusError(janusError.code ?? 0), forCall: callId)
                case .fail:
                    handleTrigger(.fatalJanusError(janusError.code ?? 0), forCall: callId)
                }
            case .timeout, .closed, .notConnected, .malformed:
                handleTrigger(.needsRejoin("start_failed"), forCall: callId)
            }
        } else {
            handleTrigger(.needsRejoin("start_error"), forCall: callId)
        }
    }

    // MARK: - Link events

    private func handle(_ event: GroupMediaSession.Event, generation: Int) {
        guard isCurrent(generation) else { return }
        lock.lock()
        let callId = activeCallId
        lock.unlock()
        guard let cid = callId else { return }
        switch event {
        case .state:
            break
        case .remotePublishers:
            lock.lock()
            let current = link
            let tiles = desiredTiles
            let update = lastUpdate
            lock.unlock()
            if let current = current { applyTiles(tiles, to: current, update: update) }
        case .pcState(let role, let pcState):
            handlePcState(role, pcState, callId: cid)
        case .needsRejoin(let reason):
            handleTrigger(.needsRejoin(reason), forCall: cid)
        case .failed(let failure):
            handleFailure(failure, forCall: cid)
        case .janusFailure(let error):
            switch JanusErrorPolicy.action(for: error) {
            case .retryMediaJoin: handleTrigger(.retryableJanusError(error.code ?? 0), forCall: cid)
            case .fail: handleTrigger(.fatalJanusError(error.code ?? 0), forCall: cid)
            }
        case .kicked:
            // The server removed us from the Janus room (roster change / ghost
            // cleanup): ask for a fresh hand-out, exactly like a lost connection.
            handleTrigger(.needsRejoin("kicked"), forCall: cid)
        case .uplinkCongested:
            noteUplinkCongested()
        case .iceRefresh:
            requestIceRefresh()
        case .tokenRefresh:
            // Spec §11: ask for a fresh Janus session token. Answered with
            // `group_call_media_token`, or `media_unavailable {not_member}` (which ends
            // the media like any other refusal). An answer that does not come is asked
            // for again, see `requestMediaToken`.
            requestMediaToken()
        case .audioLevels(let byPseudonym):
            handleAudioLevels(byPseudonym)
        case .telemetry(let telemetry):
            if telemetry.kind == GroupTelemetry.Kind.diagLine {
                noteDiagLine(telemetry)
            } else {
                emitTelemetry(telemetry)
            }
        }
    }

    private func handlePcState(_ role: GroupTelemetry.PcRole, _ pcState: GroupPcState, callId: String) {
        lock.lock()
        diagPcStates[role.rawValue] = GroupDiagnostics.pcStateCode(pcState)
        lock.unlock()
        switch pcState {
        case .connected:
            lock.lock()
            let wasConnected = mediaConnected
            // The publisher is the media path; the subscriber only exists once
            // there is somebody to hear.
            if role == .pub { mediaConnected = true }
            let firstTime = role == .pub && !connectedTelemetrySent
            if firstTime { connectedTelemetrySent = true }
            if role == .pub { recovery.mediaBecameActive(nowMs: nowMs()) }
            lock.unlock()
            if firstTime {
                groupTelemetry?("call.media.connected", callId, ["peer_prefix": "group", "sas_source": "janus"])
            }
            if role == .pub && !wasConnected { onMediaConnected?() }
        case .disconnected, .failed, .closed:
            if role == .pub {
                lock.lock()
                mediaConnected = false
                lock.unlock()
            }
        default:
            break
        }
    }

    private func handleRemoteTrack(_ remote: GroupRemoteTrack, generation: Int) {
        guard isCurrent(generation) else { return }
        lock.lock()
        let user = lastUpdate?.userByPseudonym[remote.feedId]
        lock.unlock()
        guard let identity = user else { return }
        switch remote.kind {
        case .audio:
            onRemoteAudioTrack?(identity, remote.track)
        case .video:
            if remote.isScreenShare {
                onRemoteScreenShareTrack?(identity, remote.track)
            } else {
                onRemoteVideoTrack?(identity, remote.track)
            }
        }
    }

    private func handleAudioLevels(_ byPseudonym: [String: Double]) {
        lock.lock()
        let map = lastUpdate?.userByPseudonym ?? [:]
        lock.unlock()
        var levels: [String: Double] = [:]
        for (pseudonym, level) in byPseudonym {
            if let user = map[pseudonym] { levels[user] = level }
        }
        lock.lock()
        let now = nowMs()
        let ids = speaking.update(levels: levels, nowMs: now)
        lock.unlock()
        onActiveSpeakersChanged?(ids)
        manager.setSpeaking(Set(ids))
    }

    // MARK: - Recovery

    private func handleFailure(_ failure: GroupMediaSession.Failure, forCall callId: String) {
        switch failure {
        case .dtlsPinMismatch, .transportPolicy:
            handleTrigger(.securityFailure, forCall: callId)
        case .protocolViolation:
            handleTrigger(.needsRejoin("protocol"), forCall: callId)
        }
    }

    private func handleTrigger(_ trigger: GroupMediaRecoveryPolicy.Trigger, forCall callId: String) {
        lock.lock()
        guard callId == activeCallId else {
            lock.unlock()
            return
        }
        let action = recovery.handle(trigger, nowMs: nowMs())
        mediaConnected = false
        let dead = link
        linkGeneration += 1
        link = nil
        let generation = linkGeneration
        lock.unlock()
        dead?.close()
        switch action {
        case .sendMediaJoin(let delayMs):
            scheduleMediaRequest(callId: callId, generation: generation, delayMs: delayMs) { [weak self] in
                self?.requestMediaJoin(force: true)
            }
        case .sendMediaRejoin(let reason, let delayMs):
            emitTelemetry(GroupTelemetry.rejoin(reason: reason))
            scheduleMediaRequest(callId: callId, generation: generation, delayMs: delayMs) { [weak self] in
                self?.requestMediaRejoin(reason: reason)
            }
        case .fail(let error):
            failMedia(error)
        }
    }

    private func scheduleMediaRequest(callId: String, generation: Int, delayMs: Int64, _ block: @escaping () -> Void) {
        let run: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let valid = callId == self.activeCallId && generation == self.linkGeneration
            self.lock.unlock()
            if valid { block() }
        }
        if delayMs <= 0 {
            run()
        } else {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(Int(delayMs)), execute: run)
        }
    }

    private func requestMediaRejoin(reason: String) {
        lock.lock()
        guard let callId = activeCallId else {
            lock.unlock()
            return
        }
        mediaJoinRequested = true
        mediaJoinRequestedAtMs = nowMs()
        rejoinReasonInFlight = reason
        let previousTimeout = mediaReadyTimeout
        let item = DispatchWorkItem { [weak self] in self?.mediaReadyTimedOut(callId: callId) }
        mediaReadyTimeout = item
        lock.unlock()
        previousTimeout?.cancel()
        manager.requestMediaRejoin(callId: callId, reason: reason)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + mediaReadyTimeoutSeconds, execute: item)
    }

    /// A media error the user must see: reported, then the call is left (a camera
    /// problem never gets here).
    private func failMedia(_ error: GroupCallMediaError) {
        print("[GroupCallController] media failed: \(error)")
        reportMediaError(error)
        guard error.isFatal else { return }
        var reason = "media_error"
        if case .other(let code) = error { reason = "media_error_\(code.prefix(16))" }
        setState(.failed(reason: reason))
        manager.leaveGroupCall()
        teardown(reason: reason)
    }

    // MARK: - Publish policy (thermal / battery / congestion)

    private func startPolicyObservers() {
        stopPolicyObservers()
        let center = NotificationCenter.default
        let reapply: (Notification) -> Void = { [weak self] _ in self?.applyPublishPolicy() }
        lock.lock()
        thermalObserver = center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil, using: reapply)
        powerObserver = center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil, using: reapply)
        lock.unlock()
    }

    private func stopPolicyObservers() {
        lock.lock()
        let thermal = thermalObserver
        let power = powerObserver
        thermalObserver = nil
        powerObserver = nil
        lock.unlock()
        if let observer = thermal { NotificationCenter.default.removeObserver(observer) }
        if let observer = power { NotificationCenter.default.removeObserver(observer) }
    }

    private func noteUplinkCongested() {
        lock.lock()
        congestionSteps = min(3, congestionSteps + 1)
        let previous = congestionReset
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.congestionSteps = 0
            self.lock.unlock()
            self.applyPublishPolicy()
        }
        congestionReset = item
        lock.unlock()
        previous?.cancel()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30, execute: item)
        applyPublishPolicy()
    }

    /// Spec §4.4 / §4.7: phones MAY publish only l/m under thermal or battery
    /// pressure; congestion drops to substream l, then stops the video publish,
    /// never the audio.
    func applyPublishPolicy() {
        lock.lock()
        let current = link
        let camera = cameraOn
        let steps = congestionSteps
        let stopped = videoStoppedByPolicy
        lock.unlock()
        guard let link = current, camera else { return }
        let thermal: GroupPublishPolicy.Thermal
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = .nominal
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .serious
        }
        let decision = GroupPublishPolicy.decide(
            thermal: thermal, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, congestionSteps: steps)
        if decision.publishVideo {
            link.setActiveLayers(decision.activeLayers)
            if stopped {
                lock.lock()
                videoStoppedByPolicy = false
                lock.unlock()
                Task { await link.setPublishVideo(true) }
            }
        } else if !stopped {
            lock.lock()
            videoStoppedByPolicy = true
            lock.unlock()
            Task { await link.setPublishVideo(false) }
        }
    }
}

// MARK: - E2EE environment

/// `GroupE2eeEnvironment` of one call: routes the coordinator's outward calls
/// into the controller and provides its timers on the coordinator's queue.
private final class GroupCallE2eeEnvironment: GroupE2eeEnvironment {

    private final class E2eeTimer: GroupE2eeTimer {
        private let item: DispatchWorkItem
        init(_ item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }

    private weak var controller: GroupCallController?
    private let queue: DispatchQueue

    init(controller: GroupCallController, queue: DispatchQueue) {
        self.controller = controller
        self.queue = queue
    }

    func randomKey() -> Data { GroupE2ee.randomKey() }

    func installKey(_ key: Data, index: Int32, participantId: String) {
        controller?.e2eeInstallKey(key, index: index, participantId: participantId)
    }

    func setSendKeyIndex(_ index: Int32) { controller?.e2eeSetSendKeyIndex(index) }

    func requestKeyFrame() { controller?.e2eeRequestKeyFrame() }

    func sendControl(to userId: String, envelopeJson: String, completion: @escaping (Bool) -> Void) {
        guard let controller = controller else {
            queue.async { completion(false) }
            return
        }
        controller.e2eeSend(to: userId, json: envelopeJson) { [queue] ok in
            queue.async { completion(ok) }
        }
    }

    func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    func schedule(afterMs: Int64, _ block: @escaping () -> Void) -> GroupE2eeTimer {
        let item = DispatchWorkItem(block: block)
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(max(0, afterMs))), execute: item)
        return E2eeTimer(item)
    }

    func emit(_ event: GroupTelemetryEvent) { controller?.emitTelemetry(event) }
}

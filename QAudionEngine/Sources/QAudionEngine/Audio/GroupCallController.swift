import Foundation

/// Drives an N-way audio-only group call over the server-side SFU.
/// Direct port of Android's `feature/feature-call/.../domain/GroupCallController.kt`,
/// using the SAME per-sender `GroupSession`/`GroupSenderKey` ratchet (already
/// live cross-platform for group TEXT CHAT) instead of the old insecure
/// server-decryptable shared room key (`SHA-256(callId || "qaudion-group-v1")`).
///
/// Responsibilities:
/// 1. Bridge to `BCryptoGroupCallManager` for the WebSocket protocol
///    (group_call_create / join / leave / forward) — VERIFIED against the
///    live `cmd/bcrypto-lite/main.go` handlers (2026-07-13), see that
///    file's header comment for the previous dead-protocol mismatch.
/// 2. Bootstrap + maintain one `GroupSession` per call: exactly one own
///    send chain, one recv chain per other participant, populated as
///    `sender_key_init`/`sender_key_rotate` control envelopes arrive.
/// 3. W-GRPREKEY: rekey our own send chain on ANY member departure,
///    converging on the server-canonical `sender_key_epoch` (same trick as
///    Android — see `handleDepartures`).
/// 4. On send: capture mic → Opus encode → seal under our OWN send chain
///    (single ciphertext, every recipient can open it) → ship via
///    `forwardAudioFrame` (server broadcasts to all, no per-recipient
///    targeting exists on the wire).
/// 5. On receive: open under the sender's recv chain (per-sender Opus
///    decoder state) → push PCM into the shared playback jitter buffer.
public final class GroupCallController: @unchecked Sendable {

    public enum State: Equatable {
        case idle
        case connecting(callId: String)
        case active(callId: String, participants: [String])
        case failed(reason: String)
    }

    /// Locked computed property — a review of today's work found ONE bare
    /// unlocked read of the old stored `state` property racing concurrent
    /// writers (`wireManagerCallbacks`'s `.creating` case, fired from the
    /// manager's own callback thread, vs `setState` from other threads).
    /// `_state` is the lock-protected backing field; every internal site
    /// that already holds `lock` reads/writes `_state` directly (reading
    /// the public property here would self-deadlock, NSLock is
    /// non-reentrant), every other site goes through this getter.
    private var _state: State = .idle
    public var state: State { lock.lock(); defer { lock.unlock() }; return _state }
    public var onStateChange: ((State) -> Void)?

    /// `var` (not `let`) since W-GRPSTALEMGR: `rebind(manager:)` swaps in
    /// the fresh manager `connectPersistentSocket` builds on every socket
    /// rebuild. Only ever reassigned there (MainActor, between calls) —
    /// every other access keeps treating it as effectively immutable.
    private var manager: BCryptoGroupCallManager
    private let lock = NSLock()
    private var muted = false
    /// Per-sender Opus decoders (one per peer; Opus state is stateful
    /// across frames — sharing one decoder across senders desyncs).
    private var perSenderDecoders: [String: OpusCodec] = [:]
    private let encoder: OpusCodec = OpusCodec()

    // ─── W-GRPSENDERKEY: per-sender group keying ───────────────────────

    private let groupSession = GroupSession()
    private var groupState: GroupState?
    private var activeCallId: String?
    /// Peers we've successfully delivered our `sender_key_init` to this
    /// call. Drives the W-GRPSENDERKEY-RETRY loop in `onUpdate` (re-sends
    /// to any capable peer not yet in this set on every roster update) —
    /// mirrors Android's `initSentTo`. No longer gates `sealForTransmit`
    /// (see that method's kdoc): a peer missing from this set just can't
    /// decrypt our audio yet, it doesn't block sending to everyone else.
    private var initSentTo: Set<String> = []
    /// W-GRPSENDERKEY-NACK — peers we've already sent a `sender_key_nack`
    /// this call (see `onE2eeStateChanged` wiring in `handleSfuToken`);
    /// rate-limits to one nack per peer per call.
    private var nackedPeers: Set<String> = []

    // ─── W-GRPLIVEKIT: LiveKit SFU media transport (capability-gated) ──
    // When `usingSfu` (default true), an active call first requests a
    // LiveKit access token; media rides the SFU with native per-participant
    // E2EE keyed from `groupSession`'s `currentSendKey`/`currentRecvKey`
    // (SK_0, pinned — the send chain is never advanced by `encryptForGroup`
    // while under the SFU). On `group_call_sfu_unavailable`, or if the
    // token round-trip / room connect fails, this flips to false and the
    // call falls back to the pre-existing WS-relay mesh path below
    // (`sealForTransmit`/`handleIncomingFrame`) — soft fallback, never a
    // hard failure. Mirrors Desktop's `GroupCallController` (main process)
    // `usingSfu`/`groupState`/`emitSelfMediaKey`/`emitRemoteMediaKey`.
    private var usingSfu = true
    private var sfuRoom: LiveKitGroupCallRoom?
    private static let livekitKeyringSize: UInt32 = 16
    /// W-GRPVIDEO: true when THIS call was created/joined as a video call
    /// (the creator's `callType` on `createCall`, or the invite's
    /// `call_type` threaded into `join`). Read by `handleSfuToken` to decide
    /// whether the LiveKit room publishes a camera track from the start —
    /// independent of `usingSfu`/`groupState`, set alongside them in
    /// `bootstrapGroupSession` and reset in `teardown`.
    private var wantsVideo = false

    /// A remote participant's SFU audio/video track was subscribed
    /// (type-erased `RemoteAudioTrack`/`RemoteVideoTrack` — see
    /// `LiveKitGroupCallRoom`'s doc comment for why). App layer attaches
    /// these to `VideoView`/audio rendering. Only fires when the call is
    /// actually running over the SFU.
    public var onRemoteAudioTrack: ((_ identity: String, _ track: AnyObject) -> Void)?
    public var onRemoteVideoTrack: ((_ identity: String, _ track: AnyObject) -> Void)?
    /// W-GRPVIDEO: fires with OUR OWN camera track (type-erased, nil ==
    /// camera off) — see `LiveKitGroupCallRoom.onLocalVideoTrack`.
    public var onLocalVideoTrack: ((_ track: AnyObject?) -> Void)?
    /// W-GRPSCREENSHARE: passthrough of `LiveKitGroupCallRoom.
    /// onRemoteScreenShareTrack` / `onLocalScreenShareChanged` — see those
    /// properties' kdoc for the full rationale (separate from the camera
    /// callbacks above since a participant can publish both at once).
    public var onRemoteScreenShareTrack: ((_ identity: String, _ track: AnyObject?) -> Void)?
    public var onLocalScreenShareChanged: ((Bool) -> Void)?
    /// SFU-specific participant presence (independent of `onParticipantsChanged`,
    /// which reflects the WS roster regardless of media transport).
    public var onSfuParticipant: ((_ identity: String, _ present: Bool) -> Void)?
    public var onSfuError: ((Error) -> Void)?
    /// Tier-1 layout toggle (item 5, 2026-07-16 wire contract) — passthrough
    /// of `LiveKitGroupCallRoom.onSpeakingParticipantsChanged`. Pure
    /// data-layer plumbing in this pass: no wire message, LiveKit's own
    /// native active-speaker detection (see that property's kdoc).
    public var onActiveSpeakersChanged: (([String]) -> Void)?
    /// Tier-1 (2026-07-16 wire contract) — fires once the local mic has
    /// been (attempted to be) auto-muted in response to a received
    /// `group_call_mute_request_recv`. `requesterId` is the peer's userId;
    /// resolving it to a display name for the one-shot toast ("{displayName}
    /// ti ha silenziato") is an app-layer concern, same division of labor
    /// as `BCryptoGroupCallManager.nameResolver`. No confirmation UI is
    /// needed on the requester's side — see this callback's call site
    /// (`handleMuteRequest`) for the auto-mute-on-receipt rationale.
    public var onMuteRequested: ((_ requesterId: String) -> Void)?

    /// W-GRPTELEM: forwards this call's SFU/media telemetry to the app
    /// layer. QAudionEngine cannot import QAudionApp
    /// (`TelemetryService`/`CallMediaTelemetry` live there) — same
    /// rationale as `QAudionWebRtcCallController.videoTelemetry` on the
    /// 1:1 path. `AppState.ensureGroupCallController` wires this once,
    /// mirroring that pattern. Fed by `LiveKitGroupCallRoom.onTelemetry`
    /// (which already emits `call.media.connected` — wired in
    /// `handleSfuToken` below) plus this controller's own
    /// `call.media.ended` (see `teardown`), so the connected/ended pair
    /// both flow through the same closure regardless of which layer
    /// originates them.
    public var groupTelemetry: ((_ kind: String, _ callId: String?, _ attrs: [String: Any]) -> Void)?

    // ─── Tier-1: transient reactions + raised-hand state (data layer) ──
    // In-memory only — never persisted, matches this file's "no
    // persistence anywhere" convention (no MessageStore/CoreData/SQLite).

    /// One reaction to render — sender + emoji + a monotonic id (so
    /// SwiftUI list diffing never collides same-emoji-same-sender bursts).
    /// Auto-discarded ~2s after arrival (see `appendReactionEvent`).
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

    private var _reactionEvents: [ReactionEvent] = []
    /// KNOWN ACCEPTED LIMITATION (wire contract item 3): fed ONLY by the
    /// `group_call_raise_hand_recv` stream since joining (plus our own
    /// optimistic toggle below) — there is no server-side authoritative
    /// roster snapshot, so a participant who joins/reconnects mid-call
    /// will not see who currently has a hand raised. Shipping this
    /// ephemeral-only version deliberately; adding server-side state is
    /// out of scope for this pass.
    private var _raisedHands: Set<String> = []

    public var reactionEvents: [ReactionEvent] { lock.lock(); defer { lock.unlock() }; return _reactionEvents }
    public var raisedHands: Set<String> { lock.lock(); defer { lock.unlock() }; return _raisedHands }
    /// Fires with the full up-to-date list on every change (own optimistic
    /// send OR an incoming `_recv`) — mirrors `onParticipantsChanged`'s
    /// passthrough shape so a future ViewModel can just re-render from it.
    public var onReactionEventsChanged: (([ReactionEvent]) -> Void)?
    public var onRaisedHandsChanged: ((Set<String>) -> Void)?

    /// Send + optimistically render our own group-call reaction. Per the
    /// wire contract: the sender does NOT wait for the `_recv` round trip —
    /// the local entry is appended immediately, then the manager ships the
    /// wire message. Server does not validate `emoji` (opaque, client UI
    /// constraint only — see `BCryptoGroupCallManager.sendGroupCallReaction`).
    public func sendReaction(emoji: String) {
        manager.sendGroupCallReaction(emoji: emoji)
        appendReactionEvent(senderId: manager.selfUserId, emoji: emoji)
    }

    /// Raise/lower our own hand — explicit boolean toggle (idempotent
    /// resend is safe), NOT a continuous-activity ping like `group_typing`.
    /// Reflects the toggle into `raisedHands` locally too (the server never
    /// echoes our own send back to us, so without this our own raised hand
    /// would never appear in the set the way every OTHER participant's does).
    public func setHandRaised(_ raised: Bool) {
        manager.sendGroupCallRaiseHand(raised: raised)
        let selfId = manager.selfUserId
        lock.lock()
        if raised { _raisedHands.insert(selfId) } else { _raisedHands.remove(selfId) }
        let snapshot = _raisedHands
        lock.unlock()
        onRaisedHandsChanged?(snapshot)
    }

    /// Tier-1 mute-request auto-mute-on-receipt (item 4, 2026-07-16 wire
    /// contract) — Signal's real behavior: no confirmation dialog, fully
    /// reversible in one tap, no lockout. Flips BOTH the legacy
    /// WS-relay-mesh gate (`setMuted`, gates `sendOutgoingOpusFrame`) AND
    /// the real LiveKit SFU mic toggle (`setMicrophoneEnabled`) — item 6's
    /// fix: before it existed only the former did anything, so a
    /// mute-request received during an actual SFU call silently failed to
    /// touch the real outbound audio.
    private func handleMuteRequest(fromSenderId: String) {
        setMuted(true)
        Task { [weak self] in
            _ = await self?.setMicrophoneEnabled(false)
        }
        onMuteRequested?(fromSenderId)
    }

    /// Append one reaction and schedule its ~2s auto-expiry. Removes by
    /// `id` specifically (not "the oldest") so a fast burst of reactions
    /// from different senders/emoji expires each entry independently
    /// instead of clearing the whole list on the first timer to fire.
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

    /// W-GRPVIDEO: whether the call is actually riding the LiveKit SFU right
    /// now. The WS-relay mesh fallback path has no video pipeline, so the UI
    /// gates the camera toggle on this.
    public var isUsingSfu: Bool { lock.lock(); defer { lock.unlock() }; return usingSfu }
    /// W-GRPVIDEO: whether THIS call was created/joined as a video call —
    /// read by the UI once on the `.active` transition to seed its own
    /// camera-on/off toggle state.
    public var callWantsVideo: Bool { lock.lock(); defer { lock.unlock() }; return wantsVideo }
    /// W-GRPSFUGHOST follow-up (2026-07-20) — passthrough of
    /// `LiveKitGroupCallRoom.connectedRemoteIdentities`: every remote
    /// identity the SFU room ALREADY considers connected, readable
    /// synchronously instead of only via future `onSfuParticipant` events.
    /// Lets a freshly-(re)built `GroupCallViewModel` (rebuilt on every
    /// socket rebuild — see `rebind(manager:)`'s kdoc above) seed its
    /// `sfuPresentIdentities` at bind time, the SFU-presence counterpart of
    /// the existing `manager.participants` WS-roster snapshot. Empty
    /// (never nil) when not currently riding the SFU.
    public var sfuConnectedIdentities: [String] {
        lock.lock()
        let room = sfuRoom
        lock.unlock()
        return room?.connectedRemoteIdentities ?? []
    }

    // ─── Control-envelope transport ───────────────────────────────────
    // Deliberately NOT owned here. An earlier version of this file kept its
    // OWN `MessageRatchet`/`SovereignKeyVault` static instances for the
    // pairwise 1:1 crypto used to seal `qa_grpcall_ctrl` envelopes — but
    // those instances read/write the SAME physical Keychain-backed ratchet
    // session as AppState's single shared `sharedV4Ratchet`/`ratchet`
    // instances (used for chat + every other opaque_message consumer).
    // TWO independent `MessageRatchet` objects driven concurrently (this
    // controller's callbacks fire off the WS client's own background queue,
    // chat fires on MainActor) can each load the same persisted session
    // before either saves its advance — the second save silently clobbers
    // the first's chain-index advance, risking an AEAD (key,nonce) reuse or
    // a legitimate peer message getting rejected as a replay. This is
    // exactly the multi-instance clobber hazard AppState's own doc comment
    // says was already fixed for v4 by unifying send+receive into ONE
    // shared instance — a second, separate instance here reintroduced it.
    // Fix: `onSendControlEnvelope` (below) and the receive-side decrypt in
    // `AppState.dispatchInboundOpaque` Path C both route through AppState's
    // SAME shared `Self.ratchet`/`Self.sharedV4Ratchet` instances instead.

    // W358: optional audio I/O pipeline. When set via
    // `attachAudioPipeline()`, the controller takes ownership of the
    // capture source (mic → PCM → encrypt → forward) and the playback
    // sink (incoming PCM → playback). Both are ManagedLifecycle: start
    // fires when the call enters .active, stop fires on teardown.
    private var capture: AudioCapture?
    private var playback: AudioPlayback?

    // XP-crackle — same fix as CallService's txAudioQueue: AudioCapture's
    // input tap runs on a dedicated real-time Core Audio thread, and
    // `sendOutgoingPcmFrame` used to run there synchronously (Opus encode +
    // seal + WS forward). Hand off to this dedicated SERIAL queue instead —
    // serial so frames are still processed in capture order.
    private let txAudioQueue = DispatchQueue(
        label: "com.bcrypto.qaudion.groupcall.tx-audio-encode", qos: .userInitiated)

    public init(manager: BCryptoGroupCallManager) {
        self.manager = manager
        wireManagerCallbacks()
    }

    /// W-GRPSTALEMGR (2026-07-19, iPad late-join "in the call but sees
    /// nobody"): re-point this controller at the NEW manager built for a
    /// rebuilt socket. `connectPersistentSocket` constructs a fresh
    /// `BCryptoGroupCallManager` against every fresh WS (foreground
    /// reconnect / `reviveSignalingSocket` on the incoming-call push — its
    /// "runs exactly once per AppState lifetime" comment predates those
    /// `liveProvider = nil` paths), but `ensureGroupCallController` used to
    /// return this controller still wired to the FIRST manager. The new
    /// manager — the one whose registered WS handlers actually receive
    /// `group_call_update` — had every callback slot nil, so a late
    /// joiner's one-and-only full-roster snapshot fired into nothing
    /// (further updates only come on join/leave, so the roster stayed
    /// empty for the whole call), and `join()` went out on the dead/stale
    /// previous WS. Clears the OLD manager's slots too, so a zombie socket
    /// that later revives can't double-deliver stale events into this
    /// controller.
    public func rebind(manager newManager: BCryptoGroupCallManager) {
        guard newManager !== manager else { return }
        let old = manager
        old.onStateChanged = nil
        old.onParticipantsChanged = nil
        old.onGroupUpdate = nil
        old.onAudioFrame = nil
        old.onSfuTokenReceived = nil
        old.onSfuUnavailable = nil
        old.onGroupCallReactionReceived = nil
        old.onGroupCallRaiseHandReceived = nil
        old.onGroupCallMuteRequestReceived = nil
        manager = newManager
        wireManagerCallbacks()
    }

    /// W-GRPREJOIN (2026-07-20, call FB75E465): re-send `group_call_join`
    /// for the in-flight call after the signaling socket reconnected. A
    /// dropped WS gets this participant reaped from the server's roster
    /// once the ghost-grace expires, so a reconnect that does NOT re-join
    /// leaves the user stranded alone in the call UI — the server allows
    /// rejoin for invited/former participants. Called by the app layer on
    /// the WS transition INTO `.authenticated` (once per reconnect by
    /// construction); a strict no-op unless this controller is currently
    /// `.connecting`/`.active`, so it can never join anything
    /// spontaneously. Deliberately does NOT re-run
    /// `bootstrapGroupSession`: the sender-key chains survive the socket
    /// loss, and a re-bootstrap would rotate our send key without a
    /// `sender_key_rotate` reaching the other members. The server's
    /// `group_call_update` reply re-drives the roster + (via the manager's
    /// `.active` transition) the SFU token round-trip when the LiveKit
    /// room needs rebuilding — both paths are already no-ops when the
    /// room/pipeline is still alive.
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

    /// Create a new group call and invite the listed peers.
    /// Returns the freshly-minted call id (also held internally), or nil if
    /// the manager refused (already in a call).
    ///
    /// W-GRPRING — `callType` / `groupId` / `groupName` are relayed by the
    /// server onto every invitee's `group_call_invite` AND the wake-up push
    /// (see `BCryptoGroupCallManager.createGroupCall`). Pass the real group
    /// context whenever the call is started from a persisted group; the
    /// contact-picker (ad-hoc) path leaves them empty.
    @discardableResult
    public func createCall(
        invitees: [String],
        title: String = "",
        callType: String = "audio",
        groupId: String = "",
        groupName: String = ""
    ) -> String? {
        guard let callId = manager.createGroupCall(
            recipients: invitees,
            title: title,
            callType: callType,
            groupId: groupId,
            groupName: groupName
        ) else {
            return nil
        }
        bootstrapGroupSession(callId: callId, initialPeers: invitees, video: callType == "video")
        setState(.connecting(callId: callId))
        return callId
    }

    /// - Parameter video: whether the incoming invite this joins was a
    ///   video call (`IncomingGroupCallInvite.hasVideo`) — determines
    ///   whether the LiveKit room publishes our camera from the start once
    ///   the SFU token round-trip resolves (`handleSfuToken`).
    public func join(callId: String, video: Bool = false) {
        bootstrapGroupSession(callId: callId, initialPeers: [], video: video)
        manager.joinGroupCall(callId: callId)
        setState(.connecting(callId: callId))
    }

    public func leave() {
        manager.leaveGroupCall()
        stopAudioPipeline()
        teardown(reason: "user_left")
    }

    public func endCallForAll() {
        manager.endGroupCall()
        stopAudioPipeline()
        teardown(reason: "ended_for_all")
    }

    public func setMuted(_ muted: Bool) {
        lock.lock(); self.muted = muted; lock.unlock()
    }

    public var isMuted: Bool {
        lock.lock(); defer { lock.unlock() }; return muted
    }

    /// Hook for the audio-capture path: feed one captured Opus frame
    /// (already-encoded) to be sealed under our own sender-key send chain
    /// and shipped to every other participant via the SFU (single relay,
    /// no per-recipient targeting — see `BCryptoGroupCallManager.forwardAudioFrame`).
    public func sendOutgoingOpusFrame(_ opus: Data) {
        guard !isMuted else { return }
        guard let sealed = sealForTransmit(plaintext: opus) else { return }
        manager.forwardAudioFrame(sealed)
    }

    /// Convenience wrapper: encode raw PCM → seal → forward in one step.
    public func sendOutgoingPcmFrame(_ pcm: Data) {
        guard let opus = encoder.encode(pcm) else { return }
        sendOutgoingOpusFrame(opus)
    }

    /// PCM frames produced from the inbound stream are surfaced through
    /// this callback — the AppState wires this into the AudioPlayback
    /// jitter buffer (one shared buffer; multiple talkers interleave at
    /// frame granularity until a real N-source mixer lands).
    public var onIncomingPcmFrame: ((String, Data) -> Void)?

    /// W358: bind the in-process AudioCapture (mic) and AudioPlayback
    /// (speaker) lifecycles to this call.
    public func attachAudioPipeline(capture: AudioCapture, playback: AudioPlayback) {
        lock.lock()
        self.capture = capture
        self.playback = playback
        lock.unlock()
        capture.onFrame = { [weak self] pcm in
            // XP-crackle — off the real-time tap thread; see txAudioQueue kdoc.
            self?.txAudioQueue.async { [weak self] in
                self?.sendOutgoingPcmFrame(pcm)
            }
        }
        // Default sink: dump incoming PCM into the jitter buffer.
        onIncomingPcmFrame = { [weak self] _, pcm in
            self?.playback?.playFrame(pcm)
        }
    }

    /// Manually start the audio pipeline. Called from the state
    /// transition into .active; safe to invoke multiple times. Holds
    /// `lock` across the ENTIRE start (not just the field reads) — a
    /// review found that releasing the lock before calling
    /// `.start()`/`.stop()` on the escaped `capture`/`playback` references
    /// let a concurrent `stopAudioPipeline()` (e.g. from `.ended`/`leave()`
    /// racing the `.active` transition) invoke `.stop()` on the SAME
    /// instance with no mutual exclusion between the two calls. Calls into
    /// this pair are rare (call start/end), so serializing them fully is a
    /// clean fix with no meaningful throughput cost.
    public func startAudioPipeline() throws {
        lock.lock()
        defer { lock.unlock() }
        if let playback = playback {
            try? playback.start()
        }
        if let capture = capture {
            try capture.start()
        }
    }

    /// Stop the audio pipeline. Idempotent. See `startAudioPipeline` for
    /// why this holds `lock` across the calls, not just the field reads.
    public func stopAudioPipeline() {
        lock.lock()
        defer { lock.unlock() }
        capture?.stop()
        playback?.stop()
    }

    /// Receive side of the `qa_grpcall_ctrl` opaque-message wrapper (see
    /// `AppState.dispatchInboundOpaque`, Path C). The app layer decrypts the
    /// outer 1:1 envelope (it owns the WS/opaque_message plumbing) and hands
    /// us the PLAINTEXT `{qa_grp:1, t:..., g:..., e:..., seed:..., idx:?}`
    /// JSON string plus the sender id. Silently ignores anything not for
    /// THIS active call — chat's own `qa_grp:1` envelopes never reach here
    /// (they ride the regular message channel, not opaque_message).
    public func onGroupCallControlEnvelope(json: String, fromUserId: String) {
        // W-GRPCALL-DIAG (2026-07-15, incident 419eb1dc): every early-return
        // below used to be totally silent — a peer's sender_key_init could
        // vanish at any of these gates with zero observable trace anywhere
        // (device log or server). This is the single most important new
        // telemetry in this pass: it directly distinguishes "never arrived
        // here at all" (transport/decrypt problem, see AppState's
        // onSendControlEnvelope/dispatchInboundOpaque logging) from
        // "arrived but was rejected here" (protocol/state problem) from
        // "installed successfully" (the happy path — rules THIS hop out).
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            print("[GroupCallController][telemetry] ctrl envelope from \(fromUserId.prefix(8)) failed: not valid JSON")
            return
        }
        guard (obj["qa_grp"] as? NSNumber)?.intValue == 1 else {
            print("[GroupCallController][telemetry] ctrl envelope from \(fromUserId.prefix(8)) failed: missing/wrong qa_grp marker")
            return
        }
        lock.lock()
        guard let gs = groupState, let callId = activeCallId else {
            lock.unlock()
            print("[GroupCallController][telemetry] ctrl envelope from \(fromUserId.prefix(8)) failed: no active GroupState (call not bootstrapped or already torn down)")
            return
        }
        let expectedG = GroupSenderKey.toHex(Data(callId.utf8))
        guard obj["g"] as? String == expectedG else {
            lock.unlock()
            print("[GroupCallController][telemetry] ctrl envelope from \(fromUserId.prefix(8)) failed: groupId mismatch (envelope for a different/stale call)")
            return
        }
        // W-GRPLIVEKIT: set on a successful install so we can push the fresh
        // SK_0 into the SFU key provider AFTER releasing `lock` below —
        // `applySfuRemoteKey` takes the lock itself (NSLock is non-reentrant,
        // see the kdoc on `_state`/`lock` near the top of this file).
        var installedSenderId: String?
        var nackRetryEnv: SenderKeyInitEnvelope?
        let envType = obj["t"] as? String ?? "?"
        switch envType {
        case "sender_key_init":
            guard let e = (obj["e"] as? NSNumber)?.uint32Value,
                  let seed = obj["seed"] as? String,
                  let idx = (obj["idx"] as? NSNumber)?.uint64Value else {
                lock.unlock()
                print("[GroupCallController][telemetry] sender_key_init from \(fromUserId.prefix(8)) failed: malformed envelope (missing e/seed/idx)")
                return
            }
            let env = SenderKeyInitEnvelope(g: expectedG, e: e, seed: seed, idx: idx)
            do {
                try groupSession.handleSenderKeyInit(state: gs, env: env, fromUserId: fromUserId)
                installedSenderId = fromUserId
                print("[GroupCallController][telemetry] sender_key_init INSTALLED sender=\(fromUserId.prefix(8)) epoch=\(e) idx=\(idx)")
            } catch {
                print("[GroupCallController][telemetry] sender_key_init FAILED sender=\(fromUserId.prefix(8)) epoch=\(e) reason=\(error)")
            }
        case "sender_key_rotate":
            guard let e = (obj["e"] as? NSNumber)?.uint32Value,
                  let seed = obj["seed"] as? String else {
                lock.unlock()
                print("[GroupCallController][telemetry] sender_key_rotate from \(fromUserId.prefix(8)) failed: malformed envelope (missing e/seed)")
                return
            }
            let env = SenderKeyRotateEnvelope(g: expectedG, e: e, seed: seed)
            do {
                try groupSession.handleSenderKeyRotate(state: gs, env: env, fromUserId: fromUserId)
                installedSenderId = fromUserId
                print("[GroupCallController][telemetry] sender_key_rotate INSTALLED sender=\(fromUserId.prefix(8)) epoch=\(e)")
            } catch {
                print("[GroupCallController][telemetry] sender_key_rotate FAILED sender=\(fromUserId.prefix(8)) epoch=\(e) reason=\(error)")
            }
        case "sender_key_nack":
            // W-GRPSENDERKEY-NACK — fromUserId has no usable key from us
            // (their LiveKit reported missing_key/decryption_failed for our
            // track). Clear our own send-confirmation gate AND resend right
            // now, rather than waiting for the next onUpdate roster event —
            // a stable call might not get another one for the rest of the
            // call.
            initSentTo.remove(fromUserId)
            nackRetryEnv = SenderKeyInitEnvelope(
                g: expectedG,
                e: gs.groupEpoch,
                seed: gs.sendChain.ck.base64EncodedString(),
                idx: gs.sendChain.nextIdx
            )
            print("[GroupCallController][telemetry] sender_key_nack received from \(fromUserId.prefix(8)) — resending init")
        default:
            print("[GroupCallController][telemetry] ctrl envelope from \(fromUserId.prefix(8)) ignored: unknown type=\(envType)")
        }
        lock.unlock()
        if let senderId = installedSenderId {
            applySfuRemoteKey(senderId: senderId)
        }
        if let retryEnv = nackRetryEnv {
            sendSenderKeyEnvelope(peer: fromUserId, selfId: manager.selfUserId, env: retryEnv)
        }
    }

    // MARK: - Internals

    /// Forwards `BCryptoGroupCallManager`'s raw state 1:1, for UI consumers
    /// (`GroupCallViewModel`) that want the manager's simple state machine
    /// rather than this controller's richer `State`. `manager.onStateChanged`
    /// is a single-slot closure — this controller MUST be its sole owner, so
    /// any other consumer (the ViewModel) observes THIS passthrough instead
    /// of touching `manager.onStateChanged` directly. Without this
    /// indirection, constructing a `GroupCallViewModel` against the same
    /// manager after this controller would silently overwrite
    /// `manager.onStateChanged` and break the audio-pipeline start/teardown
    /// logic below (this exact conflict was latent — never exercised —
    /// because neither type had a real call site until now).
    public var onManagerStateChanged: ((BCryptoGroupCallManager.State) -> Void)?
    /// Same passthrough rationale as `onManagerStateChanged`, for
    /// `manager.onParticipantsChanged`.
    public var onParticipantsChanged: (([BCryptoGroupCallManager.Participant]) -> Void)?

    private func wireManagerCallbacks() {
        manager.onStateChanged = { [weak self] s in
            guard let self = self else { return }
            self.onManagerStateChanged?(s)
            switch s {
            case .creating:
                if case .connecting = self.state { /* keep */ }
                else if let cid = self.manager.callId {
                    self.setState(.connecting(callId: cid))
                }
            case .active:
                if let cid = self.manager.callId {
                    let parts = self.manager.participants.map(\.id)
                    self.setState(.active(callId: cid, participants: parts))
                    self.lock.lock()
                    let roomExists = self.sfuRoom != nil
                    let attemptSfu = self.usingSfu && !roomExists
                    self.lock.unlock()
                    if attemptSfu {
                        // Hold off on the WS-relay mic/speaker pipeline until
                        // the SFU round-trip resolves — starting BOTH would
                        // briefly double-capture the mic (see
                        // LiveKitGroupCallRoom's dependency-comment on the
                        // separate AVAudioSession wrapper each WebRTC engine
                        // owns). `handleSfuToken`/`handleSfuUnavailable`
                        // start the mesh pipeline themselves if SFU doesn't
                        // pan out.
                        self.manager.requestSfuToken(callId: cid)
                    } else if !roomExists {
                        // crashPointId DbQJymhbdtXWBvt7OjOd_4 — only take the
                        // WS-relay mesh fallback when NO SFU room has ever
                        // been created for this call (`usingSfu` was already
                        // false, so `attemptSfu` never fires). If `sfuRoom`
                        // already exists, `manager.onStateChanged` re-firing
                        // `.active` (WS reconnect / duplicate state sync — the
                        // same redelivery class already handled by the 1:1
                        // `isGroupCallActive` gates) must be a no-op here:
                        // LiveKit already owns the hardware VP-IO unit, and
                        // starting this controller's OWN AudioCapture/
                        // AudioPlayback engine concurrently races it for the
                        // same RemoteIO unit — this is exactly how the mirror
                        // bug in `handleSfuUnavailable` crashed a live 5-way
                        // call in `AVAudioPlayerNode.play()`.
                        do { try self.startAudioPipeline() }
                        catch { print("[GroupCallController] startAudioPipeline failed: \(error)") }
                    }
                }
            case .ended:
                self.stopAudioPipeline()
                self.teardown(reason: "remote_ended")
            case .idle:
                self.setState(.idle)
            }
        }
        manager.onParticipantsChanged = { [weak self] list in
            self?.onParticipantsChanged?(list)
        }
        manager.onGroupUpdate = { [weak self] callId, participants, capable, epoch in
            self?.onUpdate(callId: callId, participants: participants, senderKeysCapable: capable, senderKeyEpoch: epoch)
        }
        manager.onAudioFrame = { [weak self] senderId, frame in
            self?.handleIncomingFrame(senderId: senderId, sealed: frame)
        }
        manager.onSfuTokenReceived = { [weak self] callId, _, url, token in
            self?.handleSfuToken(callId: callId, url: url, token: token)
        }
        manager.onSfuUnavailable = { [weak self] callId, reason in
            self?.handleSfuUnavailable(callId: callId, reason: reason)
        }
        // Tier-1 (2026-07-16 wire contract) — all three gated on
        // `callId == activeCallId`, same defensive pattern already used by
        // `handleSfuToken`/`handleSfuUnavailable` above.
        manager.onGroupCallReactionReceived = { [weak self] callId, senderId, emoji in
            guard let self = self else { return }
            self.lock.lock()
            let current = self.activeCallId
            self.lock.unlock()
            guard callId == current else { return }
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
            guard let self = self else { return }
            self.lock.lock()
            let current = self.activeCallId
            self.lock.unlock()
            guard callId == current else { return }
            self.handleMuteRequest(fromSenderId: senderId)
        }
    }

    // MARK: - W-GRPLIVEKIT: SFU lifecycle (capability-gated, soft fallback)

    /// The server minted a LiveKit token for `callId` — try to connect the
    /// SFU room. On success: push every currently-known media key
    /// (self + installed remotes) and skip the WS-relay mic pipeline
    /// entirely. On failure: flip `usingSfu` off and fall back to the
    /// pre-existing mesh pipeline, exactly as `handleSfuUnavailable` does.
    private func handleSfuToken(callId: String, url: String, token: String) {
        lock.lock()
        let stillCurrent = (callId == activeCallId) && usingSfu && sfuRoom == nil
        let video = wantsVideo
        lock.unlock()
        guard stillCurrent else { return }

        let room = LiveKitGroupCallRoom(video: video)
        room.onRemoteAudioTrack = { [weak self] id, track in self?.onRemoteAudioTrack?(id, track) }
        room.onRemoteVideoTrack = { [weak self] id, track in self?.onRemoteVideoTrack?(id, track) }
        room.onLocalVideoTrack = { [weak self] track in self?.onLocalVideoTrack?(track) }
        room.onRemoteScreenShareTrack = { [weak self] id, track in self?.onRemoteScreenShareTrack?(id, track) }
        room.onLocalScreenShareChanged = { [weak self] active in self?.onLocalScreenShareChanged?(active) }
        room.onParticipant = { [weak self] id, present in self?.onSfuParticipant?(id, present) }
        room.onError = { [weak self] err in self?.onSfuError?(err) }
        // Tier-1 layout toggle (item 5) — passthrough, see
        // `onActiveSpeakersChanged`'s kdoc.
        room.onSpeakingParticipantsChanged = { [weak self] identities in self?.onActiveSpeakersChanged?(identities) }
        // W-GRPTELEM: straight passthrough — see `groupTelemetry`'s kdoc.
        room.onTelemetry = { [weak self] kind, cid, attrs in self?.groupTelemetry?(kind, cid, attrs) }
        // W-GRPSENDERKEY-NACK (2026-07-17) — LiveKit's own E2EE state is the
        // most direct signal that WE never got a usable key for a peer
        // (mirrors Android's onE2eeStateChanged; see sendSenderKeyNackEnvelope's
        // kdoc for the full root-cause chain: sendSenderKeyEnvelope only
        // confirms local encrypt+dispatch, never actual delivery, and
        // onUpdate's retry loop only re-evaluates on roster changes, so a
        // control envelope lost in-flight — e.g. during the WS reconnect
        // that fires on every group-call participant join/leave — leaves
        // that peer permanently silent for the rest of the call). Rate-
        // limited via nackedPeers, one nack per peer per call.
        room.onE2eeStateChanged = { [weak self] identity, _, state in
            guard let self = self else { return }
            guard state == "missing_key" || state == "decryption_failed" else { return }
            self.lock.lock()
            let alreadyNacked = self.nackedPeers.contains(identity)
            if !alreadyNacked { self.nackedPeers.insert(identity) }
            self.lock.unlock()
            guard !alreadyNacked else { return }
            self.sendSenderKeyNackEnvelope(peer: identity, selfId: self.manager.selfUserId)
        }

        lock.lock()
        sfuRoom = room
        lock.unlock()

        Task { [weak self] in
            guard let self = self else { return }
            do {
                // W-GRPKEYPIN: pass our OWN current send-chain key so
                // `LiveKitGroupCallRoom.connect` seeds it into the
                // KeyProvider BEFORE publishing mic/camera — see that
                // method's kdoc (mirrors Android's `initialKeys`/
                // `computeSelfMediaKey` fix). Without this, both the mic
                // and camera tracks published inside `connect()` pin their
                // sender FrameCryptor to an empty key slot that
                // `resendMediaKeysToSfu()` below (which only runs AFTER
                // `connect()` returns) can never fix retroactively.
                try await room.connect(url: url, token: token, callId: callId, selfKey: self.computeSelfMediaKey())
                self.resendMediaKeysToSfu()
            } catch {
                print("[GroupCallController] LiveKit connect failed, falling back to WS-relay mesh: \(error)")
                self.lock.lock()
                self.usingSfu = false
                self.sfuRoom = nil
                self.lock.unlock()
                await room.disconnect()
                do { try self.startAudioPipeline() }
                catch { print("[GroupCallController] fallback startAudioPipeline failed: \(error)") }
            }
        }
    }

    /// Server declined the SFU for `callId` (`group_call_sfu_unavailable`) —
    /// soft-fall-back to the WS-relay mesh path. Never a hard failure: the
    /// call proceeds exactly as it did before this feature existed.
    ///
    /// crashPointId DbQJymhbdtXWBvt7OjOd_4 (2026-07-19, both iOS devices in a
    /// live 5-way group call, `AVAudioPlayerNode.play()` -> `AVAudioEngineGraph`
    /// -> `[NSException]` -> SIGABRT) — this handler used to call
    /// `startAudioPipeline()` unconditionally, with no check for whether
    /// `sfuRoom` already exists. `group_call_sfu_unavailable` can legitimately
    /// arrive AFTER a successful `handleSfuToken` connect (SFU node
    /// failover/health-check mid-call, or a stale/redelivered WS message —
    /// same failure class as the 1:1 `isGroupCallActive` redelivery bugs
    /// above): in that case LiveKit already owns the hardware VP-IO unit, and
    /// starting THIS controller's own `AudioCapture`/`AudioPlayback` engine
    /// concurrently races it for the same RemoteIO unit — the exact
    /// `setVoiceProcessingEnabled` conflict this whole gating scheme exists to
    /// prevent, just between two group-call-owned engines instead of a 1:1
    /// engine vs a group one. Mirror `handleSfuToken`'s own `stillCurrent`
    /// invariant (`sfuRoom == nil`): only fall back to the mesh pipeline when
    /// no SFU room has been created for this call yet.
    private func handleSfuUnavailable(callId: String, reason: String) {
        lock.lock()
        guard callId == activeCallId, sfuRoom == nil else { lock.unlock(); return }
        usingSfu = false
        lock.unlock()
        print("[GroupCallController] SFU unavailable (\(reason)) — using WS-relay mesh")
        do { try startAudioPipeline() }
        catch { print("[GroupCallController] fallback startAudioPipeline failed: \(error)") }
    }

    /// W-GRPVIDEO: mid-call camera on/off. No-op unless the call is
    /// actually riding the LiveKit SFU (`isUsingSfu`) — the WS-relay mesh
    /// fallback path has no video pipeline. Publishing a NEW video track
    /// here goes through `LiveKitGroupCallRoom.setCameraEnabled`, which
    /// rides the SAME room-level E2EE already covering the mic track — see
    /// that method's kdoc for the SDK-source verification.
    @discardableResult
    public func setVideoEnabled(_ enabled: Bool) async -> Bool {
        lock.lock()
        let room = sfuRoom
        lock.unlock()
        guard let room = room else { return false }
        do {
            try await room.setCameraEnabled(enabled)
            return true
        } catch {
            print("[GroupCallController] setVideoEnabled(\(enabled)) failed: \(error)")
            return false
        }
    }

    /// W-GRPMUTEFIX (item 6, 2026-07-16 wire contract) — the REAL SFU
    /// mic-toggle, same shape as `setVideoEnabled` above. No-op (returns
    /// false) unless the call is actually riding the LiveKit SFU — the
    /// WS-relay mesh fallback's own mute gate is `setMuted(_:)`, unaffected
    /// by this method. Called from BOTH `handleMuteRequest` (peer-initiated
    /// auto-mute) and the local mute button's own action (making that
    /// action itself SFU-aware, since the button is shown regardless of
    /// transport — see `LiveKitGroupCallRoom.setMicrophoneEnabled`'s kdoc
    /// for the bug this closes).
    @discardableResult
    public func setMicrophoneEnabled(_ enabled: Bool) async -> Bool {
        lock.lock()
        let room = sfuRoom
        lock.unlock()
        guard let room = room else { return false }
        do {
            try await room.setMicrophoneEnabled(enabled)
            return true
        } catch {
            print("[GroupCallController] setMicrophoneEnabled(\(enabled)) failed: \(error)")
            return false
        }
    }

    /// W-GRPSCREENSHARE: mid-call screen-share on/off. Same shape as
    /// `setVideoEnabled` above — no-op unless the call is actually riding
    /// the LiveKit SFU (the WS-relay mesh fallback has no video/screen-share
    /// pipeline). Unlike `setVideoEnabled`, a `true` result here does NOT
    /// mean screen sharing is now live — it only means the underlying SDK
    /// call didn't throw (which, on the FIRST toggle, just means the system
    /// broadcast picker was shown — see `LiveKitGroupCallRoom.
    /// setScreenShareEnabled`'s kdoc). The authoritative live/not-live signal
    /// is `onLocalScreenShareChanged`, wired above.
    @discardableResult
    public func setScreenShareEnabled(_ enabled: Bool) async -> Bool {
        lock.lock()
        let room = sfuRoom
        lock.unlock()
        guard let room = room else { return false }
        do {
            try await room.setScreenShareEnabled(enabled)
            return true
        } catch {
            print("[GroupCallController] setScreenShareEnabled(\(enabled)) failed: \(error)")
            return false
        }
    }

    /// W-GRPKEYPIN: compute our OWN current LiveKit media key WITHOUT
    /// applying it — used to pre-seed `LiveKitGroupCallRoom.connect` BEFORE
    /// the mic/camera publish (see that method's kdoc for the full
    /// mechanism), closing the deterministic ordering gap that
    /// `applySfuSelfKey` cannot (it bails when `sfuRoom` is still nil, which
    /// is exactly the state during connect). Returns nil when the group
    /// session/send key isn't ready yet — same derivation as
    /// `applySfuSelfKey`, mirrors Android's `computeSelfMediaKey` 1:1.
    private func computeSelfMediaKey() -> GroupMediaKey? {
        lock.lock()
        defer { lock.unlock() }
        guard let gs = groupState, let ck = groupSession.currentSendKey(state: gs) else { return nil }
        let selfId = manager.selfUserId
        let keyIndex = Int32(gs.groupEpoch % Self.livekitKeyringSize)
        return GroupMediaKey(identity: selfId, keyIndex: keyIndex, keyB64: ck.base64EncodedString())
    }

    /// Push our own key (a fresh COPY of the current send-chain SK_0) into
    /// the SFU key provider at `groupEpoch % 16`. `graceMs`, when set, is
    /// ONLY used right after a member-leave rekey (see `onUpdate`) so
    /// in-flight frames keyed under the OLD slot still decrypt during the
    /// ~3s hand-off window.
    private func applySfuSelfKey(graceMs: Double? = nil) {
        lock.lock()
        guard usingSfu, let gs = groupState, let ck = groupSession.currentSendKey(state: gs) else {
            // W-GRPCALL-DIAG fix: snapshot the lock-protected fields BEFORE
            // unlocking — `usingSfu`/`groupState` follow the same
            // lock-discipline as `_state` (see this file's kdoc on `_state`
            // near the top: "every internal site that already holds `lock`
            // reads/writes ... directly, every other site goes through [a
            // locked accessor]"). Reading them again in the print AFTER
            // `lock.unlock()` would be exactly the unlocked-read race that
            // kdoc says was already found and fixed once for `_state`.
            let usingSfuSnapshot = usingSfu
            let hasGroupState = groupState != nil
            lock.unlock()
            print("[GroupCallController][telemetry] local sender-key emit SKIPPED (usingSfu=\(usingSfuSnapshot), groupState present=\(hasGroupState))")
            return
        }
        let selfId = manager.selfUserId
        let epoch = gs.groupEpoch
        let keyIndex = Int32(epoch % Self.livekitKeyringSize)
        let keyB64 = ck.base64EncodedString()
        let room = sfuRoom
        lock.unlock()
        // W-GRPCALL-DIAG (2026-07-15, incident 419eb1dc): proves OUR OWN
        // key actually reached the SFU key provider — cross-reference
        // against every OTHER participant's "sender_key_init INSTALLED"
        // line for this same selfId/epoch to confirm delivery end-to-end.
        print("[GroupCallController][telemetry] local sender-key emitted selfId=\(selfId.prefix(8)) keyIndex=\(keyIndex) epoch=\(epoch) sfuRoomConnected=\(room != nil)")
        room?.applyKey(GroupMediaKey(identity: selfId, keyIndex: keyIndex, keyB64: keyB64, graceMs: graceMs))
    }

    /// Push `senderId`'s installed recv-chain key (SK_0 from their init/
    /// rotate) into the SFU key provider. No-op until the SFU is connected
    /// AND that sender's bootstrap envelope has been installed.
    private func applySfuRemoteKey(senderId: String) {
        lock.lock()
        guard usingSfu, let gs = groupState, let ck = groupSession.currentRecvKey(state: gs, senderId: senderId) else {
            // W-GRPCALL-DIAG fix: same snapshot-before-unlock rationale as
            // `applySfuSelfKey` above — `usingSfu`/`groupState` must not be
            // read again once `lock` is released.
            let usingSfuSnapshot = usingSfu
            let hasRecvChain = groupState?.recvChains.contains(where: { $0.0 == senderId }) ?? false
            lock.unlock()
            print("[GroupCallController][telemetry] remote recv-key push for sender=\(senderId.prefix(8)) SKIPPED (usingSfu=\(usingSfuSnapshot), recv chain installed=\(hasRecvChain))")
            return
        }
        let epoch = gs.groupEpoch
        let keyIndex = Int32(epoch % Self.livekitKeyringSize)
        let keyB64 = ck.base64EncodedString()
        let room = sfuRoom
        lock.unlock()
        print("[GroupCallController][telemetry] remote recv-key pushed to SFU sender=\(senderId.prefix(8)) keyIndex=\(keyIndex) epoch=\(epoch) sfuRoomConnected=\(room != nil)")
        room?.applyKey(GroupMediaKey(identity: senderId, keyIndex: keyIndex, keyB64: keyB64))
    }

    /// Re-push every currently-known media key (self + each installed
    /// remote) once the SFU room just connected — covers keys that were
    /// already installed into `groupState` before the room existed.
    private func resendMediaKeysToSfu() {
        lock.lock()
        let senders = groupState?.recvChains.map { $0.0 } ?? []
        lock.unlock()
        applySfuSelfKey()
        for senderId in senders { applySfuRemoteKey(senderId: senderId) }
    }

    /// W-GRPSENDERKEY: bootstrap any newly-seen capable member into our
    /// GroupSession roster + ship them our current sender_key_init.
    /// W-GRPREKEY: rekey our own send chain on ANY member departure.
    ///
    /// All `groupState` reads/mutations happen under `lock`; the actual
    /// control-envelope sends (which invoke the app-layer
    /// `onSendControlEnvelope` closure — real crypto + a network call) are
    /// deferred until AFTER `lock` is released, so a slow/blocking send
    /// never holds up a concurrent `sendOutgoingOpusFrame`/`handleIncomingFrame`
    /// on another queue.
    private func onUpdate(callId: String, participants: [String], senderKeysCapable: Set<String>, senderKeyEpoch: Int64) {
        let selfId = manager.selfUserId
        var initsToSend: [(peer: String, env: SenderKeyInitEnvelope)] = []
        var rotatesToSend: [(peer: String, env: SenderKeyRotateEnvelope)] = []

        lock.lock()
        if callId == activeCallId {
            if let gs = groupState {
                for peer in senderKeysCapable where peer != selfId {
                    if !gs.members.contains(peer) {
                        if let pkg = try? groupSession.handleMemberAdded(state: gs, newMember: peer) {
                            initsToSend.append((peer, pkg.initForNewMember))
                        }
                    } else if !initSentTo.contains(peer) {
                        // W-GRPSENDERKEY-RETRY: peer was added to the roster on
                        // a PREVIOUS onUpdate (so `handleMemberAdded` would now
                        // throw .alreadyMember), but our sender_key_init to
                        // them never landed — e.g. no pairwise PSK/v4 session
                        // existed at the time. Re-derive the SAME envelope
                        // handleMemberAdded would have returned (current send
                        // chain's seed/idx) and retry the send. Without this,
                        // a single peer with a persistently-failing control
                        // channel would never receive init, and — before this
                        // fix — that also permanently blocked ALL outgoing
                        // audio (see sealForTransmit).
                        let retryEnv = SenderKeyInitEnvelope(
                            g: GroupSenderKey.toHex(gs.groupIdBytes),
                            e: gs.groupEpoch,
                            seed: gs.sendChain.ck.base64EncodedString(),
                            idx: gs.sendChain.nextIdx
                        )
                        initsToSend.append((peer, retryEnv))
                    }
                }
                // See bcrypto-server `GroupCall.SenderKeyEpoch` kdoc + Android's
                // `handleDepartures` for the full race rationale: independent
                // clients each bumping "their own local epoch + 1" on detecting
                // a departure could diverge onto different epoch numbers and get
                // silently rejected by each other's strict
                // `env.e == state.groupEpoch` check. Pre-setting our local epoch
                // to `serverEpoch - 1` before the (always-exactly-+1)
                // `handleMemberRemoved` bump forces every survivor to converge
                // on the SAME server-canonical value regardless of
                // detection-order jitter.
                //
                // W-GRPREKEY-PARITY: mirrors Android's explicit bailout for a
                // legacy/pre-W-GRPREKEY server that never sends a positive
                // epoch — Android skips rekey-on-leave entirely rather than
                // guessing, since computing a "target" from a stale local
                // epoch would resurrect the very independent-per-client-
                // increment race this mechanism exists to prevent. The
                // deployed server always sends epoch>=1 today, so this branch
                // is not currently reachable — it exists so a future
                // divergent decode path degrades safely instead of silently.
                let departed = senderKeyEpoch > 0
                    ? Set(gs.members).subtracting(participants).subtracting([selfId])
                    : Set<String>()
                if !departed.isEmpty {
                    var lastPkg: GroupRotatePackage?
                    for removed in departed where gs.members.contains(removed) {
                        let target = UInt32(truncatingIfNeeded: senderKeyEpoch - 1)
                        gs.groupEpoch = target
                        if let pkg = try? groupSession.handleMemberRemoved(state: gs, removed: removed) {
                            lastPkg = pkg
                        }
                    }
                    if let pkg = lastPkg {
                        for peer in gs.members where peer != selfId {
                            rotatesToSend.append((peer, pkg.rotateEnvelope))
                        }
                    }
                }
            }
        }
        lock.unlock()

        for item in initsToSend {
            sendSenderKeyEnvelope(peer: item.peer, selfId: selfId, env: item.env)
        }
        for item in rotatesToSend {
            sendSenderKeyRotateEnvelope(peer: item.peer, selfId: selfId, env: item.env)
        }
        // W-GRPLIVEKIT: a non-empty `rotatesToSend` means `handleMemberRemoved`
        // just reseeded OUR send chain (departure rekey) — push the fresh
        // self key into the SFU with a ~3s grace so in-flight frames keyed
        // under the OLD slot still decrypt during the hand-off window.
        // Mirrors Desktop's `rekeyOnLeave` -> `emitSelfMediaKey(3000)`.
        if !rotatesToSend.isEmpty {
            applySfuSelfKey(graceMs: 3000)
        }

        // Tier-1 (2026-07-16 wire contract, item 3) — a departed
        // participant's raised-hand entry must not survive their
        // departure. Same roster-departure EVENT as the rekey logic above,
        // but deliberately NOT gated behind the `senderKeyEpoch > 0` legacy
        // guard: that guard exists only to protect the crypto epoch
        // derivation from a stale-server divergence risk — this is plain
        // in-memory UI state with no security implication, so it always
        // reconciles against the fresh `participants` roster.
        lock.lock()
        guard callId == activeCallId else { lock.unlock(); return }
        let departedRaised = _raisedHands.subtracting(participants)
        if !departedRaised.isEmpty {
            _raisedHands.subtract(departedRaised)
        }
        let raisedSnapshot = _raisedHands
        lock.unlock()
        if !departedRaised.isEmpty {
            onRaisedHandsChanged?(raisedSnapshot)
        }
    }

    private func handleIncomingFrame(senderId: String, sealed: Data) {
        lock.lock()
        guard let gs = groupState else { lock.unlock(); return }
        var decoder = perSenderDecoders[senderId]
        if decoder == nil {
            decoder = OpusCodec()
            perSenderDecoders[senderId] = decoder
        }
        let opus = groupSession.decryptFromGroup(state: gs, senderId: senderId, wire: sealed)
        lock.unlock()
        guard let decoder = decoder else { return }
        guard let opus = opus else {
            print("[GroupCallController] open failed sender=\(senderId)")
            return
        }
        guard let pcm = decoder.decode(opus) else {
            print("[GroupCallController] opus decode failed sender=\(senderId)")
            return
        }
        onIncomingPcmFrame?(senderId, pcm)
    }

    /// Bootstrap this call's own `GroupState` from a fresh random 32-byte
    /// secret — never derivable by the server. `groupIdBytes` is the
    /// callId's raw UTF-8 bytes, matching Android/Desktop's convention for
    /// CALLS specifically (ephemeral, not bound to any chat-group identity).
    private func bootstrapGroupSession(callId: String, initialPeers: [String], video: Bool = false) {
        let selfId = manager.selfUserId
        let members = (initialPeers + [selfId]).reduce(into: [String]()) { acc, id in
            if !acc.contains(id) { acc.append(id) }
        }
        let newState: GroupState?
        do {
            newState = try groupSession.create(
                groupIdBytes: Data(callId.utf8),
                members: members,
                selfId: selfId
            )
        } catch {
            print("[GroupCallController] GroupSession bootstrap failed — call has no E2E keying: \(error)")
            newState = nil
        }
        lock.lock()
        activeCallId = callId
        groupState = newState
        wantsVideo = video
        lock.unlock()
    }

    /// Seal `plaintext` (an Opus frame) under our own send chain.
    ///
    /// A review of today's work found the PREVIOUS version of this method
    /// blocked ALL outgoing audio (not just to one peer — to EVERYONE) until
    /// `sender_key_init` had been successfully delivered to EVERY currently-
    /// capable peer, with no retry: if delivery to even one peer permanently
    /// failed (no pairwise PSK/v4 session with them yet), the call's audio
    /// was silently dead for its entire duration. There is no actual crypto
    /// reason to withhold from PEERS WHO ARE READY just because one other
    /// peer isn't — the scheme is per-sender broadcast, so a peer without
    /// our init simply can't decrypt yet (drops our frames, same as any
    /// unknown-sender frame) until their init/retry lands (see the
    /// W-GRPSENDERKEY-RETRY loop in `onUpdate`). So this method now only
    /// requires OUR OWN send chain to exist — external security review
    /// (2026-07-13) confirmed this removes an availability bug without any
    /// confidentiality regression, and does NOT reintroduce Android's
    /// legacy-shared-key fallback (this project's stance is no silent
    /// weak-crypto fallback, ever).
    private func sealForTransmit(plaintext: Data) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard case .active = _state, let gs = groupState else { return nil }
        return try? groupSession.encryptForGroup(state: gs, plaintext: plaintext).wire
    }

    /// gap A2 / ADR-014a (W-GRPKMSPB) — `onSendControlEnvelope` became
    /// `async` (see its doc below) because the KMS-prebootstrap fallback
    /// needs real network round-trips (bundle + prekey fetch) before it
    /// can produce a wire envelope. `sendSenderKeyEnvelope`/
    /// `sendSenderKeyRotateEnvelope` themselves stay SYNCHRONOUS (their
    /// callers — `onUpdate`'s post-unlock send loop — are synchronous,
    /// non-actor-isolated code, not a place we want to introduce a new
    /// `async` propagation chain) by firing the actual call inside a
    /// fire-and-forget `Task`. This makes a KMS-prebootstrap send
    /// inherently best-effort/delayed relative to the old synchronous
    /// `Bool` return — accepted explicitly, see the TODO this closes
    /// (`AppState.attemptGroupCtrlKmsPreBootstrap` step 8).
    private func sendSenderKeyEnvelope(peer: String, selfId: String, env: SenderKeyInitEnvelope) {
        guard let json = Self.encodeInitEnvelope(env),
              let onSend = onSendControlEnvelope else { return }
        Task {
            if await onSend(peer, selfId, json) {
                lock.lock(); initSentTo.insert(peer); lock.unlock()
            }
        }
    }

    private func sendSenderKeyRotateEnvelope(peer: String, selfId: String, env: SenderKeyRotateEnvelope) {
        guard let json = Self.encodeRotateEnvelope(env),
              let onSend = onSendControlEnvelope else { return }
        Task {
            _ = await onSend(peer, selfId, json)
        }
    }

    /// W-GRPSENDERKEY-NACK — "I have no usable key for you" nudge, sent to
    /// `peer` when LiveKit reports missing_key/decryption_failed for their
    /// track (see `onE2eeStateChanged` wiring in `handleSfuToken`). Carries
    /// no key material — `peer`'s handler (the "sender_key_nack" case in
    /// `onGroupCallControlEnvelope`) just clears their own `initSentTo` gate
    /// for us and immediately resends their current key. Best-effort like
    /// every other control-plane send here.
    private func sendSenderKeyNackEnvelope(peer: String, selfId: String) {
        lock.lock()
        guard let gs = groupState else { lock.unlock(); return }
        let expectedG = GroupSenderKey.toHex(gs.groupIdBytes)
        lock.unlock()
        guard let onSend = onSendControlEnvelope else { return }
        let obj: [String: Any] = ["qa_grp": 1, "t": "sender_key_nack", "g": expectedG]
        guard let json = try? Self.jsonString(obj) else { return }
        Task {
            _ = await onSend(peer, selfId, json)
        }
    }

    /// App-layer hook: given (peer, selfId, plaintext envelope JSON), seal
    /// via the shared pairwise 1:1 ratchet + ship as an `opaque_message`,
    /// returning whether the send actually went out. Injected rather than
    /// hard-wired so this engine target never depends on
    /// `BCryptoWebSocketClient` directly, AND so the seal happens through
    /// AppState's single shared `MessageRatchet` instance rather than a
    /// second one owned here (see the control-envelope-transport comment
    /// near the top of this file). Set once at construction time in
    /// `AppState.connectPersistentSocket()`.
    ///
    /// gap A2 / ADR-014a (W-GRPKMSPB, 2026-07-15) — made `async`: when no
    /// pairwise v4/v1 session exists yet, the closure now falls through to
    /// a real KMS-prebootstrap attempt (`AppState.attemptGroupCtrlKmsPreBootstrap`),
    /// which needs to `await` two network fetches (peer bundle + one-time
    /// prekey) before it can produce a self-authenticating envelope. The
    /// previous synchronous `Bool`-returning signature had no way to do
    /// that; see the TODO this change closes for the full rationale.
    public var onSendControlEnvelope: ((_ peer: String, _ selfId: String, _ envelopeJson: String) async -> Bool)?

    /// W-GRPTELEM: `reason` closes the `call.media.connected`/`call.media.
    /// ended` pair `LiveKitGroupCallRoom.connect` opens — without this,
    /// `CallMediaTelemetry.shared` (which `AppState`'s `groupTelemetry`
    /// wiring routes `call.media.ended` into, mirroring the 1:1 path)
    /// would never see this call's `recordEnded`, leaving it "leaked"
    /// until the NEXT call's `recordConnected` force-flushes it as
    /// `"preempted"` (see that class's kdoc) — losing this call's real
    /// duration/heartbeat-count/end-reason in the process.
    private func teardown(reason: String) {
        lock.lock()
        let endedCallId = activeCallId
        perSenderDecoders.removeAll()
        muted = false
        groupState = nil
        activeCallId = nil
        initSentTo.removeAll()
        nackedPeers.removeAll()
        wantsVideo = false
        // Tier-1: reset per-call transient state so a subsequent call
        // (this controller is long-lived across calls) never leaks the
        // previous call's reactions/raised-hands.
        _reactionEvents.removeAll()
        _raisedHands.removeAll()
        let room = sfuRoom
        sfuRoom = nil
        usingSfu = true // reset the capability flag for the NEXT call
        lock.unlock()
        if let cid = endedCallId {
            groupTelemetry?("call.media.ended", cid, ["reason": reason])
        }
        if let room = room {
            Task { await room.disconnect() }
        }
        setState(.idle)
        onReactionEventsChanged?([])
        onRaisedHandsChanged?([])
    }

    private func setState(_ newState: State) {
        lock.lock(); _state = newState; lock.unlock()
        onStateChange?(newState)
    }

    // MARK: - Wire format helpers

    private static func encodeInitEnvelope(_ env: SenderKeyInitEnvelope) -> String? {
        let obj: [String: Any] = [
            "qa_grp": env.qa_grp, "t": env.t, "g": env.g,
            "e": env.e, "seed": env.seed, "idx": env.idx
        ]
        return try? Self.jsonString(obj)
    }

    private static func encodeRotateEnvelope(_ env: SenderKeyRotateEnvelope) -> String? {
        let obj: [String: Any] = [
            "qa_grp": env.qa_grp, "t": env.t, "g": env.g,
            "e": env.e, "seed": env.seed
        ]
        return try? Self.jsonString(obj)
    }

    private static func jsonString(_ obj: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

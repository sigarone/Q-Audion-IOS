import Foundation
import Combine

/// Group calls v2 — the WebSocket side of a group call: roster, invites,
/// `group_call_media_*` (the Janus room hand-out) and the tier-1 features
/// (reactions / raised hand / mute request). Media itself is NOT here: see
/// `GroupCallController` and `GroupMediaSession`. The LiveKit token round-trip,
/// the WS audio relay (`group_call_forward` / `group_call_frame`) and the
/// `supports_*` capability fields are gone (spec §2).
public final class BCryptoGroupCallManager: @unchecked Sendable {

    // MARK: - Types

    public enum State: String {
        case idle, creating, active, ended
    }

    public struct Participant: Identifiable, Equatable {
        public let id: String  // userId
        public var displayName: String
        public var isMuted: Bool = false
        public var isSpeaking: Bool = false
    }

    /// W-GRPRING — decoded `group_call_invite` (server commit 9619df4). The
    /// wire carries {call_id, creator_id, call_type, group_id, group_name};
    /// `creatorName` is resolved locally from the rubrica (the server only
    /// ships UUIDs on this frame — the human name is only present on the
    /// APNs/FCM push payload, which the app layer decodes separately).
    ///
    /// `Sendable` is explicit (public struct ⇒ no implicit conformance across
    /// the module boundary): the app layer captures this value in the
    /// `DispatchQueue.main.async` (@Sendable) hop of `onIncomingInvite`, which
    /// fires on the WS client's own delegate queue. All members are `String`.
    public struct IncomingGroupInvite: Equatable, Sendable {
        public let callId: String
        public let creatorId: String
        public let creatorName: String
        /// "audio" | "video" (server defaults an empty create to "audio").
        public let callType: String
        /// Empty for an ad-hoc group call started from the contact picker
        /// (no persisted group behind it).
        public let groupId: String
        public let groupName: String
        /// W-CALLPROMOTE — set when this invite continues a 1:1 call the
        /// creator was already on (the in-call "+" button). Informational
        /// only, no auth weight — see `createGroupCall`'s `promotedFromCallId`
        /// kdoc for the full cross-platform rationale. Empty for an ordinary
        /// group call or an old server that doesn't know the field.
        public let promotedFromCallId: String

        public init(callId: String, creatorId: String, creatorName: String,
                    callType: String, groupId: String, groupName: String,
                    promotedFromCallId: String = "") {
            self.callId = callId
            self.creatorId = creatorId
            self.creatorName = creatorName
            self.callType = callType
            self.groupId = groupId
            self.groupName = groupName
            self.promotedFromCallId = promotedFromCallId
        }
    }

    // MARK: - Published State

    private let lock = NSLock()
    private var _state: State = .idle
    private var _callId: String?
    private var _participants: [Participant] = []
    /// Server-authoritative epoch (`group_call_update.sender_key_epoch`), shown
    /// in the security sheet; the E2EE state machine consumes it through
    /// `onGroupUpdate`.
    private var _senderKeyEpoch: Int64 = 1

    public var state: State { lock.lock(); defer { lock.unlock() }; return _state }
    public var callId: String? { lock.lock(); defer { lock.unlock() }; return _callId }
    public var participants: [Participant] { lock.lock(); defer { lock.unlock() }; return _participants }
    public var senderKeyEpoch: Int64 { lock.lock(); defer { lock.unlock() }; return _senderKeyEpoch }

    /// Callback for state changes
    public var onStateChanged: ((State) -> Void)?
    /// Callback for participant list updates
    public var onParticipantsChanged: (([Participant]) -> Void)?
    /// Every `group_call_update`: roster, epoch, node and the pseudonym map.
    public var onGroupUpdate: ((GroupCallWire.Update) -> Void)?
    /// `group_call_media_ready` for the active call (spec §2.3).
    public var onMediaReady: ((GroupCallWire.MediaReady) -> Void)?
    /// `group_call_media_unavailable` (spec §2.4): a clear error, no fallback.
    public var onMediaUnavailable: ((_ callId: String, _ reason: GroupCallWire.UnavailableReason) -> Void)?
    /// `group_call_media_moved` (spec §2.5): the room moved to another node.
    public var onMediaMoved: ((_ callId: String, _ nodeId: String) -> Void)?
    /// `group_call_ended` for a call that is NOT the active one, i.e. a ring we
    /// never joined (creator ended, ring timeout, declined on another device).
    public var onRingEnded: ((_ callId: String, _ reason: String) -> Void)?
    /// `group_call_ended` for the active call, with the server's reason.
    public var onActiveCallEnded: ((_ callId: String, _ reason: String) -> Void)?

    // ─── Tier-1 call features: reactions / raise-hand / mute-request ──
    // Wire contract finalized 2026-07-16. `callId` on every one of these
    // is the EPHEMERAL call-session id (GroupCall.ID / the 1:1 call's own
    // id) — a different id space from any persisted chat `group_id`.

    /// call_reaction_recv — 1:1 call TARGETED reaction (Template A, mirrors
    /// bcrypto-server's `group_call_signal` case). Registered on THIS
    /// manager (not a 1:1-specific type) purely because it owns the shared
    /// `ws` instance for the app's whole persistent-socket lifetime — see
    /// `AppState.connectPersistentSocket`'s kdoc on why this manager is
    /// constructed exactly once per session. `callId` here is the 1:1
    /// call's OWN id (see `BCryptoCallingApiImpl.sendCallReaction`), NOT
    /// this manager's own group `_callId`. Wire: {call_id, sender_id, emoji}.
    public var onCallReactionReceived: ((_ callId: String, _ senderId: String, _ emoji: String) -> Void)?
    /// group_call_reaction_recv — group-call BROADCAST reaction (Template B,
    /// mirrors `group_typing`). Server does not validate `emoji` content —
    /// the fixed 6-emoji set is a CLIENT UI constraint only. Wire:
    /// {call_id, sender_id, emoji}.
    public var onGroupCallReactionReceived: ((_ callId: String, _ senderId: String, _ emoji: String) -> Void)?
    /// group_call_raise_hand_recv — group-call BROADCAST explicit boolean
    /// toggle (Template B). Unlike a reaction burst this is persistent
    /// state until explicitly lowered — idempotent resend is safe. Wire:
    /// {call_id, sender_id, raised}.
    public var onGroupCallRaiseHandReceived: ((_ callId: String, _ senderId: String, _ raised: Bool) -> Void)?
    /// group_call_mute_request_recv — group-call TARGETED (Template A,
    /// mirrors `group_call_signal` verbatim). FLAT, non-admin-gated: no
    /// `target_id` on the `_recv` envelope — the recipient knows they're
    /// the target by virtue of receiving it at all. Wire: {call_id, sender_id}.
    public var onGroupCallMuteRequestReceived: ((_ callId: String, _ senderId: String) -> Void)?

    // MARK: - Dependencies

    private let ws: BCryptoWebSocketClient

    /// Own userId — needed by GroupCallController to build the per-sender
    /// ratchet roster and the control-envelope AAD. Group calls have no
    /// separate "self" concept server-side (unlike the old fictional
    /// `Participant(id: "self", …)` placeholder this manager used to seed
    /// locally — removed below since the live server never echoes a "self"
    /// entry in `participants`).
    public let selfUserId: String

    /// Client-side caller-id resolver for group-call participants.
    /// The server only sends UUIDs in `GroupCallStateData.participants`
    /// (and on `group_call_invite`); we map each UUID to a human name
    /// via the local rubrica (`ContactsStore`) here so the UI shows
    /// "Mario Rossi" instead of `f1c5…`. Falls back to the bare UUID
    /// if not in rubrica.
    ///
    /// Override the default by injecting a custom resolver in the
    /// initialiser — handy for tests that want deterministic names.
    private let nameResolver: (String) -> String

    /// W-EXTRESOLVE (2026-07-20) — rubrica rows can change DURING a live
    /// call: the app layer's NameResolutionService asynchronously upserts
    /// server names / "Int. NNN" for ids that first rendered as the short8
    /// placeholder. Participant display names here are resolved once at
    /// roster build and cached (`handleGroupCallUpdate` deliberately reuses
    /// `existing` entries), so without this observer a member who joined as
    /// "Utente ab12cd34…" would stay that way for the whole call. On every
    /// `.contactsDidChange` we re-run `nameResolver` over the cached roster
    /// and re-fire `onParticipantsChanged` only if something changed.
    private var contactsObserver: (any NSObjectProtocol)?

    public init(
        ws: BCryptoWebSocketClient,
        selfUserId: String,
        nameResolver: ((String) -> String)? = nil
    ) {
        self.ws = ws
        self.selfUserId = selfUserId
        if let r = nameResolver {
            self.nameResolver = r
        } else {
            // Default resolver: fresh ContactsStore.load() lookup per
            // participant build. Cheap (UserDefaults read + JSON
            // decode of a small list); group calls are bounded to 8
            // participants so the worst-case cost is trivial.
            //
            // 2026-07-17 — a fellow group member the user never 1:1-chatted
            // with has no rubrica entry, and used to fall through to the
            // bare 36-char user_id ("il numero id lungo non deve essere
            // visualizzato come primario"). NEVER return the raw id even
            // as a last resort — truncate it, matching the 1:1 call path's
            // `callKitDisplayName` Tier-3 fallback exactly.
            self.nameResolver = { uid in
                let stored = ContactsStore().load()
                if let match = stored.first(where: { $0.userId == uid }),
                   !match.displayName.isEmpty {
                    return match.displayName
                }
                // Same humane last-resort format as the app-side central
                // resolver (QAudionApp DisplayName.shortUserFallback) —
                // this default only runs for tests/previews now that
                // AppState injects the full resolver, but keep the two in
                // the same shape so no path can regress to a bare UUID.
                return uid.count > 12 ? "Utente " + String(uid.prefix(8)) + "…" : uid
            }
        }
        registerHandlers()
        // See `contactsObserver`'s kdoc. queue nil = fires on the posting
        // thread; refreshParticipantNames is lock-guarded and resolver
        // calls happen outside the lock, so any thread is fine.
        contactsObserver = NotificationCenter.default.addObserver(
            forName: .contactsDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            self?.refreshParticipantNames()
        }
    }

    deinit {
        if let o = contactsObserver {
            NotificationCenter.default.removeObserver(o)
        }
    }

    /// Re-resolve the cached roster's display names against the (just
    /// changed) rubrica and republish if anything actually differs. Resolver
    /// calls run OUTSIDE the lock — the injected resolver reads ContactsStore
    /// / UserDefaults and may kick further async work; holding our NSLock
    /// across an arbitrary closure would invite deadlocks.
    private func refreshParticipantNames() {
        lock.lock()
        let ids = _participants.map { $0.id }
        lock.unlock()
        guard !ids.isEmpty else { return }
        var resolved: [String: String] = [:]
        for uid in ids { resolved[uid] = nameResolver(uid) }
        lock.lock()
        var changed = false
        for idx in _participants.indices {
            if let fresh = resolved[_participants[idx].id],
               !fresh.isEmpty, fresh != _participants[idx].displayName {
                _participants[idx].displayName = fresh
                changed = true
            }
        }
        let list = _participants
        lock.unlock()
        if changed { onParticipantsChanged?(list) }
    }

    /// Test seam (`@testable`): when set, every outbound message goes here instead
    /// of the socket.
    var sendOverride: ((_ type: String, _ data: [String: Any]) -> Void)?

    private func send(type: String, data: [String: Any]) {
        if let hook = sendOverride {
            hook(type, data)
        } else {
            ws.send(type: type, data: data)
        }
    }

    // MARK: - Actions

    /// Create a new group call and invite recipients.
    ///
    /// Wire: `{call_id, recipients, call_type, group_id, group_name,
    /// promoted_from_call_id}`. `call_type` / `group_id` / `group_name` are
    /// relayed verbatim by the server onto every invitee's `group_call_invite`
    /// AND the push that wakes an app-closed invitee (W-GRPRING), so every
    /// create site populates them whenever a group context exists. `title` is
    /// local-display-only. The old `supports_group_sender_keys` /
    /// `supports_raw_key_aes256` fields are gone: v2 has no capability
    /// negotiation (spec section 2).
    /// - Returns: the freshly-minted call id, so the caller (GroupCallController)
    ///   bootstraps its E2EE state under the SAME id actually sent to the server.
    @discardableResult
    public func createGroupCall(
        recipients: [String],
        title: String = "",
        callType: String = "audio",
        groupId: String = "",
        groupName: String = "",
        /// W-CALLPROMOTE - set when this call is a live promotion of a 1:1
        /// call this client was already on. Relayed verbatim by the server
        /// onto `group_call_invite` so THAT SAME peer's client can recognise
        /// the invite as a continuation of the call they are already on -
        /// informational only, never used for join authorisation.
        promotedFromCallId: String = ""
    ) -> String? {
        guard state == .idle else { return nil }
        let newCallId = UUID().uuidString
        lock.lock()
        _state = .creating
        _callId = newCallId
        // Real userId, not a "self" placeholder - matches what the server
        // will echo back in the first `group_call_update`.
        _participants = [Participant(id: selfUserId, displayName: "Tu")]
        _senderKeyEpoch = 1
        lock.unlock()
        onStateChanged?(.creating)

        send(type: "group_call_create", data: [
            "call_id": newCallId,
            "recipients": recipients,
            "call_type": callType,
            "group_id": groupId,
            "group_name": groupName,
            "promoted_from_call_id": promotedFromCallId
        ])
        return newCallId
    }

    /// Join an existing group call.
    public func joinGroupCall(callId: String) {
        lock.lock()
        _state = .creating
        _callId = callId
        lock.unlock()
        onStateChanged?(.creating)

        send(type: "group_call_join", data: ["call_id": callId])
    }

    /// Leave the current group call
    public func leaveGroupCall() {
        guard let cid = callId else { return }
        send(type: "group_call_leave", data: ["call_id": cid])
        endLocally()
    }

    /// End the group call for everyone (creator only)
    public func endGroupCall() {
        guard let cid = callId else { return }
        send(type: "group_call_end", data: ["call_id": cid])
        endLocally()
    }

    /// Decline a ringing invite (spec 2.6): the server removes us from
    /// `Invited` and dismisses the ring on our other devices.
    public func declineGroupCall(callId: String) {
        send(type: "group_call_decline", data: ["call_id": callId])
    }

    /// `group_call_media_join` (spec 2.2): ask for the Janus room hand-out.
    /// The answer is `group_call_media_ready` or `group_call_media_unavailable`.
    public func requestMediaJoin(callId: String) {
        send(type: "group_call_media_join", data: ["call_id": callId])
    }

    /// `group_call_media_rejoin` (spec 2.5): like a media join, plus the hint
    /// that the current node / connection failed; the server re-checks health
    /// and may move the room. `reason` is a short code, never free text.
    public func requestMediaRejoin(callId: String, reason: String) {
        send(type: "group_call_media_rejoin", data: ["call_id": callId, "reason": String(reason.prefix(24))])
    }

    /// Tier-1: group-call BROADCAST reaction (Template B, mirrors
    /// `group_typing`'s two-phase lock-then-network send). No-op outside an
    /// active call. Server does not
    /// validate `emoji` — the fixed 6-emoji set is a CLIENT UI constraint
    /// only (see `onGroupCallReactionReceived`'s kdoc).
    public func sendGroupCallReaction(emoji: String) {
        guard let cid = callId else { return }
        send(type: "group_call_reaction", data: [
            "call_id": cid,
            "emoji": emoji
        ])
    }

    /// Tier-1: group-call BROADCAST raise/lower-hand — explicit boolean
    /// toggle, NOT a continuous-activity ping (no auto-expiry timer, unlike
    /// `group_typing`). Idempotent resend is safe.
    public func sendGroupCallRaiseHand(raised: Bool) {
        guard let cid = callId else { return }
        send(type: "group_call_raise_hand", data: [
            "call_id": cid,
            "raised": raised
        ])
    }

    /// Tier-1: group-call TARGETED mute-request (Template A, mirrors
    /// `group_call_signal` verbatim). FLAT, non-admin-gated by design: the
    /// server does zero role/permission check beyond both parties being
    /// current participants — any participant can request any other mute,
    /// matching standard industry behavior for this feature (no moderator
    /// role in group calls).
    public func sendGroupCallMuteRequest(targetId: String) {
        guard let cid = callId else { return }
        send(type: "group_call_mute_request", data: [
            "call_id": cid,
            "target_id": targetId
        ])
    }

    /// Idempotent form of `toggleMute`: sets the roster mute flag of our own entry and
    /// returns it. A mute the user did not tap (a peer's mute request, CallKit) must
    /// not flip the badge back the next time the button is used.
    @discardableResult
    public func setLocalMuted(_ muted: Bool) -> Bool {
        lock.lock()
        guard let idx = _participants.firstIndex(where: { $0.id == selfUserId }) else {
            lock.unlock()
            return muted
        }
        let changed = _participants[idx].isMuted != muted
        _participants[idx].isMuted = muted
        let list = _participants
        lock.unlock()
        if changed { onParticipantsChanged?(list) }
        return muted
    }

    /// Toggle local mute state
    public func toggleMute() -> Bool {
        lock.lock()
        if let idx = _participants.firstIndex(where: { $0.id == selfUserId }) {
            _participants[idx].isMuted.toggle()
            let muted = _participants[idx].isMuted
            let list = _participants
            lock.unlock()
            onParticipantsChanged?(list)
            return muted
        }
        lock.unlock()
        return false
    }

    // MARK: - WebSocket Handlers
    // Group calls v2 (spec section 2): the server speaks `group_call_invite`,
    // `group_call_update`, `group_call_ended`, `group_call_media_ready`,
    // `group_call_media_unavailable`, `group_call_media_moved` and the tier-1
    // `*_recv` messages below; those are the ONLY handlers registered. The media
    // relay (`group_call_forward` / `group_call_frame`) and the LiveKit token
    // messages no longer exist.

    private func registerHandlers() {
        // W-GRPRING - `group_call_invite` wire: {call_id, creator_id,
        // call_type, group_id, group_name, promoted_from_call_id}. The invite
        // is a RING, not a join: this handler never touches `_state` /
        // `_callId`. The app layer rings, and only `GroupCallController.join`
        // (on accept) moves us into the call.
        ws.registerHandler(type: "group_call_invite") { [weak self] _, data in
            guard let self = self,
                  let callId = data["call_id"] as? String,
                  let creatorId = data["creator_id"] as? String else { return }
            self.onIncomingInvite?(IncomingGroupInvite(
                callId: callId,
                creatorId: creatorId,
                // The server ships only UUIDs - resolve the creator to a human
                // name via the local rubrica, same as the participant list.
                creatorName: self.nameResolver(creatorId),
                callType: (data["call_type"] as? String) ?? "audio",
                groupId: (data["group_id"] as? String) ?? "",
                groupName: (data["group_name"] as? String) ?? "",
                promotedFromCallId: (data["promoted_from_call_id"] as? String) ?? ""
            ))
        }

        // Sent on every roster change and when the room appears. Wire (spec
        // 2.1): {call_id, participants, sender_key_epoch, media?}.
        ws.registerHandler(type: "group_call_update") { [weak self] _, data in
            self?.handleGroupCallUpdate(data: data)
        }

        // Wire: {call_id, reason?} - "ended" | "ring_timeout" | "declined".
        // For the active call this ends it; for any other call id it is a ring
        // we never joined going away (the caller dismisses it).
        ws.registerHandler(type: "group_call_ended") { [weak self] _, data in
            self?.handleGroupCallEnded(data: data)
        }
        // Spec 2.3. Only accepted for the call we are in.
        ws.registerHandler(type: "group_call_media_ready") { [weak self] _, data in
            self?.handleMediaReady(data: data)
        }
        // Spec 2.4. There is NO relay fallback: the controller shows an error.
        ws.registerHandler(type: "group_call_media_unavailable") { [weak self] _, data in
            self?.handleMediaUnavailable(data: data)
        }
        // Spec 2.5: {call_id, node_id}.
        ws.registerHandler(type: "group_call_media_moved") { [weak self] _, data in
            self?.handleMediaMoved(data: data)
        }

        // ─── Tier-1 call features (2026-07-16 wire contract) ───────────

        // call_reaction_recv — 1:1 TARGETED. `call_id` here is the 1:1
        // call's own id (see `onCallReactionReceived`'s kdoc for why this
        // 1:1 handler lives on this manager). Wire: {call_id, sender_id, emoji}.
        ws.registerHandler(type: "call_reaction_recv") { [weak self] _, data in
            guard let self = self,
                  let cid = data["call_id"] as? String,
                  let senderId = data["sender_id"] as? String,
                  let emoji = data["emoji"] as? String else { return }
            self.onCallReactionReceived?(cid, senderId, emoji)
        }
        // group_call_reaction_recv — group BROADCAST. Wire: {call_id, sender_id, emoji}.
        ws.registerHandler(type: "group_call_reaction_recv") { [weak self] _, data in
            guard let self = self,
                  let cid = data["call_id"] as? String,
                  let senderId = data["sender_id"] as? String,
                  let emoji = data["emoji"] as? String else { return }
            self.onGroupCallReactionReceived?(cid, senderId, emoji)
        }
        // group_call_raise_hand_recv — group BROADCAST. Wire: {call_id, sender_id, raised}.
        ws.registerHandler(type: "group_call_raise_hand_recv") { [weak self] _, data in
            guard let self = self,
                  let cid = data["call_id"] as? String,
                  let senderId = data["sender_id"] as? String,
                  let raised = data["raised"] as? Bool else { return }
            self.onGroupCallRaiseHandReceived?(cid, senderId, raised)
        }
        // group_call_mute_request_recv — group TARGETED, no target_id on the
        // _recv envelope (recipient knows they're the target by virtue of
        // receiving it). Wire: {call_id, sender_id}.
        ws.registerHandler(type: "group_call_mute_request_recv") { [weak self] _, data in
            guard let self = self,
                  let cid = data["call_id"] as? String,
                  let senderId = data["sender_id"] as? String else { return }
            self.onGroupCallMuteRequestReceived?(cid, senderId)
        }
    }

    func handleGroupCallEnded(data: [String: Any]) {
        let endedId = data["call_id"] as? String ?? ""
        let reason = (data["reason"] as? String) ?? "ended"
        if let active = callId, endedId.isEmpty || endedId == active {
            endLocally()
            onActiveCallEnded?(active, reason)
        } else if !endedId.isEmpty {
            onRingEnded?(endedId, reason)
        }
    }

    func handleMediaReady(data: [String: Any]) {
        guard let ready = GroupCallWire.MediaReady.parse(data) else {
            print("[BCryptoGroupCallManager] group_call_media_ready UNPARSEABLE (refused)")
            return
        }
        guard ready.callId == callId else { return }
        onMediaReady?(ready)
    }

    func handleMediaUnavailable(data: [String: Any]) {
        guard let cid = data["call_id"] as? String, cid == callId else { return }
        onMediaUnavailable?(cid, GroupCallWire.UnavailableReason(wire: (data["reason"] as? String) ?? ""))
    }

    func handleMediaMoved(data: [String: Any]) {
        guard let cid = data["call_id"] as? String, cid == callId else { return }
        onMediaMoved?(cid, (data["node_id"] as? String) ?? "")
    }

    /// Applies a `group_call_update` (spec 2.1): the roster (tiles), the epoch
    /// and, once the room exists, the node and the pseudonym map. Fires
    /// `onGroupUpdate` for the E2EE state machine and the media layer.
    ///
    /// W-GRPUPDATEDIAG: every branch leaves a line, so a join whose roster
    /// never arrives can be told apart from one that arrived and was refused.
    func handleGroupCallUpdate(data: [String: Any]) {
        guard let update = GroupCallWire.Update.parse(data) else {
            let hasCallId = data["call_id"] != nil
            let hasParticipants = data["participants"] != nil
            let hasEpoch = data["sender_key_epoch"] != nil
            print("[BCryptoGroupCallManager] group_call_update UNPARSEABLE hasCallId=\(hasCallId) hasParticipants=\(hasParticipants) hasEpoch=\(hasEpoch)")
            return
        }
        print("[BCryptoGroupCallManager] group_call_update RECEIVED call=\(update.callId.prefix(8)) participants=\(update.participants.count) epoch=\(update.epoch)")
        lock.lock()
        // A stale update for another call (a previous call's tail) is dropped.
        if let active = _callId, active != update.callId {
            lock.unlock()
            return
        }
        let previous = _participants
        _participants = update.participants.map { uid in
            if let existing = previous.first(where: { $0.id == uid }) { return existing }
            // Server only ships UUIDs - resolve to a human name client-side
            // via the local rubrica, falling back to a short id.
            return Participant(id: uid, displayName: nameResolver(uid))
        }
        _senderKeyEpoch = Int64(update.epoch)
        _state = .active
        let list = _participants
        lock.unlock()
        onStateChanged?(.active)
        onParticipantsChanged?(list)
        onGroupUpdate?(update)
    }

    /// W-GRPRING - fired on an inbound `group_call_invite`. The app layer
    /// RINGS (accept/reject surface); it must NOT join here. Accept ->
    /// `GroupCallController.join(callId:)`; reject -> `declineGroupCall`.
    public var onIncomingInvite: ((IncomingGroupInvite) -> Void)?

    /// Marks a participant as speaking (or not) from the receiver-side audio
    /// level the controller computes. Replaces the old WS-frame heuristic.
    public func setSpeaking(_ speakingIds: Set<String>) {
        lock.lock()
        var changed = false
        for idx in _participants.indices {
            let speaking = speakingIds.contains(_participants[idx].id)
            if _participants[idx].isSpeaking != speaking {
                _participants[idx].isSpeaking = speaking
                changed = true
            }
        }
        let list = _participants
        lock.unlock()
        if changed { onParticipantsChanged?(list) }
    }

    private func endLocally() {
        lock.lock()
        _state = .ended
        _participants.removeAll()
        _senderKeyEpoch = 1
        _callId = nil
        lock.unlock()
        onStateChanged?(.ended)
        onParticipantsChanged?([])
        // Reset to idle after 1s
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.lock.lock()
            self?._state = .idle
            self?.lock.unlock()
            self?.onStateChanged?(.idle)
        }
    }
}

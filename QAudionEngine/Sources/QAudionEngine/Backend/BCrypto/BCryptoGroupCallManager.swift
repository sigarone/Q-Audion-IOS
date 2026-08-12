import Foundation
import Combine

/// Manages group call sessions using SFU (Selective Forwarding Unit) model.
/// Each participant sends audio once → server forwards to all other participants.
/// Max 8 participants per call. PQC encryption maintained per-pair.
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
        /// W-RAWKEY256 (2026-07-20) — whether this member's build advertised
        /// `supports_raw_key_aes256` on its own create/join (server's
        /// `GroupCall.RawKeyCapable` map, mirrors `SenderKeysCapable` byte-
        /// for-byte). Defaults `true` so every pre-existing call site that
        /// constructs a bare `Participant(id:displayName:)` (previews, the
        /// local self-seed in `createGroupCall`, an SFU-only ghost tile in
        /// `GroupCallViewModel.mergeSfuOnlyParticipants`) stays silent by
        /// default rather than spuriously flagging someone this manager has
        /// no real wire signal for yet — only `handleGroupCallUpdate` below
        /// ever sets this to `false`, from the real server-canonical
        /// `raw_key_capable` roster.
        public var isRawKeyCapable: Bool = true
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
    /// W-GRPSENDERKEY — subset of `_participants` that advertised
    /// `supports_group_sender_keys` on create/join. Mirrors the server's
    /// `GroupCall.SenderKeysCapable` map (main.go).
    private var _senderKeysCapable: Set<String> = []
    /// W-RAWKEY256 — subset of `_participants` that advertised
    /// `supports_raw_key_aes256` on create/join. Mirrors the server's
    /// `GroupCall.RawKeyCapable` map (main.go), byte-for-byte parallel to
    /// `_senderKeysCapable` above. PASS-THROUGH signal only — this manager
    /// never touches actual key material; it exists so the UI layer can
    /// warn about a version-skew pair (legacy AES-128-from-base64(SK_0) vs
    /// current AES-256-from-raw-SK_0 key derivation) instead of the two
    /// builds silently failing to decrypt each other's SFU media.
    private var _rawKeyCapable: Set<String> = []
    /// W-GRPREKEY — server-canonical epoch counter (`GroupCall.SenderKeyEpoch`),
    /// relayed on every `group_call_update`. Bumped by the server on a real
    /// membership departure; clients pre-set their local epoch to
    /// `senderKeyEpoch - 1` before rekeying so all survivors converge on the
    /// same value regardless of detection-order jitter (see GroupCallController).
    private var _senderKeyEpoch: Int64 = 1

    public var state: State { lock.lock(); defer { lock.unlock() }; return _state }
    public var callId: String? { lock.lock(); defer { lock.unlock() }; return _callId }
    public var participants: [Participant] { lock.lock(); defer { lock.unlock() }; return _participants }
    public var senderKeysCapable: Set<String> { lock.lock(); defer { lock.unlock() }; return _senderKeysCapable }
    /// W-RAWKEY256 — mirrors `senderKeysCapable` above, exact same shape.
    public var rawKeyCapable: Set<String> { lock.lock(); defer { lock.unlock() }; return _rawKeyCapable }
    public var senderKeyEpoch: Int64 { lock.lock(); defer { lock.unlock() }; return _senderKeyEpoch }

    /// Callback for state changes
    public var onStateChanged: ((State) -> Void)?
    /// Callback for participant list updates
    public var onParticipantsChanged: (([Participant]) -> Void)?
    /// Callback for incoming audio frames
    public var onAudioFrame: ((String, Data) -> Void)?  // (senderId, frameData)
    /// W-GRPSENDERKEY / W-GRPREKEY — fires on every `group_call_update` with
    /// the full server-canonical tuple GroupCallController needs to bootstrap
    /// and rekey the per-sender ratchet. `onParticipantsChanged` above only
    /// carries the plain id list (kept for UI call sites); this callback is
    /// the crypto-facing one.
    public var onGroupUpdate: ((_ callId: String, _ participants: [String], _ senderKeysCapable: Set<String>, _ senderKeyEpoch: Int64) -> Void)?
    /// W-GRPLIVEKIT — fires on `group_call_sfu_token_recv`: the server
    /// minted a LiveKit access token for `callId`. Wire:
    /// {call_id, node_id, url, token}.
    public var onSfuTokenReceived: ((_ callId: String, _ nodeId: String, _ url: String, _ token: String) -> Void)?
    /// W-GRPLIVEKIT — fires on `group_call_sfu_unavailable`: the caller
    /// MUST soft-fall-back to the existing WS-relay group-call mesh path
    /// (never hard-fail). Wire: {call_id, reason}.
    public var onSfuUnavailable: ((_ callId: String, _ reason: String) -> Void)?

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

    // MARK: - Actions

    /// Create a new group call and invite recipients.
    ///
    /// Server contract — VERIFIED against the LIVE `cmd/bcrypto-lite/main.go`
    /// handler (`case "group_call_create"`, commit 9619df4, 2026-07-14). Wire:
    /// `{call_id, recipients, supports_group_sender_keys, call_type, group_id,
    /// group_name}`. The server does NOT read a `title` or `max_participants`
    /// field on this message (it caps every room at 8 unconditionally) —
    /// `title` is therefore local-display-only for the creator.
    ///
    /// W-GRPRING (audit gap E): `call_type` / `group_id` / `group_name` are
    /// relayed VERBATIM by the server onto every invitee's `group_call_invite`
    /// AND onto the APNs/FCM push that wakes an app-closed invitee. The fields
    /// are additive server-side (an omitting client yields empty strings), but
    /// omitting them leaves the receiver unable to render the right incoming
    /// screen — so every create site MUST populate the group context when one
    /// exists (GroupChatScreen), and `call_type` always.
    /// - Returns: the freshly-minted call id, so the caller (GroupCallController)
    ///   bootstraps its `GroupSession` under the SAME id actually sent to the
    ///   server — the previous version of this method generated its own id
    ///   internally while the controller generated a SEPARATE one for its
    ///   room-key derivation, silently diverging (never caught: zero UI
    ///   reachability meant this path never ran for real).
    @discardableResult
    public func createGroupCall(
        recipients: [String],
        title: String = "",
        callType: String = "audio",
        groupId: String = "",
        groupName: String = "",
        /// W-CALLPROMOTE — set when this call is a live promotion of a 1:1
        /// call this client was already on. Relayed verbatim by the server
        /// onto `group_call_invite` so THAT SAME peer's client can
        /// recognize the invite as a continuation of the call they're
        /// already on — purely informational, never used for join
        /// authorization (unchanged: still the server's Invited/Participants
        /// membership gate). Additive/optional on the wire, same posture as
        /// `groupId`/`groupName` above.
        promotedFromCallId: String = ""
    ) -> String? {
        guard state == .idle else { return nil }
        let newCallId = UUID().uuidString
        lock.lock()
        _state = .creating
        _callId = newCallId
        // Real userId, not a "self" placeholder — matches what the server
        // will echo back in the first `group_call_update` once anyone joins.
        _participants = [Participant(id: selfUserId, displayName: "Tu")]
        _senderKeysCapable = [selfUserId]
        _senderKeyEpoch = 1  // matches server's GroupCall.SenderKeyEpoch default
        lock.unlock()
        onStateChanged?(.creating)

        ws.send(type: "group_call_create", data: [
            "call_id": newCallId,
            "recipients": recipients,
            "supports_group_sender_keys": true,
            // W-RAWKEY256 (2026-07-20) — unconditional true, no negotiation:
            // this build always derives the SFU media key from the raw
            // 32-byte SK_0 (AES-256-GCM), never the legacy
            // UTF8(base64(SK_0))->AES-128-GCM path. Mirrors
            // `supports_group_sender_keys` exactly — server-contract field
            // name is `supports_raw_key_aes256` (`GroupCall.RawKeyCapable`).
            "supports_raw_key_aes256": true,
            "call_type": callType,
            "group_id": groupId,
            "group_name": groupName,
            "promoted_from_call_id": promotedFromCallId
        ])
        return newCallId
    }

    /// Join an existing group call. Always advertises sender-key support —
    /// every live client on this codebase now ships GroupSession — and,
    /// W-RAWKEY256, raw-key AES-256 support, for the same reason.
    public func joinGroupCall(callId: String) {
        lock.lock()
        _state = .creating
        _callId = callId
        lock.unlock()
        onStateChanged?(.creating)

        ws.send(type: "group_call_join", data: [
            "call_id": callId,
            "supports_group_sender_keys": true,
            "supports_raw_key_aes256": true
        ])
    }

    /// Leave the current group call
    public func leaveGroupCall() {
        guard let cid = callId else { return }
        ws.send(type: "group_call_leave", data: ["call_id": cid])
        endLocally()
    }

    /// End the group call for everyone (creator only)
    public func endGroupCall() {
        guard let cid = callId else { return }
        ws.send(type: "group_call_end", data: ["call_id": cid])
        endLocally()
    }

    /// Forward one encrypted audio frame — the server SFU relays it,
    /// broadcast-once, to every OTHER participant of `callId`. There is no
    /// per-recipient targeting on the wire (verified against the live
    /// `case "group_call_forward"` handler in `cmd/bcrypto-lite/main.go`:
    /// `{call_id, frame}` in, single relay to all non-sender participants
    /// out) — encryption must therefore be per-SENDER (one ciphertext every
    /// recipient can open), never per-recipient. `GroupCallController` seals
    /// with the caller's own `GroupSenderKey` chain before calling this.
    public func forwardAudioFrame(_ frameData: Data) {
        guard let cid = callId, state == .active else { return }
        ws.send(type: "group_call_forward", data: [
            "call_id": cid,
            "frame": frameData.base64EncodedString()
        ])
    }

    /// W-GRPLIVEKIT: request a LiveKit SFU access token for `callId`. Reply
    /// arrives asynchronously as either `group_call_sfu_token_recv`
    /// ([onSfuTokenReceived]) or `group_call_sfu_unavailable`
    /// ([onSfuUnavailable]) — correlated by `call_id` since the wire has no
    /// request/response id for this pair. Wire: {call_id}.
    public func requestSfuToken(callId: String) {
        ws.send(type: "group_call_sfu_token", data: ["call_id": callId])
    }

    /// Tier-1: group-call BROADCAST reaction (Template B, mirrors
    /// `group_typing`'s two-phase lock-then-network send). No-op outside an
    /// active call (mirrors `forwardAudioFrame`'s guard). Server does not
    /// validate `emoji` — the fixed 6-emoji set is a CLIENT UI constraint
    /// only (see `onGroupCallReactionReceived`'s kdoc).
    public func sendGroupCallReaction(emoji: String) {
        guard let cid = callId else { return }
        ws.send(type: "group_call_reaction", data: [
            "call_id": cid,
            "emoji": emoji
        ])
    }

    /// Tier-1: group-call BROADCAST raise/lower-hand — explicit boolean
    /// toggle, NOT a continuous-activity ping (no auto-expiry timer, unlike
    /// `group_typing`). Idempotent resend is safe.
    public func sendGroupCallRaiseHand(raised: Bool) {
        guard let cid = callId else { return }
        ws.send(type: "group_call_raise_hand", data: [
            "call_id": cid,
            "raised": raised
        ])
    }

    /// Tier-1: group-call TARGETED mute-request (Template A, mirrors
    /// `group_call_signal` verbatim). FLAT, non-admin-gated by design: the
    /// server does zero role/permission check beyond both parties being
    /// current participants — any participant can request any other mute,
    /// matching Signal's real behavior (no moderator role in Signal group
    /// calls).
    public func sendGroupCallMuteRequest(targetId: String) {
        guard let cid = callId else { return }
        ws.send(type: "group_call_mute_request", data: [
            "call_id": cid,
            "target_id": targetId
        ])
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
    // Message names + shapes VERIFIED against the LIVE
    // `cmd/bcrypto-lite/main.go` handlers (2026-07-13) — NOT the dead
    // `internal/signaling/messages.go` island (zero importers, unreachable
    // from main.go). The previous version of this file was built against
    // that dead protocol (`group_call_state`, `group_call_receive`,
    // `invite_user_ids`, per-target `forward{target_id,data}`) and its
    // "current vs legacy-alias" framing was backwards: the real server only
    // ever speaks `group_call_invite` / `group_call_update` / `group_call_frame`
    // / `group_call_ended`, so those are now the ONLY handlers registered.

    private func registerHandlers() {
        // W-GRPRING — `group_call_invite` wire (server commit 9619df4):
        // {call_id, creator_id, call_type, group_id, group_name}. The last
        // three are additive: a create sent by an older client leaves them
        // empty strings.
        //
        // This handler NO LONGER touches `_state`/`_callId`. The invite is a
        // RING, not a join: the app layer surfaces an incoming-group-call
        // screen and only `GroupCallController.join(callId:)` (on accept)
        // moves us into the call. Setting `_state = .creating` here was a
        // leftover of the silent auto-join: with a real accept/reject it
        // would leave the manager stuck in `.creating` forever whenever the
        // user rejects (nothing resets it), and the `state == .idle` guard in
        // `createGroupCall` would then refuse EVERY future group call.
        ws.registerHandler(type: "group_call_invite") { [weak self] _, data in
            guard let self = self,
                  let callId = data["call_id"] as? String,
                  let creatorId = data["creator_id"] as? String else { return }
            // NOTE: does NOT call joinGroupCall itself — GroupCallController
            // .join(callId:) is the single source of truth for both the WS
            // join AND the GroupSession crypto bootstrap (mirrors Android's
            // `GroupCallController.join`, which ALSO owns both). Calling
            // joinGroupCall here directly would send `group_call_join` while
            // leaving groupState/activeCallId unset, silently disabling E2E
            // decryption for every frame this device receives in the call.
            self.onIncomingInvite?(IncomingGroupInvite(
                callId: callId,
                creatorId: creatorId,
                // The server ships only UUIDs — resolve the creator to a human
                // name via the local rubrica, same as the participant list.
                creatorName: self.nameResolver(creatorId),
                callType: (data["call_type"] as? String) ?? "audio",
                groupId: (data["group_id"] as? String) ?? "",
                groupName: (data["group_name"] as? String) ?? "",
                promotedFromCallId: (data["promoted_from_call_id"] as? String) ?? ""
            ))
        }

        // Sent on both join and leave. Wire:
        // {call_id, participants, sender_keys_capable, sender_key_epoch,
        // raw_key_capable}. `raw_key_capable` (W-RAWKEY256, 2026-07-20) is
        // additive/parallel to `sender_keys_capable` — see
        // `Participant.isRawKeyCapable`'s kdoc.
        ws.registerHandler(type: "group_call_update") { [weak self] _, data in
            self?.handleGroupCallUpdate(data: data)
        }

        // Sent by the SFU relay for every forwarded frame. Wire:
        // {call_id, frame, sender}.
        ws.registerHandler(type: "group_call_frame") { [weak self] _, data in
            self?.handleGroupCallFrame(data: data)
        }

        // Wire: {call_id}.
        ws.registerHandler(type: "group_call_ended") { [weak self] _, _ in
            self?.endLocally()
        }

        // W-GRPLIVEKIT — SFU token round-trip. Wire: {call_id, node_id, url, token}.
        ws.registerHandler(type: "group_call_sfu_token_recv") { [weak self] _, data in
            guard let self = self,
                  let cid = data["call_id"] as? String,
                  let nodeId = data["node_id"] as? String,
                  let url = data["url"] as? String,
                  let token = data["token"] as? String else { return }
            self.onSfuTokenReceived?(cid, nodeId, url, token)
        }
        // Wire: {call_id, reason}. MUST soft-fall-back, never hard-fail.
        ws.registerHandler(type: "group_call_sfu_unavailable") { [weak self] _, data in
            guard let self = self, let cid = data["call_id"] as? String else { return }
            let reason = data["reason"] as? String ?? "unknown"
            self.onSfuUnavailable?(cid, reason)
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

    /// W-GRPSENDERKEY / W-GRPREKEY — fires the crypto-facing
    /// [onGroupUpdate] callback in addition to the plain-id
    /// [onParticipantsChanged] one so GroupCallController can bootstrap new
    /// members into the sender-key roster and rekey on departure using the
    /// server-canonical epoch.
    /// W-GRPUPDATEDIAG (2026-08-03): this handler had ZERO logging — a
    /// join that never surfaced a roster looked IDENTICAL to
    /// `group_call_update` never arriving at all, whether the real cause
    /// was the server never delivering it (the W-GRPSTALEWS class of bug
    /// documented server-side, cmd/bcrypto-lite/main.go's
    /// `group_call_join` handler) or it arriving and failing this
    /// function's own guard. Confirmed live: a join whose server log
    /// showed `group_call_join ... stale_ws_routed_cross_node=0` (i.e.
    /// the server believed delivery succeeded) still left the client
    /// stuck at 0 participants until `armGroupCallJoinTimeout`'s 20s
    /// safety net fired — with no client-side trace to say which side
    /// actually failed. These two lines exist purely to answer that
    /// question the next time it happens.
    private func handleGroupCallUpdate(data: [String: Any]) {
        guard let cid = data["call_id"] as? String,
              let participantIds = data["participants"] as? [String] else {
            let hasCallId = data["call_id"] != nil
            let hasParticipants = data["participants"] != nil
            print("[BCryptoGroupCallManager] group_call_update UNPARSEABLE hasCallId=\(hasCallId) hasParticipants=\(hasParticipants)")
            return
        }
        print("[BCryptoGroupCallManager] group_call_update RECEIVED call=\(cid.prefix(8)) participants=\(participantIds.count)")
        let capableIds = data["sender_keys_capable"] as? [String] ?? []
        let epoch = (data["sender_key_epoch"] as? NSNumber)?.int64Value ?? 1
        // W-RAWKEY256 (2026-07-20) — same `?? []` fallback idiom as
        // `sender_keys_capable` above (mirrors it exactly): server always
        // ships this field on every `group_call_update` broadcast, so an
        // absent key only happens against a stale/never-updated server,
        // same failure mode `sender_keys_capable` already accepts.
        let rawKeyCapableIds = data["raw_key_capable"] as? [String] ?? []
        let rawKeyCapableSet = Set(rawKeyCapableIds)
        lock.lock()
        _participants = participantIds.map { uid in
            let isRawKeyCapable = rawKeyCapableSet.contains(uid)
            if var existing = _participants.first(where: { $0.id == uid }) {
                existing.isRawKeyCapable = isRawKeyCapable
                return existing
            }
            // Server only ships UUIDs — resolve to a human name client-side
            // via the local rubrica, falling back to the bare UUID.
            return Participant(id: uid, displayName: nameResolver(uid), isRawKeyCapable: isRawKeyCapable)
        }
        _senderKeysCapable = Set(capableIds)
        _rawKeyCapable = rawKeyCapableSet
        _senderKeyEpoch = epoch
        _state = .active
        let list = _participants
        let capableSnapshot = _senderKeysCapable
        lock.unlock()
        onStateChanged?(.active)
        onParticipantsChanged?(list)
        onGroupUpdate?(cid, participantIds, capableSnapshot, epoch)
    }

    /// W-GRPRING — fired on an inbound `group_call_invite`. The app layer
    /// RINGS (accept/reject surface); it must NOT join here. Accept →
    /// `GroupCallController.join(callId:)`; reject → do nothing (there is no
    /// `group_call_decline` wire type: the room stays open for the others).
    public var onIncomingInvite: ((IncomingGroupInvite) -> Void)?

    /// Apply an inbound SFU frame to participant speaking state and surface
    /// the encrypted audio bytes to the engine. Wire: {call_id, frame, sender}.
    private func handleGroupCallFrame(data: [String: Any]) {
        guard let senderId = data["sender"] as? String,
              let frameB64 = data["frame"] as? String,
              let frameData = Data(base64Encoded: frameB64)
        else { return }
        // Mark sender as speaking
        lock.lock()
        if let idx = _participants.firstIndex(where: { $0.id == senderId }) {
            _participants[idx].isSpeaking = true
            // Reset speaking after 500ms
            let list = _participants
            lock.unlock()
            onParticipantsChanged?(list)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                self.lock.lock()
                if let idx = self._participants.firstIndex(where: { $0.id == senderId }) {
                    self._participants[idx].isSpeaking = false
                }
                self.lock.unlock()
            }
        } else {
            lock.unlock()
        }
        onAudioFrame?(senderId, frameData)
    }

    private func endLocally() {
        lock.lock()
        _state = .ended
        _participants.removeAll()
        _senderKeysCapable.removeAll()
        _rawKeyCapable.removeAll()
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

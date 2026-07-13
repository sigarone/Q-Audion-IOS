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
            self.nameResolver = { uid in
                let stored = ContactsStore().load()
                if let match = stored.first(where: { $0.userId == uid }),
                   !match.displayName.isEmpty {
                    return match.displayName
                }
                return uid
            }
        }
        registerHandlers()
    }

    // MARK: - Actions

    /// Create a new group call and invite recipients.
    ///
    /// Server contract — VERIFIED against the LIVE `cmd/bcrypto-lite/main.go`
    /// handler (2026-07-13), not the dead `internal/signaling/messages.go`
    /// island. Wire: `{call_id, recipients, supports_group_sender_keys}`.
    /// The server does NOT read a `title` or `max_participants` field on
    /// this message (it caps every room at 8 unconditionally) — `title` is
    /// therefore local-display-only for the creator, never relayed to
    /// invitees (their `group_call_invite` carries only `call_id`+`creator_id`).
    /// - Returns: the freshly-minted call id, so the caller (GroupCallController)
    ///   bootstraps its `GroupSession` under the SAME id actually sent to the
    ///   server — the previous version of this method generated its own id
    ///   internally while the controller generated a SEPARATE one for its
    ///   room-key derivation, silently diverging (never caught: zero UI
    ///   reachability meant this path never ran for real).
    @discardableResult
    public func createGroupCall(
        recipients: [String],
        title: String = ""
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
            "supports_group_sender_keys": true
        ])
        return newCallId
    }

    /// Join an existing group call. Always advertises sender-key support —
    /// every live client on this codebase now ships GroupSession.
    public func joinGroupCall(callId: String) {
        lock.lock()
        _state = .creating
        _callId = callId
        lock.unlock()
        onStateChanged?(.creating)

        ws.send(type: "group_call_join", data: [
            "call_id": callId,
            "supports_group_sender_keys": true
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
        // GroupCallInviteData wire: {call_id, creator_id}. Auto-join, same
        // MVP behaviour as Android's MainActivity (no accept/reject sheet
        // yet — the invite silently navigates straight to the call).
        ws.registerHandler(type: "group_call_invite") { [weak self] _, data in
            guard let self = self,
                  let callId = data["call_id"] as? String,
                  let creatorId = data["creator_id"] as? String else { return }
            self.lock.lock()
            self._callId = callId
            self._state = .creating
            self.lock.unlock()
            self.onStateChanged?(.creating)
            // NOTE: does NOT call joinGroupCall itself (unlike the previous
            // version of this file) — GroupCallController.join(callId:) is
            // the single source of truth for both the WS join AND the
            // GroupSession crypto bootstrap (mirrors Android's
            // `GroupCallController.join`, which ALSO owns both). Calling
            // joinGroupCall here directly would send `group_call_join` while
            // leaving groupState/activeCallId unset, silently disabling E2E
            // decryption for every frame this device receives in the call.
            self.onIncomingInvite?(callId, creatorId)
        }

        // Sent on both join and leave. Wire:
        // {call_id, participants, sender_keys_capable, sender_key_epoch}.
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
    }

    /// W-GRPSENDERKEY / W-GRPREKEY — fires the crypto-facing
    /// [onGroupUpdate] callback in addition to the plain-id
    /// [onParticipantsChanged] one so GroupCallController can bootstrap new
    /// members into the sender-key roster and rekey on departure using the
    /// server-canonical epoch.
    private func handleGroupCallUpdate(data: [String: Any]) {
        guard let cid = data["call_id"] as? String,
              let participantIds = data["participants"] as? [String] else { return }
        let capableIds = data["sender_keys_capable"] as? [String] ?? []
        let epoch = (data["sender_key_epoch"] as? NSNumber)?.int64Value ?? 1
        lock.lock()
        _participants = participantIds.map { uid in
            if let existing = _participants.first(where: { $0.id == uid }) {
                return existing
            }
            // Server only ships UUIDs — resolve to a human name client-side
            // via the local rubrica, falling back to the bare UUID.
            return Participant(id: uid, displayName: nameResolver(uid))
        }
        _senderKeysCapable = Set(capableIds)
        _senderKeyEpoch = epoch
        _state = .active
        let list = _participants
        let capableSnapshot = _senderKeysCapable
        lock.unlock()
        onStateChanged?(.active)
        onParticipantsChanged?(list)
        onGroupUpdate?(cid, participantIds, capableSnapshot, epoch)
    }

    /// Callback fired on an inbound `group_call_invite`, BEFORE the
    /// auto-join fires — lets the app layer navigate to the call screen
    /// (mirroring Android MainActivity's `GroupCallInvite` → `navigate`).
    public var onIncomingInvite: ((_ callId: String, _ creatorId: String) -> Void)?

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

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

    public var state: State { lock.lock(); defer { lock.unlock() }; return _state }
    public var callId: String? { lock.lock(); defer { lock.unlock() }; return _callId }
    public var participants: [Participant] { lock.lock(); defer { lock.unlock() }; return _participants }

    /// Callback for state changes
    public var onStateChanged: ((State) -> Void)?
    /// Callback for participant list updates
    public var onParticipantsChanged: (([Participant]) -> Void)?
    /// Callback for incoming audio frames
    public var onAudioFrame: ((String, Data) -> Void)?  // (senderId, frameData)

    // MARK: - Dependencies

    private let ws: BCryptoWebSocketClient

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
        nameResolver: ((String) -> String)? = nil
    ) {
        self.ws = ws
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
    /// Server contract — see bcrypto-server internal/signaling/messages.go
    /// `GroupCallCreateData { title, invite_user_ids, max_participants? }`.
    /// `title` is shown in the invite payload; `maxParticipants` is optional
    /// (server caps to 8 when omitted).
    public func createGroupCall(
        recipients: [String],
        title: String = "",
        maxParticipants: Int? = nil
    ) {
        guard state == .idle else { return }
        let newCallId = UUID().uuidString
        lock.lock()
        _state = .creating
        _callId = newCallId
        _participants = [Participant(id: "self", displayName: "Tu")]
        lock.unlock()
        onStateChanged?(.creating)

        var payload: [String: Any] = [
            "call_id": newCallId,
            "title": title,
            "invite_user_ids": recipients
        ]
        if let maxP = maxParticipants {
            payload["max_participants"] = maxP
        }
        ws.send(type: "group_call_create", data: payload)
    }

    /// Join an existing group call
    public func joinGroupCall(callId: String) {
        lock.lock()
        _state = .creating
        _callId = callId
        lock.unlock()
        onStateChanged?(.creating)

        ws.send(type: "group_call_join", data: ["call_id": callId])
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

    /// Forward an encrypted audio frame to a specific participant via server SFU.
    ///
    /// Server contract — see bcrypto-server `GroupCallForwardData
    /// { call_id, target_id, data }`. Pairwise PQC means one envelope per
    /// recipient — the caller is expected to encrypt the frame separately for
    /// each peer and call this method once per peer.
    public func forwardAudioFrame(_ frameData: Data, to targetId: String) {
        guard let cid = callId, state == .active else { return }
        ws.send(type: "group_call_forward", data: [
            "call_id": cid,
            "target_id": targetId,
            "data": frameData.base64EncodedString()
        ])
    }

    /// Convenience fan-out: forward the same frame blob to every non-self
    /// participant. NOTE: pairwise PQC requires per-peer ciphertexts; this
    /// helper is only valid when the caller has already produced a single
    /// session-keyed frame. Prefer the per-target overload above.
    public func forwardAudioFrame(_ frameData: Data) {
        guard state == .active else { return }
        let peers: [String] = {
            lock.lock(); defer { lock.unlock() }
            return _participants.map(\.id).filter { $0 != "self" }
        }()
        for pid in peers {
            forwardAudioFrame(frameData, to: pid)
        }
    }

    /// Toggle local mute state
    public func toggleMute() -> Bool {
        lock.lock()
        if let idx = _participants.firstIndex(where: { $0.id == "self" }) {
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
    // Message names mirror bcrypto-server internal/signaling/messages.go:
    //   group_call_invite  → InviteUserIDs notified
    //   group_call_state   → room state update with event = created|joined|left|ended
    //   group_call_receive → SFU-forwarded opaque PQC frame
    // Old iOS names (group_call_update, group_call_frame, group_call_ended) are
    // kept as backward-compat aliases until the legacy server bake completes.

    private func registerHandlers() {
        ws.registerHandler(type: "group_call_invite") { [weak self] _, data in
            guard let self = self,
                  let callId = data["call_id"] as? String else { return }
            // Server schema: GroupCallInviteData { call_id, inviter_id, title }.
            // Older builds emitted `creator_id` — accept either, but only as a
            // sanity check; the value isn't used downstream yet.
            guard ((data["inviter_id"] as? String) ?? (data["creator_id"] as? String)) != nil else { return }
            // Auto-join for now (UI can show accept/reject later)
            self.lock.lock()
            self._callId = callId
            self._state = .creating
            self.lock.unlock()
            self.onStateChanged?(.creating)
            self.joinGroupCall(callId: callId)
        }

        // Server emits `group_call_state` for created/joined/left/ended events.
        // GroupCallStateData = { call_id, participants, event, user_id, title? }.
        ws.registerHandler(type: "group_call_state") { [weak self] _, data in
            self?.handleGroupCallState(data: data)
        }

        // Backward-compat alias — older server builds emitted `group_call_update`
        // for the same payload as `group_call_state{event:"joined"}`.
        ws.registerHandler(type: "group_call_update") { [weak self] _, data in
            self?.handleGroupCallState(data: data)
        }

        // Server emits `group_call_receive` for SFU-forwarded opaque frames.
        // GroupCallReceiveData = { call_id, sender_id, data }.
        ws.registerHandler(type: "group_call_receive") { [weak self] _, data in
            self?.handleGroupCallReceive(data: data)
        }

        // Backward-compat alias — `group_call_frame` was the older name.
        ws.registerHandler(type: "group_call_frame") { [weak self] _, data in
            self?.handleGroupCallReceive(data: data)
        }

        // Backward-compat alias — server now sends ended via
        // `group_call_state{event:"ended"}`. Keep the old handler as a fallback
        // in case a legacy server build is on the wire.
        ws.registerHandler(type: "group_call_ended") { [weak self] _, _ in
            self?.endLocally()
        }
    }

    /// Apply a `group_call_state` payload to the local participant list and
    /// state machine. Dispatches on `event` (created / joined / left / ended).
    private func handleGroupCallState(data: [String: Any]) {
        let event = (data["event"] as? String) ?? "joined"
        if event == "ended" {
            endLocally()
            return
        }

        guard let participantIds = data["participants"] as? [String] else { return }
        lock.lock()
        _participants = participantIds.map { uid in
            if let existing = _participants.first(where: { $0.id == uid }) {
                return existing
            }
            // Server only ships UUIDs for group-call participants —
            // resolve them client-side via the local rubrica
            // (`nameResolver`, defaulting to ContactsStore lookup).
            // Falls back to the bare UUID if not in the address book.
            return Participant(id: uid, displayName: nameResolver(uid))
        }
        // created/joined/left all imply the room is active for us.
        _state = .active
        let list = _participants
        lock.unlock()
        onStateChanged?(.active)
        onParticipantsChanged?(list)
    }

    /// Apply an inbound SFU frame to participant speaking state and surface
    /// the encrypted audio bytes to the engine. Accepts both `sender_id`
    /// (current server) and the legacy `sender` key. Frame bytes live under
    /// `data` (current) or `frame` (legacy).
    private func handleGroupCallReceive(data: [String: Any]) {
        guard let senderId = (data["sender_id"] as? String) ?? (data["sender"] as? String),
              let frameB64 = (data["data"] as? String) ?? (data["frame"] as? String),
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

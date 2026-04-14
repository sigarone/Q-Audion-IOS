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

    public init(ws: BCryptoWebSocketClient) {
        self.ws = ws
        registerHandlers()
    }

    // MARK: - Actions

    /// Create a new group call and invite recipients
    public func createGroupCall(recipients: [String]) {
        guard state == .idle else { return }
        let newCallId = UUID().uuidString
        lock.lock()
        _state = .creating
        _callId = newCallId
        _participants = [Participant(id: "self", displayName: "Tu")]
        lock.unlock()
        onStateChanged?(.creating)

        ws.send(type: "group_call_create", data: [
            "call_id": newCallId,
            "recipients": recipients
        ])
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

    /// Forward an encrypted audio frame to all participants via server SFU
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

    private func registerHandlers() {
        ws.registerHandler(type: "group_call_invite") { [weak self] _, data in
            guard let self = self,
                  let callId = data["call_id"] as? String,
                  let creatorId = data["creator_id"] as? String else { return }
            // Auto-join for now (UI can show accept/reject later)
            self.lock.lock()
            self._callId = callId
            self._state = .creating
            self.lock.unlock()
            self.onStateChanged?(.creating)
            self.joinGroupCall(callId: callId)
        }

        ws.registerHandler(type: "group_call_update") { [weak self] _, data in
            guard let self = self,
                  let participantIds = data["participants"] as? [String] else { return }
            self.lock.lock()
            self._participants = participantIds.map { uid in
                if let existing = self._participants.first(where: { $0.id == uid }) {
                    return existing
                }
                return Participant(id: uid, displayName: String(uid.prefix(8)))
            }
            self._state = .active
            let list = self._participants
            self.lock.unlock()
            self.onStateChanged?(.active)
            self.onParticipantsChanged?(list)
        }

        ws.registerHandler(type: "group_call_frame") { [weak self] _, data in
            guard let self = self,
                  let senderId = data["sender"] as? String,
                  let frameB64 = data["frame"] as? String,
                  let frameData = Data(base64Encoded: frameB64) else { return }
            // Mark sender as speaking
            self.lock.lock()
            if let idx = self._participants.firstIndex(where: { $0.id == senderId }) {
                self._participants[idx].isSpeaking = true
                // Reset speaking after 500ms
                let list = self._participants
                self.lock.unlock()
                self.onParticipantsChanged?(list)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.lock.lock()
                    if let idx = self._participants.firstIndex(where: { $0.id == senderId }) {
                        self._participants[idx].isSpeaking = false
                    }
                    self.lock.unlock()
                }
            } else {
                self.lock.unlock()
            }
            self.onAudioFrame?(senderId, frameData)
        }

        ws.registerHandler(type: "group_call_ended") { [weak self] _, _ in
            self?.endLocally()
        }
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

import Foundation

/// Errors surfaced by the BCrypto calling adapter. Specialised so the UI
/// can render an Italian-localised message instead of dumping a system
/// `URLError` in the alert body.
public enum BCryptoCallingError: LocalizedError {
    /// The persistent signaling WebSocket could not be (re)established
    /// before the call setup deadline. iOS suspends `URLSessionWebSocketTask`
    /// silently in background; this fires when the foreground recovery
    /// path also failed (no network, server unreachable, JWT rejected).
    case wsUnavailable

    public var errorDescription: String? {
        switch self {
        case .wsUnavailable:
            return "Connessione al server persa. Verifica la rete e riprova."
        }
    }
}

/// Wire-format adapter between the high-level `CallingApi` protocol and the
/// `bcrypto-server` signaling envelopes (see `internal/signaling/messages.go`
/// `CallOfferData`, `CallAnswerData`, `CallICEData`, `CallHangupData`).
///
/// **HISTORY**: previous revisions sent camelCase field names
/// (`recipientId`, `sdp` only, no `call_id`/`call_type`/`reason`) which the
/// Go server rejected with `INVALID_DATA` because its struct tags require
/// `recipient_id` and a non-empty `call_id`. The mismatch was silent —
/// iOS got `error` envelopes back which the WS dispatcher logged but the
/// UI never surfaced. Calls from iOS to Android NEVER established.
public final class BCryptoCallingApiImpl: CallingApi {
    private let ws: BCryptoWebSocketClient
    private let rest: BCryptoRestClient
    /// Active call_id — generated on `sendCallOffer`, reused for the
    /// subsequent answer / ICE / hangup envelopes so the server's call
    /// state machine routes them to the right peer. Cleared on hangup.
    private var activeCallId: String?
    private let callIdLock = NSLock()
    /// Guard against sending call_answer more than once per call session.
    /// Reset alongside activeCallId in clearActiveCallId().
    private var _answerSent = false

    init(ws: BCryptoWebSocketClient, rest: BCryptoRestClient) { self.ws = ws; self.rest = rest }

    public func sendCallOffer(recipientId: String, sdp: String) async throws {
        try await sendCallOffer(
            recipientId: recipientId,
            sdp: sdp,
            capabilities: CallCapabilities.local,
            callerDisplay: nil
        )
    }

    /// Outbound `call_offer` advertising the SFrame capability tags AND
    /// (optionally) the caller-supplied display string used by the
    /// callee's CallKit caller-id.
    ///
    /// Mirrors Android `WsCommand.CallOffer.capabilities` (commit 540b79c0).
    /// The `capabilities` JSON key is OMITTED when the list is empty so
    /// older bcrypto-server builds that don't yet recognise the field
    /// stay happy; the agreement is a pure end-to-end concern (the
    /// server is a relay).
    ///
    /// `callerDisplay` (optional) is shipped as the `caller_display`
    /// JSON field. Pure digits — typically the user's locally-configured
    /// "standard phone number" (see `LocalCallerIdSettings`). When nil
    /// the field is omitted and the server resolves the callee-side
    /// display string to the caller's internal extension.
    public func sendCallOffer(
        recipientId: String,
        sdp: String,
        capabilities: [String],
        callerDisplay: String?,
        hasVideo: Bool
    ) async throws {
        // Pre-flight: iOS suspends URLSessionWebSocketTask silently when the
        // app backgrounds. If we hit `ws.send` with a dead task the envelope
        // is logged "DROPPED" and the engine falls into invalidState, leaving
        // the user with a sub-second CallKit flash and no error. Force a
        // reconnect (debounced) and wait up to 5s for `MsgAuthenticated`.
        let ready = await ws.ensureAuthenticated(timeoutSec: 5)
        if !ready {
            throw BCryptoCallingError.wsUnavailable
        }
        // Mint a fresh call_id and stash for the rest of the session.
        let cid = UUID().uuidString
        setActiveCallId(cid)
        let callType: String = hasVideo ? "video" : "audio"
        var data: [String: Any] = [
            "recipient_id": recipientId,
            "call_id":      cid,
            "sdp":          sdp,
            "call_type":    callType,
            "has_video":    hasVideo,
        ]
        if !capabilities.isEmpty { data["capabilities"] = capabilities }
        if let cd = callerDisplay, !cd.isEmpty {
            data["caller_display"] = cd
        }
        ws.send(type: "call_offer", data: data)
    }

    public func sendCallOffer(
        recipientId: String,
        sdp: String,
        capabilities: [String],
        callerDisplay: String?
    ) async throws {
        try await sendCallOffer(
            recipientId: recipientId,
            sdp: sdp,
            capabilities: capabilities,
            callerDisplay: callerDisplay,
            hasVideo: false
        )
    }

    public func sendCallAnswer(recipientId: String, sdp: String) async throws {
        try await sendCallAnswer(
            recipientId: recipientId,
            sdp: sdp,
            capabilities: CallCapabilities.local
        )
    }

    /// Outbound `call_answer` advertising the SFrame capability tags —
    /// see ``sendCallOffer(recipientId:sdp:capabilities:)`` for the
    /// wire format contract. Same omitempty rule.
    public func sendCallAnswer(
        recipientId: String,
        sdp: String,
        capabilities: [String]
    ) async throws {
        try await sendCallAnswer(
            recipientId: recipientId,
            sdp: sdp,
            capabilities: capabilities,
            hasVideo: false
        )
    }

    /// Outbound `call_answer` that echoes the video acceptance flag back
    /// to the caller. Android WsCodec.kt reads `has_video` from the
    /// answer envelope — sending `false` on a video call makes it mute
    /// remote video on its side even when the SDP carries a video track.
    public func sendCallAnswer(
        recipientId: String,
        sdp: String,
        capabilities: [String],
        hasVideo: Bool
    ) async throws {
        // Idempotency: drop duplicate answers for the same call session.
        // Can occur if the WebRTC onAnswerCreated callback fires twice or
        // if AppState logic races after receiving call_incoming twice.
        guard !checkAndMarkAnswerSent() else { return }
        let cid = currentCallId()
        var data: [String: Any] = [
            "recipient_id": recipientId,
            "call_id":      cid,
            "sdp":          sdp,
            "has_video":    hasVideo,
        ]
        if !capabilities.isEmpty { data["capabilities"] = capabilities }
        ws.send(type: "call_answer", data: data)
    }

    public func sendIceCandidate(recipientId: String, candidate: String) async throws {
        try await sendIceCandidate(
            recipientId: recipientId,
            candidate: candidate,
            sdpMid: nil,
            sdpMLineIndex: 0
        )
    }

    /// Override with real `sdp_mid` / `sdp_mline_index` from the WebRTC stack.
    /// Android WsCodec.kt uses `sdp_mid` to route the candidate to the correct
    /// m-line (audio vs video) — without this, video ICE silently breaks.
    public func sendIceCandidate(
        recipientId: String,
        candidate: String,
        sdpMid: String?,
        sdpMLineIndex: Int32
    ) async throws {
        let cid = currentCallId()
        var data: [String: Any] = [
            "call_id":         cid,
            "candidate":       candidate,
            "sdp_mline_index": sdpMLineIndex,
        ]
        data["sdp_mid"] = sdpMid ?? ""
        ws.send(type: "call_ice", data: data)
    }

    /// Tier-1 (2026-07-16 wire contract) — 1:1 call TARGETED reaction.
    /// Mirrors `sendIceCandidate`'s send path: rides the internally-tracked
    /// `currentCallId()` rather than an externally-passed callId (the call
    /// is already established by the time a reaction can be sent).
    /// `targetId` is the peer's userId; the server validates both sender
    /// and target are the two call parties (mirrors bcrypto-server's
    /// `group_call_signal` case) before relaying as `call_reaction_recv`.
    /// Wire: {call_id, target_id, emoji}.
    public func sendCallReaction(targetId: String, emoji: String) async throws {
        let cid = currentCallId()
        ws.send(type: "call_reaction", data: [
            "call_id":   cid,
            "target_id": targetId,
            "emoji":     emoji,
        ])
    }

    public func sendHangup(recipientId: String) async throws {
        let cid = currentCallId()
        // W419 — log so we can correlate with bcrypto.service journalctl.
        // The previous version had no log here, so when the Android peer
        // got "ghost call" the maintainer had no signal that iOS even
        // tried to send the hangup.
        print("[BCryptoCalling] sendHangup call_id=\(cid) recipientId=\(recipientId)")
        ws.send(
            type: "call_hangup",
            data: [
                "call_id":      cid,
                "reason":       "local_hangup",  // mirrors Android CallHangup.reason
                "recipient_id": recipientId,     // belt-and-braces routing fallback
            ]
        )
        // Clear after hangup so the next outgoing call starts fresh.
        clearActiveCallId()
    }

    public func sendOpaqueMessage(recipientId: String, data: Data) async throws {
        ws.sendOpaqueMessage(recipientId: recipientId, payload: data)
    }

    /// Override the protocol default to bypass the base64 wrap that
    /// `sendOpaqueMessage(payload: Data)` applies. Required for the
    /// Android JSON HandshakeBundle wire format. WIRE_SPEC.md §3.1.
    public func sendOpaqueMessageString(recipientId: String, payload: String) async throws {
        ws.sendOpaqueMessageString(recipientId: recipientId, payload: payload)
    }

    /// Originator-side `call_offer` with an EXTERNALLY-CHOSEN callId.
    /// Per OpenRouter glm-5.1 review 2026-05-06 P0 #1.
    public func sendCallOfferWithId(callId: String, recipientId: String, sdp: String) async throws {
        try await sendCallOfferWithId(
            callId: callId,
            recipientId: recipientId,
            sdp: sdp,
            capabilities: CallCapabilities.local,
            callerDisplay: nil,
            hasVideo: false
        )
    }

    /// Bridge — drops `hasVideo` (legacy callers). Forwards to the 6-param override.
    public func sendCallOfferWithId(
        callId: String,
        recipientId: String,
        sdp: String,
        capabilities: [String],
        callerDisplay: String?
    ) async throws {
        try await sendCallOfferWithId(
            callId: callId,
            recipientId: recipientId,
            sdp: sdp,
            capabilities: capabilities,
            callerDisplay: callerDisplay,
            hasVideo: false
        )
    }

    /// Originator-side `call_offer` with externally-chosen callId, SFrame
    /// capability tags, `caller_display` substitution, and the `has_video` /
    /// `call_type` fields. This is the single real implementation — all
    /// narrower overloads bridge here so the wire format is assembled once.
    public func sendCallOfferWithId(
        callId: String,
        recipientId: String,
        sdp: String,
        capabilities: [String],
        callerDisplay: String?,
        hasVideo: Bool
    ) async throws {
        // Same pre-flight gate as `sendCallOffer`.
        let ready = await ws.ensureAuthenticated(timeoutSec: 5)
        if !ready {
            throw BCryptoCallingError.wsUnavailable
        }
        setActiveCallId(callId)
        let callType: String = hasVideo ? "video" : "audio"
        var data: [String: Any] = [
            "recipient_id": recipientId,
            "call_id":      callId,
            "sdp":          sdp,
            "call_type":    callType,
            "has_video":    hasVideo,
        ]
        if !capabilities.isEmpty { data["capabilities"] = capabilities }
        if let cd = callerDisplay, !cd.isEmpty {
            data["caller_display"] = cd
        }
        ws.send(type: "call_offer", data: data)
    }

    /// Send a call_hangup explicitly bound to a specific callId,
    /// bypassing the lazy `currentCallId()` fallback. Used by the
    /// Android-originator cleanup path: when the opaque OFFER fails
    /// after the call_offer has already woken the peer, we must
    /// hangup against the SAME callId we just minted (not whatever
    /// activeCallId happens to be — could be a previous call's
    /// stale value).
    /// Per OpenRouter glm-5.1 review 2026-05-06 P0 #3.
    public func sendCallHangupForId(callId: String, recipientId: String) async throws {
        ws.send(
            type: "call_hangup",
            data: [
                "call_id":      callId,
                "reason":       "originator_offer_failed",
                "recipient_id": recipientId,   // belt-and-braces routing fallback
            ]
        )
    }

    // MARK: - Pre-negotiation (Android/Desktop interop)

    /// Acknowledge to the caller that this device received the call_offer and is
    /// initialising the PQC handshake. Pre-negotiation step 1.
    /// Server forwards this back to the caller verbatim — see bcrypto-server
    /// pre-negotiation flow in cmd/bcrypto-lite/main.go (call_processing case).
    public func sendCallProcessing(callId: String, callerId: String) async throws {
        ws.send(type: "call_processing", data: [
            "call_id":   callId,
            "caller_id": callerId,
        ])
    }

    /// Notify the caller that the responder finished the PQC OFFER deserialisation
    /// and is ready to ring. Pre-negotiation step 2 — caller can now show "Ringing".
    /// See bcrypto-server pre-negotiation flow.
    public func sendCallReady(callId: String, callerId: String) async throws {
        ws.send(type: "call_ready", data: [
            "call_id":   callId,
            "caller_id": callerId,
        ])
    }

    /// Tell the caller a real user explicitly accepted the call. Distinct
    /// from `call_answer` (network-readiness, may be automatic) — see
    /// WIRE_SPEC.md §3.5. Server stamps sender_id/recipient_id and relays,
    /// same envelope class as call_processing/call_ready above.
    public func sendCallAccepted(callId: String) async throws {
        ws.send(type: "call_accepted", data: [
            "call_id": callId,
        ])
    }

    /// W536 — initiator-side mid-call upgrade request. Ships the new
    /// SDP offer (with the freshly-added video m-section) so the peer
    /// can produce an answer that closes the renegotiation loop. Wire
    /// format byte-for-byte identical to desktop
    /// CallController.requestUpgradeToVideo + Android
    /// WsCommand.CallUpgradeRequest.
    public func sendCallUpgradeRequest(
        callId: String,
        recipientId: String,
        sdp: String,
        media: String = "camera"
    ) async throws {
        ws.send(type: "call_upgrade_request", data: [
            "call_id":      callId,
            "recipient_id": recipientId,
            "sdp":          sdp,
            "media":        media,
        ])
    }

    /// W536 — callee-side response to a `call_upgrade_request`. When
    /// `accepted == false`, the peer should leave the SDP empty and
    /// keep the audio-only PC. Mirrors desktop
    /// CallController.respondToUpgrade.
    public func sendCallUpgradeResponse(
        callId: String,
        recipientId: String,
        sdp: String,
        accepted: Bool
    ) async throws {
        ws.send(type: "call_upgrade_response", data: [
            "call_id":      callId,
            "recipient_id": recipientId,
            "sdp":          sdp,
            "accepted":     accepted,
        ])
    }

    /// WIRE_SPEC §8.7 (v1.1) — receiver→sender media readiness. Sent by
    /// the RECEIVER when its receiver-side video cryptor is BOTH keyed
    /// and bound to the negotiated video mid; the sender responds by
    /// forcing a local encoder IDR. `dir` is "recv" today; `keyEpoch`
    /// is 0 until rekey epochs ship. The server stamps `sender_id` and
    /// relays transparently (same class as call_upgrade_*).
    public func sendCallMediaReady(
        callId: String,
        recipientId: String,
        mid: String,
        keyEpoch: Int,
        dir: String
    ) async throws {
        ws.send(type: "call_media_ready", data: [
            "call_id":      callId,
            "recipient_id": recipientId,
            "mid":          mid,
            "key_epoch":    keyEpoch,
            "dir":          dir,
        ])
    }

    /// WIRE_SPEC §8.7 (v1.1) — receiver→sender explicit keyframe
    /// recovery (the E2EE frame-transform suppresses libwebrtc's native
    /// PLI, so decoder recovery requires this wire path). Rate-limited
    /// HERE to 1/s per the spec — callers may invoke it freely; excess
    /// requests inside the window are silently dropped.
    public func sendVideoKeyframeRequest(
        callId: String,
        recipientId: String
    ) async throws {
        guard checkKeyframeRequestRateLimit() else { return }
        ws.send(type: "video_keyframe_request", data: [
            "call_id":      callId,
            "recipient_id": recipientId,
        ])
    }

    /// WIRE_SPEC §8.1 — `call_video_state` (either direction, transparent
    /// relay). Informational signal only: tells the peer we paused/resumed
    /// our camera so their UI can show a "peer paused their video" badge
    /// or auto-fall-back to the audio-only call screen. Never touches the
    /// PeerConnection/SDP — the m=video line and transceiver direction
    /// stay exactly as negotiated.
    ///
    /// WIRE_SPEC §8.9 — `seq`/`screen` carry the beacon. Both default to nil so
    /// every existing caller keeps emitting exactly the pre-beacon frame; the
    /// 1:1 call path passes them so repeated announcements can be ordered by
    /// the receiver (see ``VideoStateBeacon``). Omitted from the payload
    /// entirely when nil — the frame stays byte-identical for a non-beacon
    /// caller.
    public func sendVideoState(
        callId: String,
        recipientId: String,
        paused: Bool,
        seq: Int? = nil,
        screen: Bool? = nil
    ) async throws {
        var payload: [String: Any] = [
            "call_id":      callId,
            "recipient_id": recipientId,
            "paused":       paused,
        ]
        if let seq {
            payload["seq"] = seq
            // Positive restatement of the same fact, so a receiver never has to
            // guess whether `paused=false` means "sending" or "no video at all".
            payload["sending"] = !paused
        }
        if let screen { payload["screen"] = screen }
        ws.send(type: "call_video_state", data: payload)
    }

    public func getRelays() async throws -> [RelayServer] {
        return try await getRelaysResponse().relays
    }

    public func getRelaysResponse() async throws -> RelayResponse {
        let data = try await rest.get("/api/v1/calling/relays")
        return try JSONDecoder().decode(RelayResponse.self, from: data)
    }

    /// Returns the active call id, falling back to a fresh UUID if none
    /// has been set (e.g. a stray `sendCallAnswer` arrived before any
    /// matching offer — pathological but should not crash).
    private func currentCallId() -> String {
        callIdLock.lock(); defer { callIdLock.unlock() }
        if let cid = activeCallId { return cid }
        let cid = UUID().uuidString
        activeCallId = cid
        return cid
    }

    /// Public hook for the responder side: when `call_incoming` arrives,
    /// AppState binds the inbound call_id here so the subsequent
    /// `sendCallAnswer` / `sendIceCandidate` / `sendHangup` use it.
    public func bindIncomingCallId(_ callId: String) {
        callIdLock.lock(); activeCallId = callId; callIdLock.unlock()
    }

    /// W525 — public read of the currently-bound call_id. Used by
    /// CallService.processOutgoingAudio so the `audio_frame` WS
    /// envelope can include the `call_id` field that Android's
    /// `BcryptoWsFrameRelayTransport.parseRawFrame` and Desktop's
    /// `MediaTransport.socketHandler` BOTH require — they silently
    /// drop frames whose `call_id` doesn't match. Returns nil when no
    /// call is active (no frames will be in flight in that state).
    public func getActiveCallId() -> String? {
        callIdLock.lock(); defer { callIdLock.unlock() }
        return activeCallId
    }

    /// Sync helpers — Swift 6 prohibits NSLock.lock/unlock directly inside
    /// `async` functions ("instance method 'lock' is unavailable from
    /// asynchronous contexts"). Wrapping the mutation in a sync method
    /// makes the lock call a sync→sync call which is allowed.
    private func checkAndMarkAnswerSent() -> Bool {
        callIdLock.lock(); defer { callIdLock.unlock() }
        if _answerSent { return true }
        _answerSent = true
        return false
    }

    /// WIRE_SPEC §8.7 — outbound video_keyframe_request rate limiter
    /// (1/s). Returns `true` when the send may proceed and records the
    /// timestamp; `false` when a request already went out inside the
    /// window. Same sync-helper pattern as `checkAndMarkAnswerSent` so
    /// the NSLock never touches an async context (Swift 6 rule above).
    private func checkKeyframeRequestRateLimit() -> Bool {
        keyframeRequestLock.lock(); defer { keyframeRequestLock.unlock() }
        let now = Date().timeIntervalSinceReferenceDate
        if now - _lastKeyframeRequestAt < 1.0 { return false }
        _lastKeyframeRequestAt = now
        return true
    }
    private var _lastKeyframeRequestAt: TimeInterval = 0
    private let keyframeRequestLock = NSLock()

    private func setActiveCallId(_ cid: String) {
        callIdLock.lock(); activeCallId = cid; callIdLock.unlock()
    }

    private func clearActiveCallId() {
        callIdLock.lock(); activeCallId = nil; _answerSent = false; callIdLock.unlock()
    }
}

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
            // W-LONGAUDIO (2026-08-10) — through the gated accessor, never the
            // raw base list. This convenience overload had `CallCapabilities.local`
            // inline, which bypasses the earbud filter entirely: on an earbud
            // call it would advertise `aprof-60x256-recv-v1` on the phone's
            // behalf and invite 60 ms frames into a 960-sample earbud decode
            // buffer. Android had the identical leak on its ring notification.
            capabilities: CallCapabilities.localCaps(),
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
            "call_id": cid,
            "sdp": sdp,
            "call_type": callType,
            "has_video": hasVideo,
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
            // W-LONGAUDIO — gated accessor; see `sendCallOffer` above.
            capabilities: CallCapabilities.localCaps()
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
        // Same pre-flight gate as sendCallOffer/sendCallOfferWithId — this
        // is the CALLEE-side counterpart and was missing it. An incoming
        // call that wakes the app from background hits CallKit's report
        // rejected (domain=com.apple.CallKit.error.incomingcall code=2) and
        // falls back to the in-app manual-answer path while the persistent
        // WS is still a suspended iOS ghost task; without this gate the
        // send() call below takes the best-effort "STALE socket — kicking
        // reconnect; attempting send anyway" branch, which sends into the
        // task `forceReconnect()` just cancelled and fails immediately
        // instead of waiting for the reconnect it triggered. The caller
        // then retries call_offer for 30s and gives up — the callee's
        // CallKit UI showed answered but the call never actually connects.
        // First attempt reliably fails this way; only a second attempt
        // (giving the WS time to reconnect on its own) succeeds. Confirmed
        // 2026-08-08 against accounts 133/134's device logs.
        let ready = await ws.ensureAuthenticated(timeoutSec: 5)
        if !ready {
            throw BCryptoCallingError.wsUnavailable
        }
        // Idempotency: drop duplicate answers for the same call session.
        // Can occur if the WebRTC onAnswerCreated callback fires twice or
        // if AppState logic races after receiving call_incoming twice.
        guard !checkAndMarkAnswerSent() else { return }
        // W-PHANTOMCALLID — no bound call means there is no call to answer.
        // Answering with a fabricated id only produced frames the server
        // refused; failing loudly is what lets the caller retry or tear down.
        guard let cid = activeCallIdOrNil() else {
            print("[BCryptoCalling] sendCallAnswer DROPPED — no active call_id bound")
            throw BCryptoCallingError.wsUnavailable
        }
        var data: [String: Any] = [
            "recipient_id": recipientId,
            "call_id": cid,
            "sdp": sdp,
            "has_video": hasVideo,
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
        // W-PHANTOMCALLID — ICE trickles for the life of a call, so THIS is the
        // path that used to mint the phantom id after any clear. A candidate
        // with no call to belong to is dropped, not invented into one.
        guard let cid = activeCallIdOrNil() else {
            print("[BCryptoCalling] sendIceCandidate DROPPED — no active call_id bound")
            return
        }
        var data: [String: Any] = [
            "call_id": cid,
            "candidate": candidate,
            "sdp_mline_index": sdpMLineIndex,
        ]
        data["sdp_mid"] = sdpMid ?? ""
        ws.send(type: "call_ice", data: data)
    }

    /// Tier-1 (2026-07-16 wire contract) — 1:1 call TARGETED reaction.
    /// Mirrors `sendIceCandidate`'s send path: rides the internally-tracked
    /// the bound active call id rather than an externally-passed callId (the call
    /// is already established by the time a reaction can be sent).
    /// `targetId` is the peer's userId; the server validates both sender
    /// and target are the two call parties (mirrors bcrypto-server's
    /// `group_call_signal` case) before relaying as `call_reaction_recv`.
    /// Wire: {call_id, target_id, emoji}.
    public func sendCallReaction(targetId: String, emoji: String) async throws {
        guard let cid = activeCallIdOrNil() else {
            print("[BCryptoCalling] sendCallReaction DROPPED — no active call_id bound")
            return
        }
        ws.send(type: "call_reaction", data: [
            "call_id": cid,
            "target_id": targetId,
            "emoji": emoji,
        ])
    }

    public func sendHangup(recipientId: String) async throws {
        // W-PHANTOMCALLID — hanging up a call that was never bound is a no-op,
        // not a reason to mint an id. `sendCallHangupForId` remains the way to
        // hang up an explicitly-known call (originator cleanup path).
        guard let cid = activeCallIdOrNil() else {
            print("[BCryptoCalling] sendHangup skipped — no active call_id bound")
            clearActiveCallId()
            return
        }
        // W419 — log so we can correlate with bcrypto.service journalctl.
        // The previous version had no log here, so when the Android peer
        // got "ghost call" the maintainer had no signal that iOS even
        // tried to send the hangup.
        print("[BCryptoCalling] sendHangup call_id=\(cid.prefix(8))… recipientId=\(recipientId.prefix(8))…")
        ws.send(
            type: "call_hangup",
            data: [
                "call_id": cid,
                "reason": "local_hangup",  // mirrors Android CallHangup.reason
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
            // W-LONGAUDIO — gated accessor; see `sendCallOffer` above.
            capabilities: CallCapabilities.localCaps(),
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
            "call_id": callId,
            "sdp": sdp,
            "call_type": callType,
            "has_video": hasVideo,
        ]
        if !capabilities.isEmpty { data["capabilities"] = capabilities }
        if let cd = callerDisplay, !cd.isEmpty {
            data["caller_display"] = cd
        }
        ws.send(type: "call_offer", data: data)
    }

    /// Send a call_hangup explicitly bound to a specific callId,
    /// bypassing the bound active call id entirely. Used by the
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
                "call_id": callId,
                "reason": "originator_offer_failed",
                "recipient_id": recipientId,   // belt-and-braces routing fallback
            ]
        )
        // W-ACTIVECALLASSERT — a call we just explicitly hung up is no
        // longer "believed live": unbind it (when it is the bound one) so
        // the next `authenticate` does not assert a dead call. Harmless if
        // it lingered anyway (the server answers a stale assertion with a
        // call_hangup the handler no-ops), but asserting truthfully is
        // strictly better than relying on that backstop.
        unbindCallIdIfMatching(callId)
    }

    // MARK: - Pre-negotiation (Android/Desktop interop)

    /// Acknowledge to the caller that this device received the call_offer and is
    /// initialising the PQC handshake. Pre-negotiation step 1.
    /// Server forwards this back to the caller verbatim — see bcrypto-server
    /// pre-negotiation flow in cmd/bcrypto-lite/main.go (call_processing case).
    ///
    /// Same pre-flight gate as `sendCallAnswer` — this fires the moment the
    /// incoming call_offer arrives, i.e. potentially the very first thing
    /// this device does after a background/push wake, before the WS has
    /// necessarily reconnected. Every caller already wraps this in
    /// `try? await` (AppState), so a timeout degrades to a silent drop —
    /// same as today, just no longer racing a doomed send.
    public func sendCallProcessing(callId: String, callerId: String) async throws {
        let ready = await ws.ensureAuthenticated(timeoutSec: 5)
        if !ready {
            throw BCryptoCallingError.wsUnavailable
        }
        ws.send(type: "call_processing", data: [
            "call_id": callId,
            "caller_id": callerId,
        ])
    }

    /// Notify the caller that the responder finished the PQC OFFER deserialisation
    /// and is ready to ring. Pre-negotiation step 2 — caller can now show "Ringing".
    /// See bcrypto-server pre-negotiation flow. Same pre-flight gate as
    /// `sendCallProcessing` above, same reasoning.
    public func sendCallReady(callId: String, callerId: String) async throws {
        let ready = await ws.ensureAuthenticated(timeoutSec: 5)
        if !ready {
            throw BCryptoCallingError.wsUnavailable
        }
        ws.send(type: "call_ready", data: [
            "call_id": callId,
            "caller_id": callerId,
        ])
    }

    /// Tell the caller a real user explicitly accepted the call. Distinct
    /// from `call_answer` (network-readiness, may be automatic) — see
    /// WIRE_SPEC.md §3.5. Server stamps sender_id/recipient_id and relays,
    /// same envelope class as call_processing/call_ready above.
    ///
    /// Same pre-flight gate as `sendCallAnswer`/`sendCallOffer` — see the
    /// comment on `sendCallAnswer` for the failure mode this closes. The
    /// caller (`AppState`) already wraps this in `try? await`, so a
    /// timeout here degrades to today's silent drop rather than bricking
    /// the call — it just now actually waits for the reconnect instead of
    /// firing into a task that was cancelled a moment earlier.
    public func sendCallAccepted(callId: String) async throws {
        let ready = await ws.ensureAuthenticated(timeoutSec: 5)
        if !ready {
            throw BCryptoCallingError.wsUnavailable
        }
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
            "call_id": callId,
            "recipient_id": recipientId,
            "sdp": sdp,
            "media": media,
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
            "call_id": callId,
            "recipient_id": recipientId,
            "sdp": sdp,
            "accepted": accepted,
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
            "call_id": callId,
            "recipient_id": recipientId,
            "mid": mid,
            "key_epoch": keyEpoch,
            "dir": dir,
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
            "call_id": callId,
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
            "call_id": callId,
            "recipient_id": recipientId,
            "paused": paused,
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

    /// W-PHANTOMCALLID (2026-08-14) — the id of the call that is actually
    /// running, or `nil`. It NEVER invents one.
    ///
    /// This used to fall back to a fresh `UUID().uuidString` AND latch it into
    /// `activeCallId`, so a moment of `nil` did not degrade one frame — it
    /// permanently redirected the whole call onto an id the server had never
    /// heard of. Everything sent afterwards was refused, silently from the
    /// device's point of view:
    ///
    ///   WARN "F4: call_video_state for foreign call_id rejected" user=9a2aa555
    ///   WARN "audio relay rejected: not an established call party" ...
    ///
    /// Live on call `7fbb9921` (2026-08-14, both legs 1.0.986): audio flowed
    /// normally, then ~30 s in the callee's frames started being rejected and
    /// that direction went silent for the remaining 8 s until the user hung up.
    /// `sendHangup` clears `activeCallId` by design, and ICE candidates keep
    /// trickling during a call — so one late `sendIceCandidate` after any clear
    /// was enough to mint a phantom id and poison every later frame.
    ///
    /// The original intent was only "do not crash on a stray `sendCallAnswer`
    /// that has no matching offer". Answering with a fabricated id never
    /// achieved anything anyway — the server rejects it — so not sending, and
    /// saying so, is strictly better than sending into a call that does not
    /// exist.
    private func activeCallIdOrNil() -> String? {
        callIdLock.lock(); defer { callIdLock.unlock() }
        return activeCallId
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

    /// W-ACTIVECALLASSERT — clear the bound id ONLY when it names the same
    /// call (case-insensitive, same rationale as `peerCapabilities`' fold:
    /// the wire id's case has drifted before). Sync helper for the same
    /// Swift 6 NSLock-in-async rule as `checkAndMarkAnswerSent` above.
    private func unbindCallIdIfMatching(_ callId: String) {
        callIdLock.lock(); defer { callIdLock.unlock() }
        guard let bound = activeCallId,
              bound.caseInsensitiveCompare(callId) == .orderedSame else { return }
        activeCallId = nil
        _answerSent = false
    }

    private func clearActiveCallId() {
        callIdLock.lock(); activeCallId = nil; _answerSent = false; callIdLock.unlock()
    }
}

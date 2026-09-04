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
    /// W-PARKFRESHOFFER — the single in-flight restart-offer park (see
    /// sendIceRestartOffer); a newer attempt cancels the older one.
    private var pendingRestartPark: Task<Void, Never>?
    private let pendingRestartParkLock = NSLock()
    /// Guard against sending call_answer more than once per call session.
    /// Reset alongside activeCallId in clearActiveCallId().
    private var _answerSent = false
    /// W-SETUPRETRY (2026-08-25) — latched `true` the moment the call
    /// demonstrably progressed past setup (answer/accepted received,
    /// connected, first real inbound media frame decoded). Stops the bounded
    /// JSON-envelope retransmit ladders below; guarded by `callIdLock`, reset
    /// alongside `activeCallId` on every bind so a new call never inherits
    /// the previous call's latch.
    private var _setupProgressed = false

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
        // W-SETUPRETRY (2026-08-25) — a single lost call_offer used to fail
        // the whole setup. Bounded retransmit; RX side dedups (the callee's
        // call_incoming handler drops/rescues duplicates by design). The
        // opaque PQC OFFER bundle is NOT retried here — it stays emitted
        // exactly once per contract (the server's store+replay is
        // load-bearing and receivers replay the cached ACCEPT); this ladder
        // covers ONLY the plain JSON envelope.
        scheduleSetupRetransmit(callId: cid, type: "call_offer", data: data, label: "call_offer")
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
        // W-SETUPRETRY — a lost call_answer used to strand the caller in its
        // full ring timeout on a call this side already answered. Bounded
        // retransmit of the byte-identical payload; the caller's RX side is
        // idempotent (duplicate call_answer is the long-known W418 case).
        // The retransmit bypasses `checkAndMarkAnswerSent` on purpose — that
        // guard dedups CALLERS of this method, not the ladder's own resends.
        scheduleSetupRetransmit(callId: cid, type: "call_answer", data: data, label: "call_answer")
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
        try await sendHangup(recipientId: recipientId, reason: "local_hangup")
    }

    /// Reason-bearing overload (impl-only, not on the `CallingApi` protocol —
    /// callers that need a specific wire reason, e.g. W-GLARE's `"glare"` or
    /// W-MEDIADEAD's `"media-lost"`, downcast and call this; the protocol
    /// method above delegates with the historical `"local_hangup"`).
    public func sendHangup(recipientId: String, reason: String) async throws {
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
        // Clear BEFORE the (possibly parked, async) delivery so the next
        // `authenticate` never re-asserts a call this side has already
        // decided is dead (W-ACTIVECALLASSERT), and so a next outgoing call
        // starts fresh even while a park is still pending.
        clearActiveCallId()
        await deliverHangup(callId: cid, recipientId: recipientId, reason: reason)
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
        // W-SETUPRETRY — same ladder as the minting overload above; this is
        // the externally-chosen-id path (Android-originator pipeline).
        scheduleSetupRetransmit(callId: callId, type: "call_offer", data: data, label: "call_offer")
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
        try await sendCallHangupForId(callId: callId, recipientId: recipientId,
                                      reason: "originator_offer_failed")
    }

    /// Reason-bearing overload (impl-only) — W-GLARE's loser teardown hangs
    /// up its outgoing call by EXPLICIT id with reason `"glare"` through
    /// here, after synchronously unbinding via ``unbindActiveCallId(matching:)``
    /// so `endCall()`'s own generic hangup paths find no binding and no-op
    /// (exactly one reason-bearing hangup reaches the wire).
    public func sendCallHangupForId(callId: String, recipientId: String, reason: String) async throws {
        // W-ACTIVECALLASSERT — a call we just explicitly hung up is no
        // longer "believed live": unbind it (when it is the bound one) so
        // the next `authenticate` does not assert a dead call. Harmless if
        // it lingered anyway (the server answers a stale assertion with a
        // call_hangup the handler no-ops), but asserting truthfully is
        // strictly better than relying on that backstop. Moved BEFORE the
        // delivery (2026-08-25): delivery can now park asynchronously, and
        // the unbind must not wait for the socket.
        unbindCallIdIfMatching(callId)
        await deliverHangup(callId: callId, recipientId: recipientId, reason: reason)
    }

    /// W-HANGUPPARK + hangup-opaque-piggyback (2026-08-25) — the single
    /// choke point every outbound hangup flows through.
    ///
    /// Two-channel send, mirroring Android `WsCallSignaller.sendHangup`:
    /// bcrypto-lite is observed to forward `opaque_message` while dropping
    /// `call_hangup` envelopes silently in certain paths, so BOTH go out —
    /// the envelope for any server path that does forward it, the
    /// `<callId>|HANGUP:<reason>` opaque (plain string, NOT base64) for the
    /// one that doesn't. Receivers dedup in their state machines; the
    /// server-side EndCall is party-authorized and idempotent, so duplicates
    /// are silent no-ops everywhere.
    ///
    /// Park: a hangup pressed mid-network-outage must NOT be lost — the
    /// live Android incident (call afc64e8d) had the peer learn via the DC
    /// control frame while the SERVER kept the call tracked, leaving both
    /// users "busy" to any third caller until the sweep. Fast path waits up
    /// to 5 s for an authenticated socket (same gate as call_offer/answer);
    /// failing that, a DETACHED task parks the pair for up to 40 more
    /// seconds (~45 s total from the press, under the server's 60 s
    /// disconnect-grace ceiling, matching Android's HANGUP_PARK_BUDGET_MS)
    /// and resends the moment `ensureAuthenticated` sees the socket come
    /// back. Detached so the caller (endCall's fire-and-forget Task, the
    /// originator-cleanup error path) is never blocked for the park window.
    private func deliverHangup(callId: String, recipientId: String, reason: String) async {
        let envelope: [String: Any] = [
            "call_id": callId,
            "reason": reason,                // mirrors Android CallHangup.reason
            "recipient_id": recipientId,     // belt-and-braces routing fallback
        ]
        let opaque = CallPiggyBack.serializeHangup(callId: callId, reason: reason)
        let ready = await ws.ensureAuthenticated(timeoutSec: 5)
        if ready {
            ws.send(type: "call_hangup", data: envelope)
            ws.sendOpaqueMessageString(recipientId: recipientId, payload: opaque)
            return
        }
        // Best-effort immediate attempt anyway — `send` kicks its own
        // reconnect for control envelopes and the state probe can be wrong;
        // a duplicate arrival after the parked resend is a server no-op.
        ws.send(type: "call_hangup", data: envelope)
        ws.sendOpaqueMessageString(recipientId: recipientId, payload: opaque)
        print("[BCryptoCalling] hangup park armed call_id=\(callId.prefix(8))… (WS not ready)")
        let wsRef = ws
        Task.detached(priority: .utility) {
            let late = await wsRef.ensureAuthenticated(timeoutSec: 40)
            guard late else {
                print("[BCryptoCalling] hangup park expired call_id=\(callId.prefix(8))… — server sweep will collect")
                return
            }
            wsRef.send(type: "call_hangup", data: envelope)
            wsRef.sendOpaqueMessageString(recipientId: recipientId, payload: opaque)
            print("[BCryptoCalling] hangup park delivered call_id=\(callId.prefix(8))…")
        }
    }

    /// W-SILENTPATHDEATH / W-RESTARTOFFERPARK (2026-08-25) — the single
    /// choke point for a mid-call ICE-restart `call_offer`, reusing the
    /// bound active call id (a restart offer is never a new call session).
    ///
    /// Same two-phase shape as `deliverHangup` above (same file, same
    /// day, same 45s-under-60s-ceiling park budget — Android's
    /// `RESTART_OFFER_PARK_BUDGET_MS`): fast path waits up to 5s for an
    /// authenticated socket; failing that, a DETACHED task parks for up to
    /// 40 more seconds (~45s total from the call) and resends the moment
    /// `ensureAuthenticated` sees the socket come back — comfortably under
    /// the server's 60s disconnect-grace ceiling, so a landing resend also
    /// renews the server-side grace via signaling activity, exactly like
    /// Android's park. This is NOT Android's separate 5-attempt inline
    /// backoff ladder (250ms→4s) BEFORE the park — that ladder exists
    /// there to race a specific `WsDispatcher.awaitSendReady` primitive
    /// this iOS WS client doesn't expose the same way; `ws
    /// .ensureAuthenticated(timeoutSec:)` already IS a bounded,
    /// event-driven "wait for ready" (not a blind sleep), so folding
    /// straight into the park after one 5s attempt preserves the
    /// INVARIANT (send now if possible, otherwise park under the 45s/60s
    /// budget and resend the instant the socket recovers) without a
    /// second, redundant backoff layer on top of it.
    ///
    /// `QAudionWebRtcCallController.restartIce` calls this exactly once
    /// per restart attempt (its own `iceRestartDebounceMs` prevents
    /// hammering); the recovery watchdog re-invokes `restartIce` on its own
    /// backed-off settle-window cadence if ICE is still bad afterwards —
    /// that outer loop is where Android's repeated-attempt behavior lives
    /// on this platform, not inside a single send call.
    ///
    /// No `sendCallOfferWithId`/`scheduleSetupRetransmit` reuse — see the
    /// protocol kdoc: that ladder is a no-op once the call has
    /// demonstrably progressed past setup, which every ICE-restart call
    /// always has by definition.
    public func sendIceRestartOffer(
        recipientId: String,
        sdp: String,
        capabilities: [String],
        onParkDelivery: (@Sendable () async -> Void)? = nil
    ) async -> Bool {
        guard let cid = activeCallIdOrNil() else {
            print("[BCryptoCalling] sendIceRestartOffer DROPPED — no active call_id bound")
            return false
        }
        var data: [String: Any] = [
            "recipient_id": recipientId,
            "call_id": cid,
            "sdp": sdp,
            // W-RESTARTOFFERPARK — mirrors Android's restart-offer envelope
            // verbatim: `call_type` stays "audio" even on a video call. The
            // restart's actual video-negotiation outcome is carried
            // entirely by the SDP body (the existing m=video section is
            // renegotiated in place, unaffected by this top-level field) —
            // `call_type` only matters for the FIRST offer of a call; a
            // restart offer does not re-establish it.
            "call_type": "audio",
        ]
        if !capabilities.isEmpty { data["capabilities"] = capabilities }
        // Audit item 4 (2026-08-26) — these two waits used to be the bare
        // literals `5` / `40`, untested and undocumented anywhere as the
        // live path's real timing. Now sourced from `RestartIceDecisions`,
        // the same pinned-and-unit-tested file every other restart-ice
        // constant lives in (see that file's kdoc on
        // `restartOfferMaxInlineAttempts` for why the 5-attempt ladder
        // itself is NOT reused here — this is not that ladder, just its
        // sibling constants for the timing that actually ships).
        let ready = await ws.ensureAuthenticated(timeoutSec: RestartIceDecisions.restartOfferFastPathTimeoutSec)
        if ready {
            ws.send(type: "call_offer", data: data)
            return true
        }
        // Best-effort immediate attempt anyway (same reasoning as
        // deliverHangup: `send` kicks its own reconnect for control
        // envelopes, and the readiness probe can be wrong).
        ws.send(type: "call_offer", data: data)
        print("[BCryptoCalling] restart offer park armed call_id=\(cid.prefix(8))… (WS not ready)")
        // W-PARKFRESHOFFER — at most ONE park in flight: a newer restart
        // attempt supersedes an older parked one (two detached parks used
        // to both fire on WS recovery in arbitrary order, and the older
        // carried an SDP whose local description no longer existed).
        pendingRestartParkLock.withLock {
            pendingRestartPark?.cancel()
            pendingRestartPark = nil
        }
        let wsRef = ws
        let park = Task.detached(priority: .utility) {
            let late = await wsRef.ensureAuthenticated(timeoutSec: RestartIceDecisions.restartOfferParkTimeoutSec)
            guard late, !Task.isCancelled else {
                print("[BCryptoCalling] restart offer park expired/cancelled call_id=\(cid.prefix(8))…")
                return
            }
            if let onParkDelivery {
                // Mint a FRESH offer at delivery time instead of resending
                // the one captured up to 40s ago (see protocol kdoc).
                print("[BCryptoCalling] restart offer park re-minting call_id=\(cid.prefix(8))…")
                await onParkDelivery()
            } else {
                wsRef.send(type: "call_offer", data: data)
                print("[BCryptoCalling] restart offer park delivered call_id=\(cid.prefix(8))…")
            }
        }
        pendingRestartParkLock.withLock { pendingRestartPark = park }
        return false
    }

    /// W-RESPONDERREQFIRST (2026-08-30) — see the protocol kdoc. Same
    /// two-phase delivery shape as `sendIceRestartOffer` (fast-path
    /// authenticated send, then a detached park up to the server's
    /// disconnect-grace ceiling), because this request races the very WS
    /// reconnect the network change that triggered it caused — exactly the
    /// race Android closed with its own request-retry (W-RESTARTICEREQRETRY).
    public func sendRestartIceRequest(recipientId: String) async -> Bool {
        guard let cid = activeCallIdOrNil() else {
            print("[BCryptoCalling] sendRestartIceRequest DROPPED — no active call_id bound")
            return false
        }
        let data: [String: Any] = [
            "recipient_id": recipientId,
            "call_id": cid,
        ]
        let ready = await ws.ensureAuthenticated(timeoutSec: RestartIceDecisions.restartOfferFastPathTimeoutSec)
        if ready {
            ws.send(type: "restart_ice_request", data: data)
            return true
        }
        ws.send(type: "restart_ice_request", data: data)
        print("[BCryptoCalling] restart request park armed call_id=\(cid.prefix(8))… (WS not ready)")
        let wsRef = ws
        Task.detached(priority: .utility) {
            let late = await wsRef.ensureAuthenticated(timeoutSec: RestartIceDecisions.restartOfferParkTimeoutSec)
            guard late else {
                print("[BCryptoCalling] restart request park expired call_id=\(cid.prefix(8))…")
                return
            }
            wsRef.send(type: "restart_ice_request", data: data)
            print("[BCryptoCalling] restart request park delivered call_id=\(cid.prefix(8))…")
        }
        return false
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
    /// necessarily reconnected. Every caller (AppState) catches and logs a
    /// timeout (W-SIGSWALLOW, 2026-09-01); the envelope is deliberately NOT
    /// retransmitted — see `CallSignalingFailurePolicy.socketNotReadyAction`
    /// for why neither this nor `call_ready` may ride the setup ladder.
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
    /// comment on `sendCallAnswer` for the failure mode this closes. It
    /// waits for the reconnect instead of firing into a task that was
    /// cancelled a moment earlier; on a gate timeout it throws
    /// `wsUnavailable` (the caller logs it) AFTER a best-effort send and
    /// arming the retransmit ladder — see W-SIGSWALLOW inside.
    public func sendCallAccepted(callId: String) async throws {
        let data: [String: Any] = ["call_id": callId]
        let ready = await ws.ensureAuthenticated(timeoutSec: 5)
        if !ready {
            // W-SIGSWALLOW (2026-09-01) — this used to throw BEFORE sending,
            // so an accept pressed while the socket was still reconnecting
            // (the exact background-wake race `sendCallAnswer`'s comment
            // documents) was lost outright: the W-SETUPRETRY ladder that
            // protects the success path below was never armed on the one
            // path that needed it. Now: one best-effort send (`ws.send`
            // kicks its own reconnect for control envelopes) plus the SAME
            // bounded ladder (2.5 s / 5 s, stops on unbind/progression; the
            // caller's RX is idempotent), then still throw so the caller
            // logs the fast-path miss. Decision + kill switch live in
            // `CallSignalingFailurePolicy` (audit memory
            // reference_ios_stability_audit_2026_09_01, P1 item 7).
            if CallSignalingFailurePolicy.socketNotReadyAction(for: .callAccepted) == .bestEffortSendAndArmRetransmit {
                ws.send(type: "call_accepted", data: data)
                print("[BCryptoCalling] call_accepted fast-path miss call_id=\(callId.prefix(8))… — best-effort send + retransmit ladder armed")
                scheduleSetupRetransmit(callId: callId, type: "call_accepted", data: data, label: "call_accepted")
            }
            throw BCryptoCallingError.wsUnavailable
        }
        ws.send(type: "call_accepted", data: data)
        // W-SETUPRETRY — mirrors Android's accept-retransmit (2.5 s / 5 s,
        // CallController.startIncoming): the accept can be WRITTEN into a
        // socket already dead on the wire, and the caller then sits out its
        // ring timeout on a call this side already answered. Receipt is
        // idempotent for the caller (it only gates the SAS/active display),
        // so a duplicate is harmless; the ladder stops on unbind (hangup /
        // new call) or on the progression latch (first real inbound decode —
        // media from the caller proves the accept, or its answer sibling,
        // got through).
        scheduleSetupRetransmit(callId: callId, type: "call_accepted", data: data, label: "call_accepted")
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

    /// WIRE_SPEC §8.7 (v1.2) — receiver→sender media readiness. Sent by
    /// the RECEIVER when its receiver-side cryptor is BOTH keyed and
    /// bound to the negotiated mid; the sender responds by forcing a
    /// local encoder IDR (video) or, from `keyEpoch > 0` on, gates the
    /// deferred sender-switch for a re-key (see `RekeySwitchGate`).
    /// `dir` is "recv" today; `keyEpoch` is 0 until rekey epochs ship.
    /// `media` is "audio" or "video" — additive field, fires on EVERY
    /// re-key now, not just the first key of a call. The server stamps
    /// `sender_id` and relays transparently (same class as call_upgrade_*).
    public func sendCallMediaReady(
        callId: String,
        recipientId: String,
        mid: String,
        keyEpoch: Int,
        dir: String,
        media: String
    ) async throws {
        ws.send(type: "call_media_ready", data: [
            "call_id": callId,
            "recipient_id": recipientId,
            "mid": mid,
            "key_epoch": keyEpoch,
            "dir": dir,
            "media": media,
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

    /// W-AUXPIN (2026-09-02) — see the protocol doc on `CallingApi
    /// .pinnedUrlSession()`. `rest` is the SAME `BCryptoRestClient` every
    /// other call in this class already sends its traffic through, so this
    /// exposes its existing pinned session — no new pin data, no new
    /// `URLSession` construction.
    public func pinnedUrlSession() -> URLSession? { rest.urlSession }

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
        callIdLock.lock(); activeCallId = callId; _setupProgressed = false; callIdLock.unlock()
    }

    /// W-SETUPRETRY (2026-08-25) — the call demonstrably progressed past
    /// setup: an answer/accepted arrived, the call connected, or the first
    /// REAL inbound media frame decoded. Stops every pending retransmit
    /// ladder for the bound call. `callId == nil` (or empty) latches
    /// unconditionally for whatever call is bound — used by the sites that
    /// know "the current call progressed" without holding the wire id; a
    /// non-matching id is ignored (a late signal for a previous call must
    /// not stop a NEW call's ladder).
    public func noteCallSetupProgressed(_ callId: String?) {
        callIdLock.lock(); defer { callIdLock.unlock() }
        if let cid = callId, !cid.isEmpty {
            guard let bound = activeCallId,
                  bound.caseInsensitiveCompare(cid) == .orderedSame else { return }
        }
        _setupProgressed = true
    }

    /// W-GLARE (2026-08-25) — synchronous unbind for the glare-loser
    /// teardown path. The loser must ship its reason-bearing hangup against
    /// the EXPLICIT outgoing id (``sendCallHangupForId(callId:recipientId:reason:)``)
    /// while `endCall()`'s generic hangup paths — which read the binding —
    /// find nothing and no-op; calling this FIRST, synchronously, is what
    /// makes exactly one `"glare"` hangup reach the wire instead of a
    /// nondeterministic race between two reasons. Case-insensitive match,
    /// same rationale as `unbindCallIdIfMatching`.
    public func unbindActiveCallId(matching callId: String) {
        unbindCallIdIfMatching(callId)
    }

    /// W-GLARE (2026-08-25) — `true` while `callId` is the bound call and its
    /// setup has NOT yet demonstrably progressed (no answer/accepted received,
    /// not connected, no real inbound media decoded). This is iOS's mapping of
    /// Android's `outgoingCallIdIfDialing` window (`CallState.Handshaking` +
    /// `asInitiator`): the state AppState keeps (`callState`) cannot express
    /// "dialing, pre-answer" — the outgoing flow sets `.active` right after
    /// the OFFER round-trip — while this latch flips on exactly the signals
    /// that end the dialing phase. In every physically-realizable mutual-dial
    /// glare both peers are pre-answer on their outgoing legs, so the two
    /// predicates agree; once anything progressed, the incoming envelope is
    /// an ICE-restart/replay case and belongs to the existing dedup guards,
    /// which is precisely what returning `false` here hands it to.
    public func isCallSetupStillPending(_ callId: String) -> Bool {
        return setupRetryShouldResend(for: callId)
    }

    /// W-SETUPRETRY — `true` while the retransmit ladder for `callId` should
    /// keep firing: the id is still the bound call AND nothing has latched
    /// progression. Sync helper for the Swift 6 NSLock-in-async rule (see
    /// `checkAndMarkAnswerSent`).
    private func setupRetryShouldResend(for callId: String) -> Bool {
        callIdLock.lock(); defer { callIdLock.unlock() }
        guard let bound = activeCallId,
              bound.caseInsensitiveCompare(callId) == .orderedSame else { return false }
        return !_setupProgressed
    }

    /// W-SETUPRETRY — bounded retransmit of one already-sent JSON setup
    /// envelope: 2.5 s then 5 s (Android's accept-retransmit ladder,
    /// `CallController.startIncoming`), byte-identical payload each time,
    /// stopping the moment the call unbinds (hangup, teardown, a new call)
    /// or progression latches. At most 2 extra sends per envelope, ever —
    /// safe by construction against RX sides that are idempotent by
    /// contract (offer: the callee's dup-drop/rescue; answer: W418;
    /// accepted: the two-flag latch).
    private func scheduleSetupRetransmit(callId: String,
                                         type: String,
                                         data: [String: Any],
                                         label: String) {
        Task { [weak self] in
            for delayMs in [2_500, 5_000] {
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                guard let self else { return }
                guard self.setupRetryShouldResend(for: callId) else { return }
                print("[BCryptoCalling] \(label) retransmit call_id=\(callId.prefix(8))… (setup still pending)")
                self.ws.send(type: type, data: data)
            }
        }
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
        callIdLock.lock(); activeCallId = cid; _setupProgressed = false; callIdLock.unlock()
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
        callIdLock.lock(); activeCallId = nil; _answerSent = false; _setupProgressed = false; callIdLock.unlock()
    }
}

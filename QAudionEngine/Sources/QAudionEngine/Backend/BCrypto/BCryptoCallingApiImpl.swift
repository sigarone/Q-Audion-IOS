import Foundation

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

    init(ws: BCryptoWebSocketClient, rest: BCryptoRestClient) { self.ws = ws; self.rest = rest }

    public func sendCallOffer(recipientId: String, sdp: String) async throws {
        // Mint a fresh call_id and stash for the rest of the session.
        let cid = UUID().uuidString
        setActiveCallId(cid)
        ws.send(
            type: "call_offer",
            data: [
                "recipient_id": recipientId,
                "call_id":      cid,
                "sdp":          sdp,
                "call_type":    "audio",  // SDP-less PQC path uses "audio"
            ]
        )
    }

    public func sendCallAnswer(recipientId: String, sdp: String) async throws {
        let cid = currentCallId()
        ws.send(
            type: "call_answer",
            data: [
                "call_id": cid,
                "sdp":     sdp,
            ]
        )
    }

    public func sendIceCandidate(recipientId: String, candidate: String) async throws {
        let cid = currentCallId()
        ws.send(
            type: "call_ice",
            data: [
                "call_id":         cid,
                "candidate":       candidate,
                "sdp_mid":         "",
                "sdp_mline_index": 0,
            ]
        )
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
                "call_id":     cid,
                "reason":      "normal",
                "recipient_id": recipientId,  // belt-and-braces: server uses
                                              // call_id but explicit recipient
                                              // gives a fallback for race cases
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
    /// Pins the supplied callId on the in-process state machine so
    /// subsequent `sendCallAnswer` / `sendIceCandidate` / `sendHangup`
    /// envelopes ride on the same callId, AND sends the WS frame
    /// carrying that exact callId — keeping the WS wire, the engine
    /// stash, and the PQC bundle's callId field all aligned.
    /// Per OpenRouter glm-5.1 review 2026-05-06 P0 #1.
    public func sendCallOfferWithId(callId: String, recipientId: String, sdp: String) async throws {
        setActiveCallId(callId)
        ws.send(
            type: "call_offer",
            data: [
                "recipient_id": recipientId,
                "call_id":      callId,
                "sdp":          sdp,
                "call_type":    "audio",
            ]
        )
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
                "call_id": callId,
                "reason":  "originator_offer_failed",
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

    public func getRelays() async throws -> [RelayServer] {
        let data = try await rest.get("/api/v1/calling/relays")
        let response = try JSONDecoder().decode(RelayResponse.self, from: data)
        return response.relays
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

    /// Sync helpers — Swift 6 prohibits NSLock.lock/unlock directly inside
    /// `async` functions ("instance method 'lock' is unavailable from
    /// asynchronous contexts"). Wrapping the mutation in a sync method
    /// makes the lock call a sync→sync call which is allowed.
    private func setActiveCallId(_ cid: String) {
        callIdLock.lock(); activeCallId = cid; callIdLock.unlock()
    }

    private func clearActiveCallId() {
        callIdLock.lock(); activeCallId = nil; callIdLock.unlock()
    }
}

import Foundation

/// Call signaling routed through Signal's infrastructure.
///
/// Q-Audion call data (SDP offers/answers, ICE candidates) is wrapped as opaque
/// payloads and transported via Signal's message channel. When both endpoints are
/// Q-Audion users, payloads are encrypted with our PQC crypto before reaching this
/// layer. When the remote is a standard Signal user, the opaque message falls through
/// to Signal's own encryption.
///
/// Prefers WebSocket for low-latency signaling; falls back to REST POST when the
/// WebSocket is not authenticated.
public final class UpstreamCallingApiImpl: CallingApi {
    private let rest: BCryptoRestClient
    private let ws: BCryptoWebSocketClient

    init(rest: BCryptoRestClient, ws: BCryptoWebSocketClient) {
        self.rest = rest
        self.ws = ws
    }

    // MARK: - CallingApi

    public func sendCallOffer(recipientId: String, sdp: String) async throws {
        let payload: [String: Any] = [
            "recipientId": recipientId,
            "sdp": sdp,
            "type": "offer"
        ]
        try await sendCallSignal(recipientId: recipientId, type: "call_offer", payload: payload)
    }

    public func sendCallAnswer(recipientId: String, sdp: String) async throws {
        let payload: [String: Any] = [
            "recipientId": recipientId,
            "sdp": sdp,
            "type": "answer"
        ]
        try await sendCallSignal(recipientId: recipientId, type: "call_answer", payload: payload)
    }

    public func sendIceCandidate(recipientId: String, candidate: String) async throws {
        let payload: [String: Any] = [
            "recipientId": recipientId,
            "candidate": candidate
        ]
        try await sendCallSignal(recipientId: recipientId, type: "call_ice", payload: payload)
    }

    public func sendHangup(recipientId: String) async throws {
        try await sendCallSignal(
            recipientId: recipientId,
            type: "call_hangup",
            payload: ["recipientId": recipientId]
        )
    }

    /// Send an opaque message carrying already-encrypted Q-Audion data.
    /// This is the primary transport for PQC-encrypted call payloads between
    /// Q-Audion users routed through Signal.
    public func sendOpaqueMessage(recipientId: String, data: Data) async throws {
        if ws.state == .authenticated {
            ws.sendOpaqueMessage(recipientId: recipientId, payload: data)
        } else {
            let body = try JSONSerialization.data(withJSONObject: [
                "recipient_id": recipientId,
                "data": data.base64EncodedString(),
                "type": "opaque_message"
            ])
            _ = try await rest.post("/v1/messages/opaque", body: body)
        }
    }

    // MARK: - Internal

    /// Route call signaling through WebSocket when authenticated, REST otherwise.
    /// Signal uses opaque messages for call signaling -- we wrap Q-Audion call
    /// data as a JSON payload inside the opaque envelope.
    private func sendCallSignal(
        recipientId: String,
        type: String,
        payload: [String: Any]
    ) async throws {
        if ws.state == .authenticated {
            ws.send(type: type, data: payload)
        } else {
            let envelope: [String: Any] = [
                "type": type,
                "destination": recipientId,
                "content": payload
            ]
            let body = try JSONSerialization.data(withJSONObject: envelope)
            _ = try await rest.post("/v1/messages/\(recipientId)", body: body)
        }
    }
}

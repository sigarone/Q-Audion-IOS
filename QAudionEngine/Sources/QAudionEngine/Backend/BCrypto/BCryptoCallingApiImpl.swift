import Foundation

public final class BCryptoCallingApiImpl: CallingApi {
    private let ws: BCryptoWebSocketClient
    private let rest: BCryptoRestClient
    init(ws: BCryptoWebSocketClient, rest: BCryptoRestClient) { self.ws = ws; self.rest = rest }

    public func sendCallOffer(recipientId: String, sdp: String) async throws {
        ws.send(type: "call_offer", data: ["recipientId": recipientId, "sdp": sdp])
    }
    public func sendCallAnswer(recipientId: String, sdp: String) async throws {
        ws.send(type: "call_answer", data: ["recipientId": recipientId, "sdp": sdp])
    }
    public func sendIceCandidate(recipientId: String, candidate: String) async throws {
        ws.send(type: "call_ice", data: ["recipientId": recipientId, "candidate": candidate])
    }
    public func sendHangup(recipientId: String) async throws {
        ws.send(type: "call_hangup", data: ["recipientId": recipientId])
    }
    public func sendOpaqueMessage(recipientId: String, data: Data) async throws {
        ws.sendOpaqueMessage(recipientId: recipientId, payload: data)
    }

    // MARK: - Pre-negotiation (Android/Desktop interop)

    /// Acknowledge to the caller that this device received the call_offer and is
    /// initialising the PQC handshake. Pre-negotiation step 1.
    /// Server forwards this back to the caller verbatim — see bcrypto-server
    /// pre-negotiation flow in cmd/bcrypto-lite/main.go (call_processing case).
    public func sendCallProcessing(callId: String, callerId: String) async throws {
        ws.send(type: "call_processing", data: [
            "call_id": callId,
            "caller_id": callerId
        ])
    }

    /// Signal to the caller that the responder finished the PQC OFFER deserialisation
    /// and is ready to ring. Pre-negotiation step 2 — caller can now show "Ringing".
    /// See bcrypto-server pre-negotiation flow.
    public func sendCallReady(callId: String, callerId: String) async throws {
        ws.send(type: "call_ready", data: [
            "call_id": callId,
            "caller_id": callerId
        ])
    }

    public func getRelays() async throws -> [RelayServer] {
        let data = try await rest.get("/api/v1/calling/relays")
        let response = try JSONDecoder().decode(RelayResponse.self, from: data)
        return response.relays
    }
}

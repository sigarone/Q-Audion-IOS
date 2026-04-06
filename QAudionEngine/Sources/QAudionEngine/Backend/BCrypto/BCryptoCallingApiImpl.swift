import Foundation

public final class BCryptoCallingApiImpl: CallingApi {
    private let ws: BCryptoWebSocketClient
    init(ws: BCryptoWebSocketClient) { self.ws = ws }

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
}

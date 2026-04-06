import Foundation

public final class BCryptoGroupCallManager {
    private let ws: BCryptoWebSocketClient
    public init(ws: BCryptoWebSocketClient) { self.ws = ws }

    public func createGroupCall(participants: [String]) {
        ws.send(type: "group_call_create", data: ["participants": participants])
    }
    public func joinGroupCall(callId: String) {
        ws.send(type: "group_call_join", data: ["callId": callId])
    }
    public func leaveGroupCall(callId: String) {
        ws.send(type: "group_call_leave", data: ["callId": callId])
    }
}

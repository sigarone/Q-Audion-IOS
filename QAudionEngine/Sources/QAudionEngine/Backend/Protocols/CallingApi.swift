import Foundation

public protocol CallingApi {
    func sendCallOffer(recipientId: String, sdp: String) async throws
    func sendCallAnswer(recipientId: String, sdp: String) async throws
    func sendIceCandidate(recipientId: String, candidate: String) async throws
    func sendHangup(recipientId: String) async throws
    func sendOpaqueMessage(recipientId: String, data: Data) async throws
    /// Get TURN/STUN relay servers with time-limited credentials.
    func getRelays() async throws -> [RelayServer]
}

public struct RelayServer: Codable {
    public let urls: [String]
    public let username: String
    public let credential: String
    public let ttl: Int
}

public struct RelayResponse: Codable {
    public let relays: [RelayServer]
}

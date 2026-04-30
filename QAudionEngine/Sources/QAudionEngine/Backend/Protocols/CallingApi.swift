import Foundation

public protocol CallingApi {
    func sendCallOffer(recipientId: String, sdp: String) async throws
    func sendCallAnswer(recipientId: String, sdp: String) async throws
    func sendIceCandidate(recipientId: String, candidate: String) async throws
    func sendHangup(recipientId: String) async throws
    func sendOpaqueMessage(recipientId: String, data: Data) async throws
    /// Get TURN/STUN relay servers with time-limited credentials.
    func getRelays() async throws -> [RelayServer]

    // MARK: - Pre-negotiation (optional — backend-specific)
    // Only the BCrypto backend implements these today; Signal/upstream paths
    // route call signaling through opaque messages and don't need explicit
    // processing/ready ACKs. Default impls are no-ops to keep the protocol
    // additive — see CallingApi+PreNegotiation extension.

    /// Tell the caller we received their call_offer and are setting up PQC.
    func sendCallProcessing(callId: String, callerId: String) async throws

    /// Tell the caller we finished setup and are now ringing locally.
    func sendCallReady(callId: String, callerId: String) async throws
}

public extension CallingApi {
    func sendCallProcessing(callId: String, callerId: String) async throws { /* no-op default */ }
    func sendCallReady(callId: String, callerId: String) async throws { /* no-op default */ }
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

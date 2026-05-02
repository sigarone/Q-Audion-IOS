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

/// Bcrypto-server `/api/v1/calling/relays` response shape.
/// Mirrors Android `RelayDto` / `RelaysResponse`:
/// - `username` and `credential` are **optional** (STUN-only relays omit
///   them); previous iOS revs declared them non-optional, which made the
///   JSON decoder reject any STUN-only entry with `keyNotFound`.
/// - `wssTurnUrl` / `onionAddress` are top-level fields used by the
///   transport selector for the WS-TURN and Tor onion fallbacks.
public struct RelayServer: Codable, Equatable {
    public let urls: [String]
    public let username: String?
    public let credential: String?
    public let ttl: Int

    public init(urls: [String], username: String? = nil, credential: String? = nil, ttl: Int = 3600) {
        self.urls = urls
        self.username = username
        self.credential = credential
        self.ttl = ttl
    }

    /// Tolerant init: Android may serialize `ttl` as `ttlSeconds` /
    /// `ttl_seconds`. Try both shapes and fall back to a sane default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.urls = try c.decodeIfPresent([String].self, forKey: .urls) ?? []
        self.username = try c.decodeIfPresent(String.self, forKey: .username)
        self.credential = try c.decodeIfPresent(String.self, forKey: .credential)
        let ttl = try c.decodeIfPresent(Int.self, forKey: .ttl)
            ?? c.decodeIfPresent(Int.self, forKey: .ttlSeconds)
            ?? c.decodeIfPresent(Int.self, forKey: .ttl_seconds)
            ?? 3600
        self.ttl = ttl
    }

    private enum CodingKeys: String, CodingKey {
        case urls, username, credential, ttl
        case ttlSeconds, ttl_seconds
    }
}

public struct RelayResponse: Codable, Equatable {
    public let relays: [RelayServer]
    public let wssTurnUrl: String?
    public let onionAddress: String?

    public init(relays: [RelayServer], wssTurnUrl: String? = nil, onionAddress: String? = nil) {
        self.relays = relays
        self.wssTurnUrl = wssTurnUrl
        self.onionAddress = onionAddress
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.relays = try c.decodeIfPresent([RelayServer].self, forKey: .relays) ?? []
        self.wssTurnUrl = try c.decodeIfPresent(String.self, forKey: .wssTurnUrl)
            ?? c.decodeIfPresent(String.self, forKey: .wss_turn_url)
        self.onionAddress = try c.decodeIfPresent(String.self, forKey: .onionAddress)
            ?? c.decodeIfPresent(String.self, forKey: .onion_address)
    }

    private enum CodingKeys: String, CodingKey {
        case relays
        case wssTurnUrl, wss_turn_url
        case onionAddress, onion_address
    }
}

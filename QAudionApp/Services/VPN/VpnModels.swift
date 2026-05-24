// VpnModels.swift — Q-Audion iOS
//
// Mirror of Android `VpnModels.kt`. All field names use the server's
// snake_case JSON keys via CodingKeys so no custom CodingKey enum is needed.

import Foundation

// MARK: - Server API responses

/// A VPN node returned by GET /api/v1/vpn/nodes.
struct VpnNode: Codable, Identifiable, Hashable {
    let id: String
    let country: String
    let city: String
    let lat: Double
    let lon: Double
    /// WireGuard endpoint "host:port" (also the primary connect address).
    let quicAddr: String
    let wsAddr: String
    let loadPct: Double
    let pingMs: Int

    enum CodingKeys: String, CodingKey {
        case id, country, city, lat, lon
        case quicAddr = "quic_addr"
        case wsAddr   = "ws_addr"
        case loadPct  = "load_pct"
        case pingMs   = "ping_ms"
    }

    static let pingUnknown = 999
}

/// Response from POST /api/v1/vpn/token.
struct VpnTokenResponse: Codable {
    let token: String
    let expiresAt: String
    let jti: String

    enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
        case jti
    }
}

/// Response from POST /api/v1/vpn/wg-register.
struct WgConfigResponse: Codable {
    let serverPubkey: String
    let serverEndpoint: String
    let assignedIp4: String
    /// Empty string when server doesn't assign IPv6.
    let assignedIp6: String
    /// Preshared key for PQC-hybrid. NEVER log.
    let psk: String
    let dns: [String]
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case serverPubkey   = "server_pubkey"
        case serverEndpoint = "server_endpoint"
        case assignedIp4    = "assigned_ip4"
        case assignedIp6    = "assigned_ip6"
        case psk, dns
        case expiresAt      = "expires_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serverPubkey    = try c.decode(String.self, forKey: .serverPubkey)
        serverEndpoint  = try c.decode(String.self, forKey: .serverEndpoint)
        assignedIp4     = try c.decode(String.self, forKey: .assignedIp4)
        // Default to empty string when server omits the IPv6 field.
        assignedIp6     = (try? c.decode(String.self, forKey: .assignedIp6)) ?? ""
        psk             = try c.decode(String.self, forKey: .psk)
        dns             = try c.decode([String].self, forKey: .dns)
        expiresAt       = try c.decode(String.self, forKey: .expiresAt)
    }
}

// MARK: - App-internal state

/// Observable VPN connection state — matches Android's sealed `VpnState`.
enum VpnState: Equatable {
    case disconnected
    case connecting(nodeId: String)
    case connected(node: VpnNode, assignedIp: String)
    case error(message: String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }

    var statusLabel: String {
        switch self {
        case .disconnected:          return "VPN"
        case .connecting:            return "Connessione…"
        case .connected(let n, _):   return "VPN · \(n.city)"
        case .error:                 return "Errore VPN"
        }
    }
}

// MARK: - WireGuard helpers

/// Keys used in `NETunnelProviderProtocol.providerConfiguration` to pass the
/// WireGuard config from the main app to the `PacketTunnelProvider` extension.
/// Keys used in `NETunnelProviderProtocol.providerConfiguration` to pass the
/// WireGuard parameters from the main app to the `PacketTunnelProvider` extension.
///
/// Values are individual strings (not a wg-quick blob) so `PacketTunnelProvider`
/// can build `TunnelConfiguration` using the public WireGuardKit API
/// (`TunnelConfiguration.init(name:interface:peers:)`) without needing the
/// private wg-quick parser that is not in the SPM target.
///
/// NOTE: The same key strings are hardcoded in `PacketTunnelProvider.swift`
/// (the extension cannot import files from the main app target).
enum WgProviderKey {
    static let privateKeyB64    = "wg_private_key_b64"    // client private key (base64)
    static let serverPubKeyB64  = "wg_server_pub_key_b64" // server public key (base64)
    static let pskB64           = "wg_psk_b64"            // pre-shared key (base64, may be "")
    static let clientAddresses  = "wg_client_addresses"   // "10.x.x.x/32[,fd00::1/128]"
    static let serverEndpoint   = "wg_server_endpoint"    // "host:port"
    static let dns              = "wg_dns"                // "1.1.1.1,9.9.9.9"
    static let serverCity       = "server_city"           // human-readable city name
}

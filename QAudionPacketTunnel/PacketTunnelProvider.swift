// PacketTunnelProvider.swift — QAudionPacketTunnel extension
//
// This file lives in the QAudionPacketTunnel app extension target.
// It is a separate process launched by iOS's VPN subsystem.
//
// Dependency: WireGuardKit (sigarone/wireguard-apple fork, Xcode 26 compatible)
//
// What this does:
//   1. Reads individual WireGuard parameters from providerConfiguration.
//   2. Builds a TunnelConfiguration using the public WireGuardKit API.
//   3. Starts WireGuardAdapter (which manages the actual WireGuard tunnel).
//   4. Calls completionHandler() to tell iOS the tunnel is up.
//
// NOTE: providerConfiguration keys are kept in sync with WgProviderKey in
//   QAudionApp/Services/VPN/VpnModels.swift (cannot share — different targets).

import NetworkExtension
import WireGuardKit
import os.log

private let log = Logger(subsystem: "com.qaudion.app.packet-tunnel", category: "tunnel")

// Mirrors WgProviderKey in VpnModels.swift (main app target — not importable here).
private enum ProviderKey {
    static let privateKeyB64    = "wg_private_key_b64"
    static let serverPubKeyB64  = "wg_server_pub_key_b64"
    static let pskB64           = "wg_psk_b64"
    static let clientAddresses  = "wg_client_addresses"
    static let serverEndpoint   = "wg_server_endpoint"
    static let dns              = "wg_dns"
    static let serverCity       = "server_city"
}

final class PacketTunnelProvider: NEPacketTunnelProvider {

    private var adapter: WireGuardAdapter?

    // MARK: - NEPacketTunnelProvider

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        // Read the individual WireGuard parameters written by VpnService.startTunnel().
        guard
            let proto = protocolConfiguration as? NETunnelProviderProtocol,
            let provConf = proto.providerConfiguration,
            let privKeyB64 = provConf[ProviderKey.privateKeyB64] as? String,
            let serverPubKeyB64 = provConf[ProviderKey.serverPubKeyB64] as? String,
            let clientAddressesStr = provConf[ProviderKey.clientAddresses] as? String,
            let serverEndpointStr = provConf[ProviderKey.serverEndpoint] as? String
        else {
            log.error("Missing required WireGuard parameters in providerConfiguration")
            completionHandler(TunnelError.missingConfig)
            return
        }

        let pskB64       = provConf[ProviderKey.pskB64] as? String ?? ""
        let city         = provConf[ProviderKey.serverCity] as? String ?? "VPN"
        let dnsStr       = provConf[ProviderKey.dns] as? String ?? "1.1.1.1,9.9.9.9"

        log.info("Starting WireGuard tunnel -> \(city, privacy: .public)")

        // Validate keys.
        guard
            let privateKey = PrivateKey(base64Key: privKeyB64),
            let serverPubKey = PublicKey(base64Key: serverPubKeyB64)
        else {
            log.error("Invalid WireGuard key material")
            completionHandler(TunnelError.badConfig("Invalid key material"))
            return
        }

        // Build InterfaceConfiguration (client side).
        var iface = InterfaceConfiguration(privateKey: privateKey)
        iface.addresses = clientAddressesStr
            .split(separator: ",")
            .compactMap { IPAddressRange(from: String($0).trimmingCharacters(in: .whitespaces)) }
        iface.dns = dnsStr
            .split(separator: ",")
            .compactMap { DNSServer(from: String($0).trimmingCharacters(in: .whitespaces)) }

        // Build PeerConfiguration (server side).
        var peer = PeerConfiguration(publicKey: serverPubKey)
        if !pskB64.isEmpty, let psk = PreSharedKey(base64Key: pskB64) {
            peer.preSharedKey = psk
        }
        peer.allowedIPs = [
            IPAddressRange(from: "0.0.0.0/0")!,
            IPAddressRange(from: "::/0")!,
        ]
        peer.endpoint = Endpoint(from: serverEndpointStr)
        peer.persistentKeepAlive = 25

        let tunnelConfig = TunnelConfiguration(name: city, interface: iface, peers: [peer])

        // Start WireGuard adapter.
        let wgAdapter = WireGuardAdapter(with: self) { logLevel, message in
            switch logLevel {
            case .verbose: log.debug("\(message, privacy: .public)")
            case .error:   log.error("\(message, privacy: .public)")
            }
        }
        self.adapter = wgAdapter

        wgAdapter.start(tunnelConfiguration: tunnelConfig) { err in
            if let err {
                log.error("WireGuardAdapter.start failed: \(err, privacy: .public)")
                completionHandler(err)
            } else {
                log.info("WireGuard tunnel up (\(city, privacy: .public))")
                completionHandler(nil)
            }
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        log.info("Stopping tunnel (reason \(reason.rawValue))")
        adapter?.stop { [weak self] err in
            if let err {
                log.error("WireGuardAdapter.stop error: \(err, privacy: .public)")
            }
            self?.adapter = nil
            completionHandler()
        }
    }

    // MARK: - Error types

    private enum TunnelError: LocalizedError {
        case missingConfig
        case badConfig(String)

        var errorDescription: String? {
            switch self {
            case .missingConfig:      return "Missing WireGuard configuration"
            case .badConfig(let msg): return "Bad WireGuard config: \(msg)"
            }
        }
    }
}

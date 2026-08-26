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

    /// The live call-media host currently punched out of the tunnel (nil = no
    /// active call gate, full `0.0.0.0/0`/`::/0` tunnel as before this
    /// feature). See `handleAppMessage` — set from `VpnService.setCallMediaHost`
    /// via the ICE selected-candidate-pair remote host, and cleared on call end.
    private var currentExcludedHost: String?

    // MARK: - NEPacketTunnelProvider

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let iface: InterfaceConfiguration
        let peer: PeerConfiguration
        let city: String
        do {
            (iface, peer, city) = try buildConfig()
        } catch {
            completionHandler(error)
            return
        }

        log.info("Starting WireGuard tunnel -> \(city, privacy: .public)")

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

    /// Builds (interface, peer, city) from `providerConfiguration` — the
    /// SAME parsing `startTunnel` originally did inline, pulled out so
    /// `handleAppMessage` can rebuild an identical peer (modulo `allowedIPs`)
    /// on every call-gate update without duplicating the key/address
    /// validation logic.
    private func buildConfig() throws -> (iface: InterfaceConfiguration, peer: PeerConfiguration, city: String) {
        guard
            let proto = protocolConfiguration as? NETunnelProviderProtocol,
            let provConf = proto.providerConfiguration,
            let privKeyB64 = provConf[ProviderKey.privateKeyB64] as? String,
            let serverPubKeyB64 = provConf[ProviderKey.serverPubKeyB64] as? String,
            let clientAddressesStr = provConf[ProviderKey.clientAddresses] as? String,
            let serverEndpointStr = provConf[ProviderKey.serverEndpoint] as? String
        else {
            log.error("Missing required WireGuard parameters in providerConfiguration")
            throw TunnelError.missingConfig
        }

        let pskB64 = provConf[ProviderKey.pskB64] as? String ?? ""
        let city   = provConf[ProviderKey.serverCity] as? String ?? "VPN"
        let dnsStr = provConf[ProviderKey.dns] as? String ?? "1.1.1.1,9.9.9.9"

        guard
            let privateKey = PrivateKey(base64Key: privKeyB64),
            let serverPubKey = PublicKey(base64Key: serverPubKeyB64)
        else {
            log.error("Invalid WireGuard key material")
            throw TunnelError.badConfig("Invalid key material")
        }

        var iface = InterfaceConfiguration(privateKey: privateKey)
        iface.addresses = clientAddressesStr
            .split(separator: ",")
            .compactMap { IPAddressRange(from: String($0).trimmingCharacters(in: .whitespaces)) }
        iface.dns = dnsStr
            .split(separator: ",")
            .compactMap { DNSServer(from: String($0).trimmingCharacters(in: .whitespaces)) }

        var peer = PeerConfiguration(publicKey: serverPubKey)
        if !pskB64.isEmpty, let psk = PreSharedKey(base64Key: pskB64) {
            peer.preSharedKey = psk
        }
        peer.allowedIPs = allowedIPs(excludingHost: currentExcludedHost)
        peer.endpoint = Endpoint(from: serverEndpointStr)
        peer.persistentKeepAlive = 25

        return (iface, peer, city)
    }

    /// Full-tunnel `allowedIPs` (`0.0.0.0/0` + `::/0`), minus `excludedHost`
    /// when one is set — see `CidrExclusion` for why this punch-hole approach
    /// is what WireGuard's model actually supports (no native "exclude"
    /// primitive). Only ever punches the IPv4 block: every real call-media
    /// host observed in this project is IPv4 (checked this session — the
    /// relay fleet, TURN bridge, and every live-verified ICE candidate pair
    /// so far are all v4); an IPv6 call-media host would currently stay
    /// tunneled, same as before this feature existed — disclosed gap, not
    /// silently assumed away.
    private func allowedIPs(excludingHost host: String?) -> [IPAddressRange] {
        let ipv6 = IPAddressRange(from: "::/0")!
        guard let host, host.contains(".") else {
            return [IPAddressRange(from: "0.0.0.0/0")!, ipv6]
        }
        let punchedIPv4 = CidrExclusion.excludingHost(from: "0.0.0.0/0", excludedHost: host)
            .compactMap { IPAddressRange(from: $0) }
        guard !punchedIPv4.isEmpty else {
            // Punch failed (bad/unparseable host) — safe fallback: full tunnel.
            return [IPAddressRange(from: "0.0.0.0/0")!, ipv6]
        }
        return punchedIPv4 + [ipv6]
    }

    /// IPC from `VpnService` (main app process) — the only channel available
    /// to reach this extension's separate process. Message body is a UTF-8
    /// JSON object `{"excludedHost": "<ipv4>"}` to set/replace the current
    /// call-media exclusion, or `{}` (no `excludedHost` key) to clear it.
    /// Rebuilds the peer config with the new `allowedIPs` and pushes it via
    /// `WireGuardAdapter.update(tunnelConfiguration:)` — WireGuardKit's own
    /// public live-update API (confirmed at the pinned revision: it
    /// regenerates `NEPacketTunnelNetworkSettings` from the new config and
    /// re-applies via `setTunnelNetworkSettings`, the same call `startTunnel`
    /// uses — not a private/undocumented path).
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        // Explicit do/catch rather than a chained `try? ... as? ...` one-liner:
        // `try?` combined with a trailing `as?` cast on a throwing `Any`-
        // returning call is a documented source of double-optional
        // confusion across Swift versions, and this box has no local
        // toolchain to compile-check which behavior applies here — spelling
        // it out avoids relying on that.
        var newHost: String?
        do {
            let obj = try JSONSerialization.jsonObject(with: messageData, options: [])
            newHost = (obj as? [String: String])?["excludedHost"]
        } catch {
            log.error("handleAppMessage: bad JSON payload: \(error, privacy: .public)")
            completionHandler?(nil)
            return
        }

        guard newHost != currentExcludedHost else {
            completionHandler?(nil)
            return
        }
        currentExcludedHost = newHost

        guard let adapter else {
            completionHandler?(nil)
            return
        }
        let iface: InterfaceConfiguration
        let peer: PeerConfiguration
        let city: String
        do {
            (iface, peer, city) = try buildConfig()
        } catch {
            log.error("handleAppMessage: buildConfig failed: \(error, privacy: .public)")
            completionHandler?(nil)
            return
        }
        let tunnelConfig = TunnelConfiguration(name: city, interface: iface, peers: [peer])
        adapter.update(tunnelConfiguration: tunnelConfig) { err in
            if let err {
                log.error("call-gate update failed: \(err, privacy: .public)")
            } else {
                log.info("call-gate updated, excludedHost=\(newHost ?? "none", privacy: .public)")
            }
            completionHandler?(nil)
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

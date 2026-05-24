// PacketTunnelProvider.swift — QAudionPacketTunnel extension
//
// This file lives in the QAudionPacketTunnel app extension target.
// It is a separate process launched by iOS's VPN subsystem.
//
// Dependency: WireGuardKit (from https://github.com/WireGuard/wireguard-apple)
// Link this target against WireGuardKit in Xcode.
//
// What this does:
//   1. Reads the wg-quick config string from providerConfiguration.
//   2. Builds a WireGuardKit TunnelConfiguration from it.
//   3. Starts WireGuardAdapter (which manages the actual WireGuard tunnel).
//   4. Calls completionHandler() to tell iOS the tunnel is up.

import NetworkExtension
import WireGuardKit
import os.log

private let log = Logger(subsystem: "com.bcrypto.qaudion.packet-tunnel", category: "tunnel")

final class PacketTunnelProvider: NEPacketTunnelProvider {

    private var adapter: WireGuardAdapter?

    // MARK: - NEPacketTunnelProvider

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        // Read the wg-quick config written by VpnService.startTunnel().
        guard
            let proto = protocolConfiguration as? NETunnelProviderProtocol,
            let provConf = proto.providerConfiguration,
            let wgQuickConf = provConf["wg_config"] as? String
        else {
            log.error("Missing wg_config in providerConfiguration")
            completionHandler(TunnelError.missingConfig)
            return
        }

        let city = (provConf["server_city"] as? String) ?? "VPN"
        log.info("Starting WireGuard tunnel → \(city, privacy: .public)")

        // Parse the wg-quick config string into WireGuardKit types.
        let parseResult = TunnelConfiguration.from(wgQuickString: wgQuickConf, name: "Q-Audion VPN")
        switch parseResult {
        case .failure(let err):
            log.error("WireGuard config parse failed: \(err, privacy: .public)")
            completionHandler(TunnelError.badConfig(err.localizedDescription))
            return

        case .success(let tunnelConfig):
            let wgAdapter = WireGuardAdapter(with: self) { [weak self] logLevel, message in
                switch logLevel {
                case .verbose: self.map { _ in log.debug("\(message, privacy: .public)") }
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

// VpnService.swift — Q-Audion iOS
//
// Manages the WireGuard VPN tunnel on iOS via NetworkExtension.
//
// Architecture:
//   Main app (this file) ←→ QAudionPacketTunnel extension (NEPacketTunnelProvider)
//
// The main app configures and starts the tunnel via NETunnelProviderManager.
// The actual packet-level work runs inside QAudionPacketTunnel, which is a
// separate process launched by the OS. They communicate through:
//   - providerConfiguration (NETunnelProviderProtocol) for initial WG config
//   - NEVPNStatus KVO for status updates back to the main app
//
// Connect flow (mirrors Android VpnViewModel.connect()):
//   1. POST /vpn/token       — obtain short-lived VPN sub-token
//   2. Generate WG key pair  — CryptoKit P256? No — WireGuard uses Curve25519.
//                              We generate via Security framework (SecRandomCopyBytes).
//   3. POST /vpn/wg-register — register WG public key, receive server config
//   4. Build wg-quick config string and store in NETunnelProviderProtocol
//   5. Start the tunnel (NEVPNStatus transitions to .connected)
//
// WireGuard keypair: Curve25519 (X25519). iOS CryptoKit doesn't expose raw
// X25519 key generation in the wg-compatible format. We use SecRandomCopyBytes
// for 32 bytes of random, then clamp as per RFC 7748 §5 before deriving the
// public key with the WireGuard go-library approach.
// NOTE: If WireGuardKit is linked, use WireGuardKit.PrivateKey() for this.

import Foundation
@preconcurrency import NetworkExtension
import CryptoKit // for SHA256/random bytes only
import QAudionEngine // VpnMlKem — ephemeral ML-KEM-1024 PSK handshake

/// App Group ID shared between the main app and the VPN extension.
/// Both targets must declare this in their entitlements.
let kVpnAppGroup = "group.com.bcrypto.qaudion.vpn"

/// Bundle ID of the QAudionPacketTunnel extension.
/// Must be prefixed with the parent app's bundle ID (com.qaudion.app)
/// per Apple's embedded-extension naming requirement.
let kVpnExtensionBundleId = "com.qaudion.app.packet-tunnel"

@MainActor
final class VpnService: ObservableObject {

    // MARK: - Public state

    @Published private(set) var state: VpnState = .disconnected

    // MARK: - Private

    private let api = VpnApiService()
    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    // MARK: - Init / deinit

    init() {
        Task { await loadManager() }
    }

    deinit {
        if let obs = statusObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - Public API

    /// Fetches the list of available VPN nodes.
    ///
    /// Convenience wrapper over `VpnApiService.getNodes` so external callers
    /// (e.g. `VpnToggleChip`) don't need their own `VpnApiService` instance
    /// and the associated URLSession allocation.
    ///
    /// - Parameter accessToken: The user's current session access token.
    func fetchNodes(accessToken: String) async throws -> [VpnNode] {
        try await api.getNodes(accessToken: accessToken)
    }

    /// Connect to the given VPN node.
    ///
    /// - Parameters:
    ///   - node: Target VPN node (from `VpnApiService.getNodes`).
    ///   - accessToken: The user's current session access token.
    func connect(to node: VpnNode, accessToken: String) async {
        guard !state.isConnected && !state.isConnecting else { return }
        state = .connecting(nodeId: node.id)
        do {
            // Step 1 — VPN sub-token (used for server-side session binding).
            _ = try await api.getToken(accessToken: accessToken)

            // Step 2 — WireGuard key pair.
            let (privateKeyB64, publicKeyB64) = try generateWgKeyPair()

            // Step 2b — Ephemeral ML-KEM-1024 keypair for the PQC-hybrid PSK.
            // Only offered when liboqs in this build actually has ML-KEM-1024
            // (VpnMlKem.isSupported). When unsupported we send no mlkem_pubkey;
            // the server omits mlkem_ciphertext and we use the classical psk —
            // exactly the documented fallback. Generated fresh per connection;
            // never the device's long-term ML-KEM-1024 identity key.
            var mlkemSecretKey: Data?
            var mlkemPubkeyB64: String?
            if VpnMlKem.isSupported {
                let mlkemPair = try VpnMlKem.generateKeyPair()
                mlkemSecretKey = mlkemPair.secretKey
                mlkemPubkeyB64 = mlkemPair.publicKey.base64EncodedString()
            }

            // Step 3 — Register WG peer; receive server config.
            let wgConfig = try await api.registerWgPeer(
                accessToken: accessToken,
                clientPubkey: publicKeyB64,
                nodeId: node.id,
                mlkemPubkey: mlkemPubkeyB64
            )

            // Step 3b — Resolve the WireGuard PSK.
            // If the server returned an ML-KEM ciphertext, decapsulate it with
            // our ephemeral secret key and derive the PSK via HKDF — this PQC
            // PSK SUPERSEDES wgConfig.psk. A decapsulation failure here is FATAL
            // (the server committed to PQC): we throw rather than silently
            // dropping to the classical psk. If no ciphertext is present, use
            // the classical psk unchanged.
            let resolvedPskB64 = try resolveWgPsk(
                wgConfig: wgConfig,
                mlkemSecretKey: mlkemSecretKey
            )

            // Step 4 — Pass raw crypto params to the extension.
            try await startTunnel(
                node: node,
                privateKeyB64: privateKeyB64,
                pskB64: resolvedPskB64,
                wgConfig: wgConfig
            )

            // State transitions to .connected when NEVPNStatus fires.
            // Store node so the status handler can set it.
            pendingConnectedNode = node
            pendingAssignedIp = wgConfig.assignedIp4
                .components(separatedBy: "/").first ?? wgConfig.assignedIp4

        } catch {
            // W497 — log the full error so it surfaces in the live telemetry feed.
            // Before this, the error was silently swallowed and the chip showed
            // only "Errore VPN" with no actionable detail.
            print("[VpnService] connect failed: \(error.localizedDescription)")
            state = .error(message: error.localizedDescription)
        }
    }

    /// Disconnect the active tunnel.
    func disconnect() {
        manager?.connection.stopVPNTunnel()
        state = .disconnected
        lastSentExcludedHost = nil
    }

    /// Call-media VPN gate (mirrors Android's `07c517b9a` `CallController`-state
    /// gate — see `QAudionPacketTunnel/PacketTunnelProvider.swift`'s
    /// `handleAppMessage` kdoc for the full mechanism and why iOS needs a
    /// destination-based punch instead of Android's per-app exclusion).
    ///
    /// - Parameter host: the active call's resolved media destination (the
    ///   selected ICE candidate pair's remote IPv4 address — set once ICE
    ///   settles, mirrors `QAudionWebRtcCallController.onActiveCandidatePairRemoteHost`),
    ///   or `nil` to clear the gate (call ended, or ICE has no resolved pair
    ///   yet). A no-op when the VPN tunnel isn't connected — nothing to
    ///   exclude from a tunnel that isn't routing anything — and a no-op when
    ///   `host` hasn't actually changed since the last call, so a call that
    ///   re-polls the same settled pair doesn't re-trigger the extension IPC
    ///   + WireGuard config reload on every stats tick.
    func setCallMediaHost(_ host: String?) {
        guard state.isConnected else { return }
        guard host != lastSentExcludedHost else { return }
        lastSentExcludedHost = host

        guard let session = manager?.connection as? NETunnelProviderSession else { return }
        let body: [String: String] = host.map { ["excludedHost": $0] } ?? [:]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return }
        do {
            try session.sendProviderMessage(payload) { _ in }
        } catch {
            print("[VpnService] setCallMediaHost sendProviderMessage failed: \(error.localizedDescription)")
        }
    }

    /// De-dupes `setCallMediaHost` calls — see that method's kdoc.
    private var lastSentExcludedHost: String?

    // MARK: - Private helpers

    private var pendingConnectedNode: VpnNode?
    private var pendingAssignedIp: String = ""

    /// Loads (or creates) the NETunnelProviderManager for our VPN configuration.
    private func loadManager() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            let mgr = managers.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == kVpnExtensionBundleId
            }) ?? NETunnelProviderManager()
            self.manager = mgr
            subscribeToStatus(connection: mgr.connection)
        } catch {
            print("[VpnService] loadAllFromPreferences failed: \(error)")
        }
    }

    /// Configures and starts the NETunnelProviderManager.
    ///
    /// Stores individual WireGuard parameters in `providerConfiguration` so the
    /// `PacketTunnelProvider` extension can build a `TunnelConfiguration` using
    /// the public WireGuardKit API without the private wg-quick string parser.
    private func startTunnel(node: VpnNode, privateKeyB64: String, pskB64: String, wgConfig: WgConfigResponse) async throws {
        guard let mgr = manager else { throw NSError(domain: "VpnService", code: -1) }

        let ip4Bare = wgConfig.assignedIp4.components(separatedBy: "/").first ?? wgConfig.assignedIp4
        let ip6Bare = wgConfig.assignedIp6.components(separatedBy: "/").first ?? wgConfig.assignedIp6

        var clientAddresses = "\(ip4Bare)/32"
        if !ip6Bare.isEmpty { clientAddresses += ",\(ip6Bare)/128" }

        let dnsServers = wgConfig.dns.isEmpty ? ["1.1.1.1", "9.9.9.9"] : wgConfig.dns

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = kVpnExtensionBundleId
        proto.serverAddress = node.quicAddr // shown in iOS VPN Settings
        proto.providerConfiguration = [
            WgProviderKey.privateKeyB64:   privateKeyB64,
            WgProviderKey.serverPubKeyB64: wgConfig.serverPubkey,
            // Resolved PSK: the HKDF-derived ML-KEM-1024 PSK when the server did
            // PQC, otherwise the classical wgConfig.psk.
            WgProviderKey.pskB64:          pskB64,
            WgProviderKey.clientAddresses: clientAddresses,
            WgProviderKey.serverEndpoint:  wgConfig.serverEndpoint,
            WgProviderKey.dns:             dnsServers.joined(separator: ","),
            WgProviderKey.serverCity:      node.city,
        ]

        mgr.protocolConfiguration = proto
        mgr.localizedDescription = "Q-Audion VPN · \(node.city)"
        mgr.isEnabled = true

        try await mgr.saveToPreferences()
        try await mgr.loadFromPreferences()
        // loadFromPreferences() replaces mgr.connection with a fresh object, so the
        // observer registered in loadManager() (bound to the OLD connection via
        // `object:`) would never fire for this tunnel — leaving `state` stuck at
        // .connecting and the status badge grey for every node. Re-subscribe to the
        // new connection before starting so NEVPNStatusDidChange actually reaches us.
        subscribeToStatus(connection: mgr.connection)
        try (mgr.connection as? NETunnelProviderSession)?
            .startTunnel(options: nil)
    }

    /// Subscribes to NEVPNStatus notifications on the given connection.
    private func subscribeToStatus(connection: NEVPNConnection) {
        if let existing = statusObserver {
            NotificationCenter.default.removeObserver(existing)
        }
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: connection,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleStatusChange(connection: connection)
            }
        }
    }

    private func handleStatusChange(connection: NEVPNConnection) {
        switch connection.status {
        case .connected:
            if let node = pendingConnectedNode {
                state = .connected(node: node, assignedIp: pendingAssignedIp)
                pendingConnectedNode = nil
            }
        case .disconnected:
            // Only flip to .disconnected if we were actually connected/connecting.
            // Avoids clobbering an .error state set before the extension shut down.
            if state.isConnected || state.isConnecting {
                state = .disconnected
            }
        case .disconnecting:
            break // intermediate — wait for .disconnected
        case .connecting, .reasserting:
            break // already set to .connecting in connect()
        case .invalid:
            state = .error(message: "Configurazione VPN non valida")
        @unknown default:
            break
        }
    }

    // MARK: - PQC PSK resolution

    /// Resolves the base64 WireGuard PSK from the server response.
    ///
    /// - If the server returned `mlkem_ciphertext`, decapsulate it with our
    ///   ephemeral ML-KEM-1024 secret key and derive the PSK via HKDF-SHA256.
    ///   This PQC-derived PSK SUPERSEDES `wgConfig.psk`.
    /// - Otherwise return `wgConfig.psk` unchanged (classical / old-server path).
    ///
    /// FATAL-on-failure semantics: when a ciphertext is present the handshake
    /// is committed to PQC, so any decode/decapsulation problem throws. We never
    /// silently fall back to the classical PSK once the server has answered with
    /// a ciphertext — doing so would mask a key-agreement failure and produce a
    /// PSK mismatch the tunnel could never recover from.
    private func resolveWgPsk(
        wgConfig: WgConfigResponse,
        mlkemSecretKey: Data?
    ) throws -> String {
        guard let ciphertextB64 = wgConfig.mlkemCiphertext, !ciphertextB64.isEmpty else {
            // No PQC ciphertext → classical PSK, exactly as before.
            return wgConfig.psk
        }
        // Server committed to PQC. We MUST have a secret key and a valid
        // ciphertext; anything else is fatal (no classical fallback).
        guard let secretKey = mlkemSecretKey else {
            throw VpnError.pqcStateMismatch
        }
        guard let ciphertext = Data(base64Encoded: ciphertextB64) else {
            throw VpnError.invalidMlkemCiphertext
        }
        let psk = try VpnMlKem.derivePsk(ciphertext: ciphertext, secretKey: secretKey)
        return psk.base64EncodedString()
    }

    // MARK: - WireGuard X25519 keypair

    /// Generates a Curve25519 keypair compatible with WireGuard.
    ///
    /// WireGuard uses X25519 (RFC 7748). The private key is 32 random bytes
    /// with bits clamped per RFC 7748 §5. The public key is derived via
    /// the X25519 base-point multiplication, which we implement using
    /// CryptoKit's Curve25519 DH.
    private func generateWgKeyPair() throws -> (privateKeyB64: String, publicKeyB64: String) {
        // CryptoKit.Curve25519.KeyAgreement generates a proper X25519 keypair.
        let privKey = Curve25519.KeyAgreement.PrivateKey()
        let privData = privKey.rawRepresentation          // 32 bytes
        let pubData  = privKey.publicKey.rawRepresentation // 32 bytes
        return (
            privData.base64EncodedString(),
            pubData.base64EncodedString()
        )
    }
}

/// Errors specific to the VPN connect flow's PQC PSK handshake.
enum VpnError: LocalizedError {
    /// Server returned an ML-KEM ciphertext but the client has no ephemeral
    /// secret key for this connection (should be impossible — the pubkey is
    /// only sent when a keypair was generated). Treated as fatal.
    case pqcStateMismatch
    /// The `mlkem_ciphertext` field was not valid base64.
    case invalidMlkemCiphertext

    var errorDescription: String? {
        switch self {
        case .pqcStateMismatch:
            return "VPN PQC: ciphertext senza chiave ML-KEM locale"
        case .invalidMlkemCiphertext:
            return "VPN PQC: ciphertext ML-KEM non valido"
        }
    }
}

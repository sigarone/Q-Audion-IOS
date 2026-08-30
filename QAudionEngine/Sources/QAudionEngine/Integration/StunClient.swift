import Foundation
import Network
import os

/// Lightweight STUN client (RFC 5389) to discover the device's public IP and port
/// behind a NAT. Used by `IceAgent` to generate server-reflexive candidates for
/// P2P connection establishment.
public final class StunClient: @unchecked Sendable {

    // MARK: - Init

    /// The class is `public` but had no explicit initializer — the
    /// compiler-synthesized default init for a class is always `internal`
    /// regardless of the class's own access level, so any public-surface
    /// caller (e.g. `RelayLatencyProbe`'s default argument) needs this
    /// declared explicitly.
    public init() {}

    // MARK: - Public types

    public struct StunResult: Sendable {
        public let publicIP: String
        public let publicPort: UInt16
        public let natType: NatType
    }

    public enum NatType: String, Sendable {
        case openInternet    // No NAT, direct P2P possible
        case fullCone        // Easy P2P via STUN
        case restrictedCone  // P2P possible with hole punching
        case symmetric       // P2P difficult, need TURN relay
        case unknown
    }

    public enum StunError: Error {
        case connectionFailed
        case timeout
        case invalidResponse
        case noMappedAddress
    }

    // MARK: - Constants

    /// Default public STUN servers.
    public static let defaultServers = [
        "stun.l.google.com:19302",
        "stun1.l.google.com:19302",
        "stun.cloudflare.com:3478"
    ]

    private static let magicCookie: UInt32 = 0x2112A442
    private static let bindingRequest: UInt16 = 0x0001
    private static let bindingResponse: UInt16 = 0x0101
    private static let attrXorMappedAddress: UInt16 = 0x0020
    private static let attrMappedAddress: UInt16 = 0x0001
    private static let timeoutSeconds: TimeInterval = 5

    // MARK: - Public API

    /// Perform a STUN Binding Request to discover the public IP/port.
    public func discoverPublicEndpoint(
        server: String = "stun.l.google.com",
        port: UInt16 = 19302
    ) async throws -> StunResult {
        let request = buildBindingRequest()
        let responseData = try await sendUDP(data: request, host: server, port: port)
        guard let result = parseBindingResponse(responseData) else {
            throw StunError.noMappedAddress
        }
        return result
    }

    /// Try multiple STUN servers, returning the first successful result.
    public func discoverFromAnyServer() async -> StunResult? {
        for entry in Self.defaultServers {
            let parts = entry.split(separator: ":")
            let host = String(parts[0])
            let port = parts.count > 1 ? UInt16(parts[1]) ?? 3478 : 3478
            if let result = try? await discoverPublicEndpoint(server: host, port: port) {
                return result
            }
        }
        return nil
    }

    /// W-RELAYGEO (2026-08-26, best-practices audit item 5) — lightweight
    /// round-trip-latency probe for relay-list ordering
    /// (`RelayLatencyProbe`). Sends the SAME STUN Binding Request this
    /// client already builds for public-IP discovery and times the
    /// wall-clock gap until ANY UDP response arrives — deliberately looser
    /// than `discoverPublicEndpoint`, which additionally requires the reply
    /// to parse as a valid XOR-MAPPED-ADDRESS/MAPPED-ADDRESS. A relay/TURN
    /// server that answers a plain STUN Binding Request with something this
    /// client can't parse (e.g. a TURN-specific error response) still just
    /// answered — that round trip is a real, valid RTT sample for ordering
    /// purposes, even though it would (correctly) fail
    /// `discoverPublicEndpoint`'s stricter contract.
    ///
    /// Returns `nil` on any failure (timeout, connection error, unreachable
    /// host) — callers must treat `nil` as "no signal", not as "infinite
    /// latency" (see `RelayOrdering`).
    public func measureRttMs(
        host: String,
        port: UInt16,
        timeoutSec: TimeInterval
    ) async -> Double? {
        // W-STUNDUALSTACK — for a HOSTNAME, race one family-pinned socket
        // per family and take the first STUN reply; the loser is cancelled
        // by the group. On a healthy network the preferred family answers
        // first and the race costs one extra idle socket; on a broken-IPv6
        // network the v4 leg answers while the v6 leg is still timing out —
        // instead of the whole probe failing and W-RELAYGATE concluding the
        // network blocks UDP (and preferring the WSS-TURN bridge over a
        // relay that plain UDP reaches fine). An IP LITERAL names one
        // family already: single attempt, exactly as before.
        if Self.isIPLiteral(host) {
            return await singleProbeRttMs(host: host, port: port, timeoutSec: timeoutSec, ipVersion: .any)
        }
        return await withTaskGroup(of: Double?.self) { group in
            for version in [ProbeIPVersion.v6, .v4] {
                group.addTask {
                    await self.singleProbeRttMs(host: host, port: port, timeoutSec: timeoutSec, ipVersion: version)
                }
            }
            defer { group.cancelAll() }
            for await rtt in group where rtt != nil {
                return rtt
            }
            return nil
        }
    }

    private func singleProbeRttMs(
        host: String,
        port: UInt16,
        timeoutSec: TimeInterval,
        ipVersion: ProbeIPVersion
    ) async -> Double? {
        let request = buildBindingRequest()
        let start = DispatchTime.now()
        do {
            _ = try await sendUDP(data: request, host: host, port: port, timeoutSec: timeoutSec, ipVersion: ipVersion)
        } catch {
            return nil
        }
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        return Double(elapsedNs) / 1_000_000.0
    }

    /// W-STUNDUALSTACK — a bare IPv4 dotted quad or an IPv6 literal (any
    /// colon) already names its family; racing families for it is
    /// meaningless. Pure so it can be pinned by tests.
    static func isIPLiteral(_ host: String) -> Bool {
        if host.contains(":") { return true } // IPv6 literal (hostnames cannot contain ':')
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { UInt8($0) != nil }
    }

    // MARK: - STUN protocol

    /// Build a STUN Binding Request (20 bytes).
    /// Layout: type (2) + length (2) + magic cookie (4) + transaction ID (12).
    private func buildBindingRequest() -> Data {
        var data = Data(capacity: 20)

        // Message type: Binding Request 0x0001
        var type = Self.bindingRequest.bigEndian
        data.append(Data(bytes: &type, count: 2))

        // Message length: 0 (no attributes)
        var length: UInt16 = 0
        data.append(Data(bytes: &length, count: 2))

        // Magic cookie
        var cookie = Self.magicCookie.bigEndian
        data.append(Data(bytes: &cookie, count: 4))

        // Transaction ID: 12 random bytes
        var transactionID = Data(count: 12)
        // force-unwrap safe: transactionID is a fixed 12-byte buffer,
        // always non-empty — baseAddress nil only for an empty buffer.
        transactionID.withUnsafeMutableBytes { ptr in
            // swiftlint:disable:next force_unwrapping
            _ = SecRandomCopyBytes(kSecRandomDefault, 12, ptr.baseAddress!)
        }
        data.append(transactionID)

        return data
    }

    /// Parse a STUN Binding Response and extract XOR-MAPPED-ADDRESS.
    private func parseBindingResponse(_ data: Data) -> StunResult? {
        guard data.count >= 20 else { return nil }

        let responseType = UInt16(data[0]) << 8 | UInt16(data[1])
        guard responseType == Self.bindingResponse else { return nil }

        let bodyLength = Int(UInt16(data[2]) << 8 | UInt16(data[3]))
        guard data.count >= 20 + bodyLength else { return nil }

        // Walk attributes
        var offset = 20
        while offset + 4 <= data.count {
            let attrType = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
            let attrLength = Int(UInt16(data[offset + 2]) << 8 | UInt16(data[offset + 3]))
            let attrStart = offset + 4

            if attrType == Self.attrXorMappedAddress && attrLength >= 8 {
                return parseXorMappedAddress(data: data, offset: attrStart)
            }

            if attrType == Self.attrMappedAddress && attrLength >= 8 {
                return parseMappedAddress(data: data, offset: attrStart)
            }

            // Attributes are padded to 4-byte boundaries
            let padded = (attrLength + 3) & ~3
            offset = attrStart + padded
        }

        return nil
    }

    /// Parse XOR-MAPPED-ADDRESS: family (1) + port (2) + IP (4 for IPv4).
    /// Port is XORed with top 16 bits of magic cookie.
    /// IP is XORed with the full magic cookie.
    private func parseXorMappedAddress(data: Data, offset: Int) -> StunResult? {
        guard offset + 8 <= data.count else { return nil }

        let family = data[offset + 1]
        guard family == 0x01 else { return nil } // IPv4 only

        let xorPort = UInt16(data[offset + 2]) << 8 | UInt16(data[offset + 3])
        let port = xorPort ^ UInt16(Self.magicCookie >> 16)

        let xorIP0 = UInt32(data[offset + 4]) << 24
            | UInt32(data[offset + 5]) << 16
            | UInt32(data[offset + 6]) << 8
            | UInt32(data[offset + 7])
        let ip = xorIP0 ^ Self.magicCookie

        let ipString = "\(ip >> 24 & 0xFF).\(ip >> 16 & 0xFF).\(ip >> 8 & 0xFF).\(ip & 0xFF)"
        return StunResult(publicIP: ipString, publicPort: port, natType: .fullCone)
    }

    /// Parse plain MAPPED-ADDRESS (fallback for servers not sending XOR variant).
    private func parseMappedAddress(data: Data, offset: Int) -> StunResult? {
        guard offset + 8 <= data.count else { return nil }
        let family = data[offset + 1]
        guard family == 0x01 else { return nil }

        let port = UInt16(data[offset + 2]) << 8 | UInt16(data[offset + 3])
        let ipString = "\(data[offset + 4]).\(data[offset + 5]).\(data[offset + 6]).\(data[offset + 7])"
        return StunResult(publicIP: ipString, publicPort: port, natType: .fullCone)
    }

    // MARK: - UDP transport

    /// W-STUNDUALSTACK (2026-08-30) — which IP family a probe socket may
    /// use. UDP gets NO Happy Eyeballs from Network.framework (there is no
    /// handshake to race), so a probe to a dual-stack hostname silently
    /// binds one family — the wrong one on a network whose IPv6 route is
    /// advertised but black-holed, where the probe then times out against
    /// a server that answers on IPv4 in milliseconds. Same defect class
    /// Android fixed as W-DUALSTACKPROBE, one layer down: here the race
    /// has to be on the STUN reply, so the caller races two family-pinned
    /// sockets instead of trusting the resolver's first answer.
    enum ProbeIPVersion: Sendable {
        case any, v4, v6

        var nwVersion: NWProtocolIP.Options.Version? {
            switch self {
            case .any: return nil
            case .v4: return .v4
            case .v6: return .v6
            }
        }
    }

    private func sendUDP(
        data: Data,
        host: String,
        port: UInt16,
        timeoutSec: TimeInterval = StunClient.timeoutSeconds,
        ipVersion: ProbeIPVersion = .any
    ) async throws -> Data {
        // `port` ultimately traces back to `discoverPublicEndpoint`'s public
        // `port` parameter — today's only caller (`discoverFromAnyServer`)
        // always passes a fixed non-zero value, but nothing stops a future
        // caller of this public API from passing 0 (the only UInt16 value
        // NWEndpoint.Port(rawValue:) rejects), so fail closed instead of
        // force-unwrapping.
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw StunError.connectionFailed
        }
        return try await withCheckedThrowingContinuation { continuation in
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(host),
                port: nwPort
            )
            // W-STUNDUALSTACK — pin the socket's family when asked. `.udp`
            // is a fresh NWParameters instance each access, so mutating its
            // IP options here cannot leak into any other connection.
            let params: NWParameters = .udp
            if let pinned = ipVersion.nwVersion,
               let ipOpts = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ipOpts.version = pinned
            }
            let connection = NWConnection(to: endpoint, using: params)

            final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }
            let completedBox = Box(false)
            let lock = OSAllocatedUnfairLock<Void>(initialState: ())

            // Timeout — W-RELAYGEO: parameterized so `measureRttMs` can use
            // a much shorter budget than the 5s default public-IP-discovery
            // timeout (`Self.timeoutSeconds`, still this method's default).
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSec) {
                let didComplete: Bool = lock.withLock {
                    if !completedBox.value { completedBox.value = true; return true }
                    return false
                }
                guard didComplete else { return }
                connection.cancel()
                continuation.resume(throwing: StunError.timeout)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: data, completion: .contentProcessed { error in
                        if let error = error {
                            let didComplete: Bool = lock.withLock {
                                if !completedBox.value { completedBox.value = true; return true }
                                return false
                            }
                            guard didComplete else { return }
                            connection.cancel()
                            continuation.resume(throwing: error)
                            return
                        }
                        connection.receiveMessage { content, _, _, recvError in
                            let didComplete: Bool = lock.withLock {
                                if !completedBox.value { completedBox.value = true; return true }
                                return false
                            }
                            guard didComplete else { return }
                            connection.cancel()
                            if let content = content {
                                continuation.resume(returning: content)
                            } else {
                                continuation.resume(throwing: recvError ?? StunError.invalidResponse)
                            }
                        }
                    })
                case .failed(let error):
                    let didComplete: Bool = lock.withLock {
                        if !completedBox.value { completedBox.value = true; return true }
                        return false
                    }
                    guard didComplete else { return }
                    connection.cancel()
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }

            connection.start(queue: .global())
        }
    }
}

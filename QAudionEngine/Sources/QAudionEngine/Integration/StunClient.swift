import Foundation
import Network
import os

/// Lightweight STUN client (RFC 5389) to discover the device's public IP and port
/// behind a NAT. Used by `IceAgent` to generate server-reflexive candidates for
/// P2P connection establishment.
public final class StunClient: @unchecked Sendable {

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
        transactionID.withUnsafeMutableBytes { ptr in
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

    private func sendUDP(data: Data, host: String, port: UInt16) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!
            )
            let connection = NWConnection(to: endpoint, using: .udp)

            final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }
            let completedBox = Box(false)
            let lock = OSAllocatedUnfairLock<Void>(initialState: ())

            // Timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeoutSeconds) {
                var didComplete = false
                lock.withLock {
                    if !completedBox.value { completedBox.value = true; didComplete = true }
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
                            var didComplete = false
                            lock.withLock {
                                if !completedBox.value { completedBox.value = true; didComplete = true }
                            }
                            guard didComplete else { return }
                            connection.cancel()
                            continuation.resume(throwing: error)
                            return
                        }
                        connection.receiveMessage { content, _, _, recvError in
                            var didComplete = false
                            lock.withLock {
                                if !completedBox.value { completedBox.value = true; didComplete = true }
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
                    var didComplete = false
                    lock.withLock {
                        if !completedBox.value { completedBox.value = true; didComplete = true }
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

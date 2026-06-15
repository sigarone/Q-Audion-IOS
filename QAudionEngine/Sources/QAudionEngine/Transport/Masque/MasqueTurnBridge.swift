#if canImport(WebRTC)
import Darwin
import Foundation
import os

/// Loopback UDP ↔ MASQUE (HTTP/3 CONNECT-UDP) bridge for the TURN fallback.
///
/// Binds a loopback UDP socket and opens an RFC 9298 CONNECT-UDP tunnel to the
/// server's masque proxy, tunnelling to the TURN server. Bidirectionally
/// relays raw TURN frames between the loopback socket and the tunnel,
/// presenting libwebrtc with a standard
/// `turn:127.0.0.1:<port>?transport=udp` ICE server URL — no libwebrtc
/// patches required.
///
/// **Why this exists:** like `WssTurnBridge`, it gets TURN traffic through
/// networks that block UDP 3478 / TCP 3478 / TURNS 5349. Unlike WSS-TURN it
/// rides UDP-over-HTTP/3 (QUIC datagrams) instead of UDP-over-WebSocket-over-
/// TCP, avoiding TCP-over-TCP head-of-line blocking on the media path.
///
/// **Wire format:** each loopback UDP packet → one RFC 9298 HTTP Datagram
/// payload (`MasqueDatagramCodec`); the QUIC/H3 framing is the transport's job.
///
/// **Reply routing:** libwebrtc uses a single UDP socket for all outbound TURN
/// traffic, so we remember the source of the last packet it sent and route
/// inbound tunnel datagrams back there.
///
/// **Mirrors:** `WssTurnBridge` (this repo) and Android `CronetMasqueDriver`.
public final class MasqueTurnBridge: @unchecked Sendable {

    // MARK: - Types

    public struct BridgeResult {
        public let localPort: UInt16
        /// ICE candidate URL for `RTCIceServer(urlStrings:username:credential:)`.
        public var iceUrl: String { "turn:127.0.0.1:\(localPort)?transport=udp" }
    }

    public enum BridgeError: Error {
        case socketFailed(Int32)
        case bindFailed(Int32)
    }

    // MARK: - Init

    private let transport: MasqueDatagramTransport
    private let request: MasqueConnectUdpRequest

    public init(transport: MasqueDatagramTransport, request: MasqueConnectUdpRequest) {
        self.transport = transport
        self.request = request
    }

    deinit { stop() }

    // MARK: - State

    private var udpFD: Int32 = -1
    private let stateLock = NSLock()
    private var _running = false
    private var running: Bool {
        get { stateLock.withLock { _running } }
        set { stateLock.withLock { _running = newValue } }
    }

    // Last UDP source from libwebrtc — reply target for inbound tunnel datagrams.
    private var lastSrc: sockaddr_in?
    private let lastSrcLock = NSLock()

    private static let log = Logger(subsystem: "com.bcrypto.qaudion", category: "MasqueTurnBridge")

    // MARK: - Lifecycle

    /// Open the CONNECT-UDP tunnel, then bind the loopback socket and start
    /// relaying. Throws if the tunnel handshake or socket setup fails — the
    /// caller falls back to WSS-TURN / Tor.
    public func start() async throws -> BridgeResult {
        // 1. Establish the HTTP/3 CONNECT-UDP tunnel first; bail before
        //    touching sockets if the proxy rejects us.
        try await transport.connect(request)

        // 2. Bind loopback UDP socket on an ephemeral port.
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw BridgeError.socketFailed(errno) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let rc = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 {
            Darwin.close(fd)
            throw BridgeError.bindFailed(errno)
        }

        var bound = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &boundLen)
            }
        }
        let port = UInt16(bigEndian: bound.sin_port)
        udpFD = fd
        running = true

        // 3. Tunnel → UDP: deliver inbound datagrams to libwebrtc's last src.
        transport.onDatagram = { [weak self] payload in
            guard let self else { return }
            guard let udp = MasqueDatagramCodec.decode(payload) else { return }
            self.sendToLoopback(udp)
        }

        // 4. UDP → tunnel: blocking recvfrom on a dedicated OS thread (a Swift
        //    Task can't block on a syscall without starving the pool).
        let capturedFD = fd
        Thread.detachNewThread { [weak self] in self?.pumpUdpToTunnel(fd: capturedFD) }

        Self.log.info("start: 127.0.0.1:\(port) ↔ masque \(self.request.proxyAuthority) → \(self.request.targetHost):\(self.request.targetPort)")
        return BridgeResult(localPort: port)
    }

    public func stop() {
        guard running else { return }
        running = false
        transport.onDatagram = nil
        transport.close()
        let fd = udpFD
        if fd >= 0 { Darwin.close(fd); udpFD = -1 }
        Self.log.debug("stop: bridge torn down")
    }

    // MARK: - Relay pumps

    /// UDP → tunnel pump. Runs on a dedicated OS thread (`recvfrom` blocks).
    /// Exits when the fd closes (recvfrom ≤ 0) or `running` clears.
    private func pumpUdpToTunnel(fd: Int32) {
        let bufSize = 2048
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        var src = sockaddr_in()
        var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        while running {
            let n = withUnsafeMutablePointer(to: &src) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, buf, bufSize, 0, $0, &srcLen)
                }
            }
            if n <= 0 { break }
            lastSrcLock.withLock { lastSrc = src }
            let udp = Data(bytes: buf, count: n)
            transport.sendDatagram(MasqueDatagramCodec.encode(udpPayload: udp))
        }
    }

    /// Route an inbound (decoded) UDP payload back to libwebrtc's last source.
    /// Drops if no source is known yet (TURN is always client-initiated).
    private func sendToLoopback(_ udp: Data) {
        guard udpFD >= 0 else { return }
        guard let dst = lastSrcLock.withLock({ lastSrc }) else {
            Self.log.debug("drop tunnel datagram — no known libwebrtc src")
            return
        }
        let fd = udpFD
        udp.withUnsafeBytes { rawBuf in
            var d = dst
            _ = withUnsafeMutablePointer(to: &d) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, rawBuf.baseAddress, udp.count, 0, sa,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}
#endif

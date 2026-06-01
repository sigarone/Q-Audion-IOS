#if canImport(WebRTC)
import Darwin
import Foundation
import os

/// Loopback UDP ↔ WebSocket bridge for WSS-TURN fallback.
///
/// Binds a loopback UDP socket and opens a WebSocket to the server's
/// WSS-TURN proxy (`/api/v1/turn-ws`). Bidirectionally relays raw TURN
/// frames between them, presenting libwebrtc with a standard
/// `turn:127.0.0.1:<port>?transport=udp` ICE server URL — no libwebrtc
/// patches required.
///
/// **Why this exists:** libwebrtc speaks UDP/TCP/TLS to TURN; it has no
/// built-in WebSocket transport. Corporate firewalls that block UDP 3478,
/// TCP 3478, and TURNS 5349 will still allow WSS on port 443. This bridge
/// is the last-resort path that gets TURN traffic through those networks.
///
/// **Wire format:** binary WebSocket frames == raw TURN UDP packet bytes.
/// Subprotocol: `"turn"` (Sec-WebSocket-Protocol header).
/// Auth: `Authorization: Bearer <accessToken>` (server requires JWT).
///
/// **Reply routing:** libwebrtc always uses a single UDP socket for all
/// outbound TURN traffic, so we remember the source address of the last
/// packet libwebrtc sent us and route reply frames back there.
///
/// **Mirrors:**
///  - Android: `WssTurnBridge.kt` (OkHttp + POSIX UDP)
///  - Desktop: `WssTurnBridge.ts` (node `dgram` + `ws`)
public final class WssTurnBridge: @unchecked Sendable {

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

    private let wssUrl: URL
    private let username: String?
    private let credential: String?
    private let accessToken: String?

    public init(
        wssUrl: URL,
        username: String? = nil,
        credential: String? = nil,
        accessToken: String? = nil
    ) {
        self.wssUrl = wssUrl
        self.username = username
        self.credential = credential
        self.accessToken = accessToken
    }

    deinit { stop() }

    // MARK: - State

    private var udpFD: Int32 = -1
    private var wsTask: URLSessionWebSocketTask?
    private let stateLock = NSLock()
    private var _running = false
    private var running: Bool {
        get { stateLock.withLock { _running } }
        set { stateLock.withLock { _running = newValue } }
    }

    // Last UDP source address from libwebrtc — reply target for inbound WS frames.
    private var lastSrc: sockaddr_in?
    private let lastSrcLock = NSLock()

    private static let log = Logger(subsystem: "com.bcrypto.qaudion", category: "WssTurnBridge")

    // MARK: - Lifecycle

    /// Open the bridge. Throws `BridgeError` on socket failure.
    /// Returns once the UDP socket is bound and the WebSocket handshake
    /// is initiating — the WS open is async; TURN frames will begin
    /// flowing once the handshake completes.
    public func start() async throws -> BridgeResult {
        // Bind loopback UDP socket on an ephemeral port.
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw BridgeError.socketFailed(errno) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                          // kernel assigns port
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

        // Open WebSocket with subprotocol + auth header.
        var req = URLRequest(url: wssUrl)
        req.setValue("turn", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        if let tok = accessToken {
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        }
        let task = URLSession.shared.webSocketTask(with: req)
        wsTask = task
        running = true
        task.resume()

        // UDP → WS pump: blocking recvfrom on a dedicated OS thread.
        // Swift Tasks can't block on a syscall without starving the
        // cooperative thread pool, so we use Thread.detachNewThread.
        let capturedFD = fd
        Thread.detachNewThread { [weak self] in self?.pumpUdpToWs(fd: capturedFD) }
        // WS → UDP pump: async/await on a detached Task (URLSession
        // webSocket.receive suspends without blocking a thread).
        Task.detached(priority: .utility) { [weak self] in
            await self?.pumpWsToUdp(fd: capturedFD)
        }

        Self.log.info("start: 127.0.0.1:\(port) ↔ \(self.wssUrl.absoluteString)")
        return BridgeResult(localPort: port)
    }

    public func stop() {
        guard running else { return }
        running = false
        wsTask?.cancel(with: .goingAway, reason: Data("bridge-stop".utf8))
        wsTask = nil
        // Closing the fd interrupts the blocking recvfrom in pumpUdpToWs.
        let fd = udpFD
        if fd >= 0 { Darwin.close(fd); udpFD = -1 }
        Self.log.debug("stop: bridge torn down")
    }

    // MARK: - Relay pumps

    /// UDP → WebSocket pump. Runs on a dedicated OS thread because
    /// `recvfrom` is a blocking syscall. Exits when the fd is closed
    /// (recvfrom returns ≤ 0) or `running` becomes false.
    private func pumpUdpToWs(fd: Int32) {
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
            let data = Data(bytes: buf, count: n)
            wsTask?.send(.data(data)) { err in
                if let err { Self.log.warning("ws.send error: \(err)") }
            }
        }
    }

    /// WebSocket → UDP pump. Runs on a Swift cooperative Task.
    /// Routes inbound WS frames back to the last-known libwebrtc
    /// UDP source address. Drops frames if no source is known yet
    /// (harmless — TURN handshake is always client-initiated).
    private func pumpWsToUdp(fd: Int32) async {
        while running {
            guard let task = wsTask else { return }
            do {
                let msg = try await task.receive()
                guard case .data(let data) = msg else { continue }
                guard let dst = lastSrcLock.withLock({ lastSrc }) else {
                    Self.log.debug("drop WS frame — no known libwebrtc src")
                    continue
                }
                data.withUnsafeBytes { rawBuf in
                    var d = dst
                    _ = withUnsafeMutablePointer(to: &d) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            sendto(fd, rawBuf.baseAddress, data.count, 0, sa,
                                   socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            } catch {
                if running { Self.log.warning("ws.receive error: \(error)") }
                return
            }
        }
    }
}
#endif

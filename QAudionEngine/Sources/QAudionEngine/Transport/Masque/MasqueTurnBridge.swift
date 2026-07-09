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
/// **Reply routing (2026-07-09 hijack fix):** inbound tunnel datagrams are
/// routed by STUN/TURN transaction ID (RFC 5389 §6, shared by a request and
/// its response) or, for TURN ChannelData media, by channel number bound via
/// a prior ChannelBind exchange (RFC 5766 §11.4/§14.1) — never by "last UDP
/// sender", which any co-located loopback process could spoof with a single
/// datagram to hijack every subsequent reply (control-plane *and* media).
/// Reuses `WssTurnBridge`'s STUN/TURN parsing (same module, same wire
/// shapes) rather than duplicating it. See `resolveTarget(buf:len:)`.
///
/// **Mirrors:** `WssTurnBridge` (this repo, sibling fix) and Android `CronetMasqueDriver`.
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

    // Per-STUN-transaction / per-TURN-channel reply correlation (2026-07-09
    // hijack fix — replaces the old single "last UDP sender" scalar, see
    // class doc). Types/parsing reused from `WssTurnBridge` (same module).
    private var pendingByTxId: [String: (addr: sockaddr_in, ts: TimeInterval)] = [:]
    private var pendingChannelBind: [String: (addr: sockaddr_in, channelNumber: UInt16)] = [:]
    private var channelToAddr: [UInt16: sockaddr_in] = [:]
    private let correlationLock = NSLock()

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

        // 3. Tunnel → UDP: the transport hands us the raw UDP packet
        //    (it owns the H3/QUIC datagram framing); route it to libwebrtc.
        transport.onDatagram = { [weak self] udp in
            guard let self else { return }
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
    /// `SO_RCVTIMEO` bounds each blocking call to 1s so the same thread can
    /// also sweep expired `pendingByTxId` entries without a second timer
    /// racing `correlationLock` — mirrors `WssTurnBridge.pumpUdpToWs`. Exits
    /// when the fd closes (recvfrom returns 0) or `running` clears.
    private func pumpUdpToTunnel(fd: Int32) {
        let bufSize = 2048
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        var src = sockaddr_in()
        var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        while running {
            let n = withUnsafeMutablePointer(to: &src) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, buf, bufSize, 0, $0, &srcLen)
                }
            }
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    sweepExpiredPendingTx()
                    continue
                }
                break
            }
            if n == 0 { break }
            registerPendingAndSend(buf: buf, len: n, src: src)
        }
    }

    /// Registers this outbound datagram's STUN transaction ID (if any) as
    /// pending a reply, then forwards it into the tunnel. A ChannelBind
    /// request additionally stashes its address+channel number so the
    /// matching success response can populate `channelToAddr`. Mirrors
    /// `WssTurnBridge.registerPendingAndSend`.
    private func registerPendingAndSend(buf: UnsafePointer<UInt8>, len: Int, src: sockaddr_in) {
        if let txId = WssTurnBridge.stunTransactionId(buf, len) {
            correlationLock.withLock {
                if let existing = pendingByTxId[txId], !WssTurnBridge.sockaddrEqual(existing.addr, src) {
                    Self.log.warning("txId collision from a different src — ignoring re-registration")
                } else {
                    pendingByTxId[txId] = (addr: src, ts: Date().timeIntervalSince1970)
                    if WssTurnBridge.stunMessageClass(buf) == .request,
                       WssTurnBridge.stunMethod(buf) == WssTurnBridge.channelBindMethod,
                       let channelNumber = WssTurnBridge.channelBindChannelNumber(buf, len) {
                        pendingChannelBind[txId] = (addr: src, channelNumber: channelNumber)
                    }
                }
            }
        }
        // Pass the raw UDP packet; the transport applies the H3/QUIC
        // datagram framing (quarter-stream-id + context-id) itself.
        let udp = Data(bytes: buf, count: len)
        transport.sendDatagram(udp)
    }

    private func sweepExpiredPendingTx() {
        let cutoff = Date().timeIntervalSince1970 - WssTurnBridge.pendingTxTTL
        correlationLock.withLock {
            for (txId, entry) in pendingByTxId where entry.ts < cutoff {
                pendingByTxId.removeValue(forKey: txId)
                pendingChannelBind.removeValue(forKey: txId)
            }
        }
    }

    /// Route an inbound (decoded) tunnel datagram via `resolveTarget` — no
    /// fallback to a "last known sender" scalar (see class doc for why).
    private func sendToLoopback(_ udp: Data) {
        guard udpFD >= 0 else { return }
        let fd = udpFD
        udp.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            guard let dst = resolveTarget(buf: base, len: udp.count) else { return }
            var d = dst
            _ = withUnsafeMutablePointer(to: &d) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, base, udp.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// Resolves the UDP destination for an inbound tunnel datagram — see
    /// `WssTurnBridge.resolveTarget` for the full correlation rationale
    /// (ChannelData by channel number, STUN request/response by txId,
    /// indications and anything unmatched dropped rather than guess-routed).
    private func resolveTarget(buf: UnsafePointer<UInt8>, len: Int) -> sockaddr_in? {
        if let channelNumber = WssTurnBridge.channelDataNumber(buf, len) {
            let target = correlationLock.withLock { channelToAddr[channelNumber] }
            if target == nil {
                Self.log.debug("drop ChannelData — unknown channel \(channelNumber)")
            }
            return target
        }
        guard let txId = WssTurnBridge.stunTransactionId(buf, len) else {
            Self.log.debug("drop tunnel datagram — not STUN-shaped and not ChannelData")
            return nil
        }
        let msgClass = WssTurnBridge.stunMessageClass(buf)
        if msgClass == .indication {
            Self.log.debug("drop STUN indication — no channel/txId correlation available")
            return nil
        }
        return correlationLock.withLock {
            guard let pending = pendingByTxId.removeValue(forKey: txId) else {
                Self.log.debug("drop tunnel datagram — no pending request for txId")
                return nil
            }
            if msgClass == .successResponse, let bind = pendingChannelBind.removeValue(forKey: txId) {
                channelToAddr[bind.channelNumber] = pending.addr
            }
            return pending.addr
        }
    }
}
#endif

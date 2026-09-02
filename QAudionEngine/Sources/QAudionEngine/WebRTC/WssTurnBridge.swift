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
/// **Reply routing (2026-07-09 hijack fix):** inbound WS frames are routed
/// by STUN/TURN transaction ID (RFC 5389 §6, shared by a request and its
/// response) or, for TURN ChannelData media, by channel number bound via a
/// prior ChannelBind exchange (RFC 5766 §11.4/§14.1) — never by "last UDP
/// sender", which any co-located loopback process could spoof with a single
/// datagram to hijack every subsequent reply (control-plane *and* media).
/// See `resolveTarget(buf:len:)`.
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
    /// Local loopback SOCKS5 port to dial THIS bridge's WebSocket through
    /// (Reality/Tor active) — same shape as
    /// `BCryptoWebSocketClient.connect(viaSocksPort:)`'s `currentSocksPort`.
    /// `nil` (the default) preserves today's direct-dial behavior
    /// byte-for-byte: the signaling socket already tunnels through
    /// Reality/Tor when active (see `BCryptoWebSocketClient`), but this
    /// TURN-fallback bridge used to always dial clearnet regardless —
    /// leaking the call's TURN traffic outside the tunnel. Caller resolves
    /// the port from `RealityManager.shared.activeSocksPort` (or an
    /// equivalent Tor port) before constructing the bridge.
    private let socksPort: Int?
    /// W-AUXPIN (2026-09-02) — the caller's already cert-pinned REST
    /// `URLSession` (SECURITY C-6), reused for this bridge's WSS-TURN
    /// handshake instead of `URLSession.shared` (no pin) when no SOCKS
    /// proxy is in play. `nil` (the default) preserves today's behavior
    /// byte-for-byte — no caller before this change passed one. See
    /// `start()`'s session-selection comment for why the SOCKS-proxy
    /// branch is untouched.
    private let pinnedSession: URLSession?

    public init(
        wssUrl: URL,
        username: String? = nil,
        credential: String? = nil,
        accessToken: String? = nil,
        socksPort: Int? = nil,
        pinnedSession: URLSession? = nil
    ) {
        self.wssUrl = wssUrl
        self.username = username
        self.credential = credential
        self.accessToken = accessToken
        self.socksPort = socksPort
        self.pinnedSession = pinnedSession
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

    // Per-STUN-transaction / per-TURN-channel reply correlation (2026-07-09
    // hijack fix — replaces the old single "last UDP sender" scalar, see
    // class doc). All three maps are guarded by `correlationLock`.
    private var pendingByTxId: [String: (addr: sockaddr_in, ts: TimeInterval)] = [:]
    private var pendingChannelBind: [String: (addr: sockaddr_in, channelNumber: UInt16)] = [:]
    private var channelToAddr: [UInt16: sockaddr_in] = [:]
    private let correlationLock = NSLock()

    private static let log = Logger(subsystem: "com.bcrypto.qaudion", category: "WssTurnBridge")

    // MARK: - STUN/TURN wire parsing (RFC 5389 §6, RFC 5766 §2/§11.4/§14.1)
    //
    // These were made `internal` (module-visible, not `private`) in 2026-07-09
    // so the sibling MASQUE/HTTP-3 TURN bridge could reuse the same parsing.
    // That bridge is gone (MASQUE/QUIC removed fleet-wide), so today the only
    // consumer is this class. Left `internal` rather than re-narrowed to
    // `private` to keep the removal a pure deletion; safe to tighten later.

    enum StunMessageClass {
        case request
        case indication
        case successResponse
        case errorResponse
    }

    static let stunMagicCookie: UInt32 = 0x2112_a442
    static let channelBindMethod: UInt16 = 0x0009
    static let channelNumberAttrType: UInt16 = 0x000c
    static let pendingTxTTL: TimeInterval = 15

    /// RFC 5389 §6 transaction-ID extraction (bytes 8-19, after the 4-byte
    /// magic cookie at bytes 4-7). `nil` for anything shorter than a STUN
    /// header or lacking the magic cookie (e.g. a ChannelData frame, which
    /// is correlated by channel number instead — see `channelDataNumber`).
    static func stunTransactionId(_ buf: UnsafePointer<UInt8>, _ len: Int) -> String? {
        guard len >= 20 else { return nil }
        let cookie = (UInt32(buf[4]) << 24) | (UInt32(buf[5]) << 16) | (UInt32(buf[6]) << 8) | UInt32(buf[7])
        guard cookie == stunMagicCookie else { return nil }
        var hex = ""
        hex.reserveCapacity(24)
        for i in 8..<20 { hex += String(format: "%02x", buf[i]) }
        return hex
    }

    /// RFC 5389 §6 message class, decoded from the C1/C0 bits of the
    /// 16-bit message-type field (bytes 0-1).
    static func stunMessageClass(_ buf: UnsafePointer<UInt8>) -> StunMessageClass {
        let messageType = (UInt16(buf[0]) << 8) | UInt16(buf[1])
        let c1 = (messageType & 0x0100) != 0
        let c0 = (messageType & 0x0010) != 0
        if c1 && c0 { return .errorResponse }
        if c1 { return .successResponse }
        if c0 { return .indication }
        return .request
    }

    /// RFC 5389 §6 method bits of the message-type field (class bits masked out).
    static func stunMethod(_ buf: UnsafePointer<UInt8>) -> UInt16 {
        let messageType = (UInt16(buf[0]) << 8) | UInt16(buf[1])
        return messageType & 0xfeef
    }

    /// Parses the CHANNEL-NUMBER attribute (type 0x000C, RFC 5766 §14.1)
    /// out of a ChannelBind request body, following the 20-byte STUN header.
    static func channelBindChannelNumber(_ buf: UnsafePointer<UInt8>, _ len: Int) -> UInt16? {
        var offset = 20
        while offset + 4 <= len {
            let attrType = (UInt16(buf[offset]) << 8) | UInt16(buf[offset + 1])
            let attrLen = Int((UInt16(buf[offset + 2]) << 8) | UInt16(buf[offset + 3]))
            let valueStart = offset + 4
            if attrType == channelNumberAttrType, attrLen >= 2, valueStart + 2 <= len {
                return (UInt16(buf[valueStart]) << 8) | UInt16(buf[valueStart + 1])
            }
            // Attributes are padded to a 4-byte boundary (RFC 5389 §15).
            offset = valueStart + ((attrLen + 3) & ~3)
        }
        return nil
    }

    /// RFC 5766 §11.4: a ChannelData frame's first two bytes are the bound
    /// channel number (top two bits `01`, range 0x4000-0x7FFF) rather than
    /// a STUN magic cookie.
    static func channelDataNumber(_ buf: UnsafePointer<UInt8>, _ len: Int) -> UInt16? {
        guard len >= 4, (buf[0] & 0xc0) == 0x40 else { return nil }
        return (UInt16(buf[0]) << 8) | UInt16(buf[1])
    }

    static func sockaddrEqual(_ a: sockaddr_in, _ b: sockaddr_in) -> Bool {
        a.sin_addr.s_addr == b.sin_addr.s_addr && a.sin_port == b.sin_port
    }

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
        // Reality/Tor censorship-bypass path (additive, default off — mirrors
        // BCryptoWebSocketClient.connect(viaSocksPort:)). When SOCKS is set,
        // route this bridge's WSS-TURN socket through the SAME local tunnel
        // the signaling socket already uses, so a call's TURN relay traffic
        // doesn't leak outside Reality/Tor while signaling does — a custom
        // proxy config, so it cannot reuse `pinnedSession` below (that
        // session was built with no proxy) without risking exactly the kind
        // of behavior change this bridge's happy path must not get.
        let session: URLSession
        if let socksPort {
            let sessionConfig = URLSessionConfiguration.default
            sessionConfig.connectionProxyDictionary = [
                "SOCKSEnable": true,
                "SOCKSProxy": "127.0.0.1",
                "SOCKSPort": socksPort
            ] as [String: Any]
            session = URLSession(configuration: sessionConfig)
        } else if PinnedSessionPolicy.auxiliaryClientsUsePinnedSession, let pinnedSession {
            // W-AUXPIN (2026-09-02) — no SOCKS proxy in play, so the
            // caller's pinned REST session (see init doc, B11 / audit P1
            // item 6) is a drop-in replacement for `.shared`: identical
            // trust decision to every other pinned request to this host,
            // zero new `URLSession` construction. A caller that passes no
            // session (any `CallingApi` that doesn't override
            // `pinnedUrlSession()`) or has the kill switch off falls
            // through to the untouched `.shared` branch below.
            session = pinnedSession
        } else {
            session = URLSession.shared
        }
        let task = session.webSocketTask(with: req)
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
    /// `recvfrom` is a blocking syscall. `SO_RCVTIMEO` bounds each blocking
    /// call to 1s so the same thread can also sweep expired
    /// `pendingByTxId` entries without a second timer racing
    /// `correlationLock` from another thread. Exits when the fd is closed
    /// (recvfrom returns 0) or `running` becomes false.
    private func pumpUdpToWs(fd: Int32) {
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
    /// pending a reply, then forwards it over the WebSocket. A ChannelBind
    /// request additionally stashes its address+channel number so the
    /// matching success response can populate `channelToAddr`.
    private func registerPendingAndSend(buf: UnsafePointer<UInt8>, len: Int, src: sockaddr_in) {
        if let txId = Self.stunTransactionId(buf, len) {
            correlationLock.withLock {
                if let existing = pendingByTxId[txId], !Self.sockaddrEqual(existing.addr, src) {
                    Self.log.warning("txId collision from a different src — ignoring re-registration")
                } else {
                    pendingByTxId[txId] = (addr: src, ts: Date().timeIntervalSince1970)
                    if Self.stunMessageClass(buf) == .request,
                       Self.stunMethod(buf) == Self.channelBindMethod,
                       let channelNumber = Self.channelBindChannelNumber(buf, len) {
                        pendingChannelBind[txId] = (addr: src, channelNumber: channelNumber)
                    }
                }
            }
        }
        let data = Data(bytes: buf, count: len)
        wsTask?.send(.data(data)) { err in
            if let err { Self.log.warning("ws.send error: \(err)") }
        }
    }

    private func sweepExpiredPendingTx() {
        let cutoff = Date().timeIntervalSince1970 - Self.pendingTxTTL
        correlationLock.withLock {
            for (txId, entry) in pendingByTxId where entry.ts < cutoff {
                pendingByTxId.removeValue(forKey: txId)
                pendingChannelBind.removeValue(forKey: txId)
            }
        }
    }

    /// WebSocket → UDP pump. Runs on a Swift cooperative Task. Routes
    /// inbound WS frames via `resolveTarget` — no fallback to a "last
    /// known sender" scalar (see class doc for why).
    private func pumpWsToUdp(fd: Int32) async {
        while running {
            guard let task = wsTask else { return }
            do {
                let msg = try await task.receive()
                guard case .data(let data) = msg else { continue }
                data.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
                    guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                    guard let dst = resolveTarget(buf: base, len: data.count) else { return }
                    var d = dst
                    _ = withUnsafeMutablePointer(to: &d) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            sendto(fd, base, data.count, 0, sa,
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

    /// Resolves the UDP destination for an inbound WS frame:
    /// - ChannelData (RFC 5766 §11.4): routed by `channelToAddr[channelNumber]`.
    /// - STUN request/response (RFC 5389 §6): routed by `pendingByTxId[txId]`,
    ///   consumed on match. A ChannelBind success response additionally
    ///   promotes its pending-bind entry into `channelToAddr`.
    /// - STUN indication (e.g. legacy Data Indication, RFC 5766 §10):
    ///   carries a server-generated txId that never matches a client
    ///   request, so it can't be correlated here — real TURN clients
    ///   (including libwebrtc) use ChannelBind instead whenever the server
    ///   supports it (ours does), so this is expected to be a cold path;
    ///   dropped with a log line to confirm that post-ship.
    /// Anything else (unknown channel, unmatched txId, non-STUN/non-channel
    /// bytes) is dropped — never falls back to a "last known sender" scalar.
    private func resolveTarget(buf: UnsafePointer<UInt8>, len: Int) -> sockaddr_in? {
        if let channelNumber = Self.channelDataNumber(buf, len) {
            let target = correlationLock.withLock { channelToAddr[channelNumber] }
            if target == nil {
                Self.log.debug("drop ChannelData — unknown channel \(channelNumber)")
            }
            return target
        }
        guard let txId = Self.stunTransactionId(buf, len) else {
            Self.log.debug("drop WS frame — not STUN-shaped and not ChannelData")
            return nil
        }
        let msgClass = Self.stunMessageClass(buf)
        if msgClass == .indication {
            Self.log.debug("drop STUN indication — no channel/txId correlation available")
            return nil
        }
        return correlationLock.withLock {
            guard let pending = pendingByTxId.removeValue(forKey: txId) else {
                Self.log.debug("drop WS frame — no pending request for txId")
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

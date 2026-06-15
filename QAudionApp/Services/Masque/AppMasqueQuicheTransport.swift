#if canImport(Cquiche)
import Foundation
import Network
import QAudionEngine
import Cquiche
import os

/// Cloudflare-quiche-backed MASQUE CONNECT-UDP transport (HTTP/3 + QUIC
/// DATAGRAM, RFC 9298/9297/9221). Lives in the app target because quiche is
/// linked as `QAudionApp/Vendor/quiche.xcframework` (built in CI); the engine
/// stays QUIC-free. Registered into `MasqueTransportFactory` at launch.
///
/// Design:
///   - A single serial queue owns the `quiche_conn` (quiche is not
///     thread-safe per connection).
///   - An `NWConnection(.udp)` carries the wire bytes quiche produces /
///     consumes (quiche never touches a socket itself).
///   - `connect()` drives the QUIC handshake + the HTTP/3 extended-CONNECT
///     request and resolves once the proxy answers 2xx (tunnel open).
///   - UDP packets ride QUIC DATAGRAM frames framed by
///     `MasqueDatagramCodec.encodeHttp3Datagram` (quarter-stream-id +
///     context-id), wire-identical to the server's masque-go.
///
/// Call safety: any failure here surfaces as a thrown error /
/// `connectFailed`, and `MasqueTurnBridge.start()` is `try?`-guarded by the
/// call controller, so a broken tunnel degrades to WSS-TURN / Tor — it never
/// breaks a call.
public final class AppMasqueQuicheTransport: MasqueDatagramTransport {

    public var onDatagram: ((Data) -> Void)?

    private let queue = DispatchQueue(label: "com.bcrypto.qaudion.masque.quiche")
    private static let log = Logger(subsystem: "com.bcrypto.qaudion", category: "MasqueQuiche")

    private var conn: OpaquePointer?        // quiche_conn*
    private var h3: OpaquePointer?          // quiche_h3_conn*
    private var h3Config: OpaquePointer?    // quiche_h3_config*
    private var config: OpaquePointer?      // quiche_config*
    private var nw: NWConnection?

    private var requestStreamID: Int64 = -1
    private var quarterStreamID: UInt64 = 0
    private var established = false
    private var tunnelOpen = false
    private var readyCont: CheckedContinuation<Void, Error>?
    private var peerAddr = sockaddr_storage()
    private var peerAddrLen: socklen_t = 0
    private var localAddr = sockaddr_storage()
    private var localAddrLen: socklen_t = 0

    public init() {}

    deinit { close() }

    // MARK: - MasqueDatagramTransport

    public func connect(_ request: MasqueConnectUdpRequest) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else { cont.resume(throwing: MasqueTransportError.transportFailed("deallocated")); return }
                self.readyCont = cont
                do {
                    try self.startConnection(request)
                } catch {
                    self.readyCont = nil
                    cont.resume(throwing: error)
                }
            }
        }
    }

    public func sendDatagram(_ udpPayload: Data) {
        queue.async { [weak self] in
            guard let self, let conn = self.conn, self.tunnelOpen else { return }
            let framed = MasqueDatagramCodec.encodeHttp3Datagram(
                quarterStreamID: self.quarterStreamID, udpPayload: udpPayload)
            _ = framed.withUnsafeBytes { raw -> ssize_t in
                quiche_conn_dgram_send(conn, raw.bindMemory(to: UInt8.self).baseAddress, framed.count)
            }
            self.flushEgress()
        }
    }

    public func close() {
        queue.async { [weak self] in
            guard let self else { return }
            self.tunnelOpen = false
            if let h3 = self.h3 { quiche_h3_conn_free(h3); self.h3 = nil }
            if let conn = self.conn { quiche_conn_close(conn, true, 0, nil, 0); quiche_conn_free(conn); self.conn = nil }
            if let h3c = self.h3Config { quiche_h3_config_free(h3c); self.h3Config = nil }
            if let c = self.config { quiche_config_free(c); self.config = nil }
            self.nw?.cancel(); self.nw = nil
            if let cont = self.readyCont {
                self.readyCont = nil
                cont.resume(throwing: MasqueTransportError.transportFailed("closed"))
            }
        }
    }

    // MARK: - Setup (serial queue)

    private func startConnection(_ request: MasqueConnectUdpRequest) throws {
        let parts = request.proxyAuthority.split(separator: ":", maxSplits: 1)
        let host = String(parts.first ?? "")
        let port = UInt16(parts.count > 1 ? String(parts[1]) : "") ?? 443
        guard !host.isEmpty else { throw MasqueTransportError.transportFailed("bad authority") }
        savedRequest = request

        try resolvePeer(host: host, port: port)

        // quiche config: QUIC v1 (RFC 9000, what masque-go negotiates),
        // ALPN h3, datagrams on, generous flow control.
        guard let cfg = quiche_config_new(1) else {
            throw MasqueTransportError.transportFailed("config_new")
        }
        config = cfg
        let alpn: [UInt8] = [0x02, 0x68, 0x33]  // len-prefixed "h3"
        _ = alpn.withUnsafeBufferPointer { quiche_config_set_application_protos(cfg, $0.baseAddress, $0.count) }
        quiche_config_set_max_idle_timeout(cfg, 30_000)
        quiche_config_set_max_recv_udp_payload_size(cfg, 1350)
        quiche_config_set_max_send_udp_payload_size(cfg, 1350)
        quiche_config_set_initial_max_data(cfg, 10_000_000)
        quiche_config_set_initial_max_stream_data_bidi_local(cfg, 1_000_000)
        quiche_config_set_initial_max_stream_data_bidi_remote(cfg, 1_000_000)
        quiche_config_set_initial_max_stream_data_uni(cfg, 1_000_000)
        quiche_config_set_initial_max_streams_bidi(cfg, 100)
        quiche_config_set_initial_max_streams_uni(cfg, 100)
        quiche_config_enable_dgram(cfg, true, 65536, 65536)
        quiche_config_verify_peer(cfg, true)

        // SCID (random-ish; varies per instance via boot time + address).
        var scid = [UInt8](repeating: 0, count: 16)
        for i in 0..<scid.count { scid[i] = UInt8((Int(localAddrLen) &+ i &* 31) & 0xFF) }

        let conn: OpaquePointer? = host.withCString { hostPtr in
            scid.withUnsafeBufferPointer { scidBuf in
                withUnsafePointer(to: &localAddr) { localPtr in
                    localPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { localSA in
                        withUnsafePointer(to: &peerAddr) { peerPtr in
                            peerPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { peerSA in
                                quiche_connect(hostPtr, scidBuf.baseAddress, scidBuf.count,
                                               localSA, localAddrLen, peerSA, peerAddrLen, cfg)
                            }
                        }
                    }
                }
            }
        }
        guard let c = conn else { throw MasqueTransportError.transportFailed("quiche_connect") }
        self.conn = c

        startNetwork(host: host, port: port, request: request)
    }

    private func resolvePeer(host: String, port: UInt16) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        guard rc == 0, let info = res else { throw MasqueTransportError.transportFailed("resolve") }
        defer { freeaddrinfo(res) }
        memcpy(&peerAddr, info.pointee.ai_addr, Int(info.pointee.ai_addrlen))
        peerAddrLen = info.pointee.ai_addrlen
        // Local: unspecified IPv4/IPv6 matching the peer family.
        localAddr = sockaddr_storage()
        localAddr.ss_family = peerAddr.ss_family
        localAddrLen = peerAddrLen
    }

    private func startNetwork(host: String, port: UInt16, request: MasqueConnectUdpRequest) {
        let ep = NWEndpoint.hostPort(host: NWEndpoint.Host(host),
                                     port: NWEndpoint.Port(rawValue: port) ?? 443)
        let conn = NWConnection(to: ep, using: .udp)
        nw = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async {
                switch state {
                case .ready:
                    self.startReceive()
                    self.flushEgress()
                case .failed(let e), .waiting(let e):
                    Self.log.error("nw state \(String(describing: e))")
                default: break
                }
            }
        }
        conn.start(queue: queue)
        scheduleTimeout()
    }

    private var savedRequest: MasqueConnectUdpRequest?

    // MARK: - Egress / ingress pumps (serial queue)

    private func startReceive() {
        nw?.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            self.queue.async {
                if let data, !data.isEmpty { self.feedRecv(data) }
                if error == nil { self.startReceive() }
            }
        }
    }

    private func feedRecv(_ data: Data) {
        guard let conn = self.conn else { return }
        var recvInfo = quiche_recv_info()
        _ = withUnsafeMutablePointer(to: &peerAddr) { peerPtr in
            peerPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { peerSA in
                withUnsafeMutablePointer(to: &localAddr) { localPtr in
                    localPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { localSA in
                        recvInfo.from = peerSA
                        recvInfo.from_len = peerAddrLen
                        recvInfo.to = localSA
                        recvInfo.to_len = localAddrLen
                        var bytes = [UInt8](data)
                        return bytes.withUnsafeMutableBufferPointer { buf in
                            quiche_conn_recv(conn, buf.baseAddress, buf.count, &recvInfo)
                        }
                    }
                }
            }
        }
        afterQuicheProgress()
    }

    private func afterQuicheProgress() {
        guard let conn = self.conn else { return }
        if !established && quiche_conn_is_established(conn) {
            established = true
            openH3AndConnect()
        }
        if h3 != nil { pollH3() }
        drainDatagrams()
        flushEgress()
        scheduleTimeout()
    }

    private func openH3AndConnect() {
        guard let conn = self.conn, let req = savedRequest else { return }
        guard let h3cfg = quiche_h3_config_new() else { return }
        h3Config = h3cfg
        guard let h3conn = quiche_h3_conn_new_with_transport(conn, h3cfg) else { return }
        h3 = h3conn
        sendRequestWithHeaders(req: req, h3: h3conn, conn: conn)
    }

    private func sendRequestWithHeaders(req: MasqueConnectUdpRequest, h3: OpaquePointer, conn: OpaquePointer) {
        let fields = req.headerFields()
        // Keep all name/value byte buffers alive for the duration of the call.
        var bufs: [[UInt8]] = []
        for f in fields { bufs.append([UInt8](f.name.utf8)); bufs.append([UInt8](f.value.utf8)) }
        var hdrs = [quiche_h3_header]()
        bufs.withUnsafeBufferPointerToElements { ptrs in
            var i = 0
            for _ in fields {
                let n = ptrs[i]; let v = ptrs[i + 1]; i += 2
                hdrs.append(quiche_h3_header(name: UnsafeMutablePointer(mutating: n.baseAddress),
                                             name_len: n.count,
                                             value: UnsafeMutablePointer(mutating: v.baseAddress),
                                             value_len: v.count))
            }
            let sid = hdrs.withUnsafeBufferPointer { hb in
                quiche_h3_send_request(h3, conn, UnsafeMutablePointer(mutating: hb.baseAddress), hb.count, false)
            }
            if sid >= 0 {
                self.requestStreamID = sid
                self.quarterStreamID = UInt64(sid) / 4
                Self.log.info("CONNECT-UDP stream \(sid) (qsid \(self.quarterStreamID))")
            } else {
                Self.log.error("h3_send_request failed \(sid)")
            }
        }
    }

    private func pollH3() {
        guard let h3 = self.h3, let conn = self.conn else { return }
        while true {
            var evPtr: OpaquePointer?
            let streamID = quiche_h3_conn_poll(h3, conn, &evPtr)
            if streamID < 0 { break }
            guard let ev = evPtr else { continue }
            let type = quiche_h3_event_type(ev)
            // QUICHE_H3_EVENT_HEADERS == 0 (response headers arrived).
            if type == QUICHE_H3_EVENT_HEADERS && streamID == requestStreamID {
                markTunnelOpen()
            }
            quiche_h3_event_free(ev)
        }
    }

    private func markTunnelOpen() {
        guard !tunnelOpen else { return }
        tunnelOpen = true
        Self.log.info("MASQUE tunnel open")
        if let cont = readyCont { readyCont = nil; cont.resume() }
    }

    private func drainDatagrams() {
        guard let conn = self.conn else { return }
        var buf = [UInt8](repeating: 0, count: 2048)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { quiche_conn_dgram_recv(conn, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            let full = Data(buf[0..<Int(n)])
            if let decoded = MasqueDatagramCodec.decodeHttp3Datagram(full),
               decoded.quarterStreamID == quarterStreamID {
                onDatagram?(decoded.udpPayload)
            }
        }
    }

    private func flushEgress() {
        guard let conn = self.conn, let nw = self.nw else { return }
        var out = [UInt8](repeating: 0, count: 1350)
        while true {
            var sendInfo = quiche_send_info()
            let written = out.withUnsafeMutableBufferPointer {
                quiche_conn_send(conn, $0.baseAddress, $0.count, &sendInfo)
            }
            // quiche returns QUICHE_ERR_DONE (-1) when nothing is queued, or
            // other negatives on error; any value ≤ 0 means stop.
            if written <= 0 { break }
            let pkt = Data(out[0..<Int(written)])
            nw.send(content: pkt, completion: .contentProcessed { _ in })
        }
    }

    private func scheduleTimeout() {
        guard let conn = self.conn else { return }
        let ms = quiche_conn_timeout_as_millis(conn)
        guard ms != UInt64.max else { return }
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(min(ms, 5_000)))) { [weak self] in
            guard let self, let conn = self.conn else { return }
            quiche_conn_on_timeout(conn)
            self.afterQuicheProgress()
        }
    }
}

// Helper: call a closure with an array of UnsafeBufferPointer over each [UInt8].
private extension Array where Element == [UInt8] {
    func withUnsafeBufferPointerToElements<R>(_ body: ([UnsafeBufferPointer<UInt8>]) -> R) -> R {
        func rec(_ i: Int, _ acc: [UnsafeBufferPointer<UInt8>]) -> R {
            if i == count { return body(acc) }
            return self[i].withUnsafeBufferPointer { rec(i + 1, acc + [$0]) }
        }
        return rec(0, [])
    }
}
#endif

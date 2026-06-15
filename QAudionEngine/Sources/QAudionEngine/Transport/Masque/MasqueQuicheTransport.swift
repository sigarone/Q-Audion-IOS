// MASQUE CONNECT-UDP transport backed by Cloudflare quiche (HTTP/3 + QUIC
// DATAGRAM). Compiled ONLY when the `QAUDION_MASQUE_QUICHE` flag is set AND
// the CQuiche target + quiche.xcframework exist (see build-quiche-xcframework.sh
// and the FINISH LINE in MasqueDatagramTransport.swift). The default CI /
// TestFlight build never sets the flag, so this file contributes nothing and
// cannot affect the shipping binary.
#if QAUDION_MASQUE_QUICHE
import Foundation
import Network
import CQuiche   // C-shim target wrapping quiche.h

/// quiche-backed CONNECT-UDP transport.
///
/// IMPLEMENTATION RECIPE (must be completed + on-device tested on macOS):
///   1. Open a QUIC connection to `request.proxyAuthority` over UDP/443 using
///      `quiche_connect` with ALPN "h3" and `quiche_config_enable_dgram(true,…)`.
///      Drive the handshake on an NWConnection(.udp) socket (send/recv the
///      datagrams quiche produces via `quiche_conn_send`/`recv`).
///   2. Create the H3 connection (`quiche_h3_conn_new_with_transport`) and send
///      the extended CONNECT request with the pseudo-headers from
///      `request.headerFields()` (`:method=CONNECT`, `:protocol=connect-udp`,
///      `:path=…`, `capsule-protocol=?1`, `authorization`). Use
///      `quiche_h3_send_request` (do NOT close the stream — it stays open).
///   3. On the 2xx response, the tunnel is ready; surface that to `connect()`.
///   4. `sendDatagram`: `quiche_h3_send_dgram(flowID, payload)` where flowID is
///      the request stream's quarter-stream-id and `payload` is the already
///      RFC9298-framed bytes from MasqueDatagramCodec (context-id 0 + UDP).
///   5. Poll loop: on `quiche_h3_recv_dgram`, hand the payload to `onDatagram`.
///
/// Until the steps above are implemented, `connect` fails closed so callers
/// transparently fall back to WSS-TURN / Tor.
public final class MasqueQuicheTransport: MasqueDatagramTransport {

    public var onDatagram: ((Data) -> Void)?

    public init() {}

    public func connect(_ request: MasqueConnectUdpRequest) async throws {
        // TODO(masque): implement the quiche handshake + extended CONNECT.
        throw MasqueTransportError.backendNotBuilt
    }

    public func sendDatagram(_ payload: Data) {
        // TODO(masque): quiche_h3_send_dgram(flowID, payload).
    }

    public func close() {
        // TODO(masque): quiche_h3_conn_free + quiche_conn_close + socket teardown.
    }
}
#endif

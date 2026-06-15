import Foundation

/// RFC 9298 (CONNECT-UDP) HTTP Datagram payload codec.
///
/// Once an extended-CONNECT tunnel is open, each forwarded UDP packet travels
/// as one HTTP Datagram whose payload is:
///
///     HTTP Datagram Payload = Context ID (varint) || UDP Proxying Payload
///
/// Context ID 0 is reserved for raw UDP packets (RFC 9298 §5). The server
/// (`bcrypto-server/internal/masque/proxy.go`, masque-go over QUIC DATAGRAM
/// frames, RFC 9297/9221) sends and expects exactly this framing. The HTTP/3
/// Quarter-Stream-ID prefix that wraps this payload inside a QUIC DATAGRAM
/// frame is handled by the QUIC/H3 backend (see `MasqueDatagramTransport`),
/// not here.
///
/// Pure value logic — no platform dependency; unit-tested on every target.
public enum MasqueDatagramCodec {

    /// Context ID for raw UDP packets (RFC 9298 §5).
    public static let udpContextID: UInt64 = 0

    /// Wrap a raw outbound UDP payload into a CONNECT-UDP HTTP Datagram payload.
    public static func encode(udpPayload: Data) -> Data {
        var out = Data(MasqueVarint.encode(udpContextID))
        out.append(udpPayload)
        return out
    }

    /// Unwrap an inbound HTTP Datagram payload back to the raw UDP packet.
    /// Returns `nil` for a malformed prefix or any non-zero (unknown) context
    /// ID — such datagrams are not UDP payloads and must be dropped.
    public static func decode(_ datagramPayload: Data) -> Data? {
        let bytes = [UInt8](datagramPayload)
        guard let (ctx, length) = MasqueVarint.decode(bytes[...]) else { return nil }
        guard ctx == udpContextID else { return nil }
        return Data(bytes[length...])
    }

    // MARK: - HTTP/3 Datagram framing (RFC 9297 §2.1)

    /// A full HTTP/3 Datagram carried in a QUIC DATAGRAM frame is:
    ///
    ///     Quarter Stream ID (varint) || HTTP Datagram Payload
    ///
    /// where the Quarter Stream ID is `request_stream_id / 4` and the payload
    /// is the CONNECT-UDP framing above. The raw QUIC datagram backend
    /// (`quiche_conn_dgram_send`/`recv`) needs these exact bytes; quiche's
    /// higher-level h3 helper is bypassed so the wire format is fully ours and
    /// matches the server's masque-go (quic-go HTTP datagrams) byte-for-byte.

    /// Build the full HTTP/3 datagram bytes for an outbound UDP packet.
    public static func encodeHttp3Datagram(quarterStreamID: UInt64, udpPayload: Data) -> Data {
        var out = Data(MasqueVarint.encode(quarterStreamID))
        out.append(encode(udpPayload: udpPayload))
        return out
    }

    /// Parse a full inbound HTTP/3 datagram. Returns the quarter stream ID and
    /// the raw UDP packet, or `nil` on a malformed prefix / unknown context.
    public static func decodeHttp3Datagram(_ datagram: Data) -> (quarterStreamID: UInt64, udpPayload: Data)? {
        let bytes = [UInt8](datagram)
        guard let (qsid, qLen) = MasqueVarint.decode(bytes[...]) else { return nil }
        guard let udp = decode(Data(bytes[qLen...])) else { return nil }
        return (qsid, udp)
    }
}

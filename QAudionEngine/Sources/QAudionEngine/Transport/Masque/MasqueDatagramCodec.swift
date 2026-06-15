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
}

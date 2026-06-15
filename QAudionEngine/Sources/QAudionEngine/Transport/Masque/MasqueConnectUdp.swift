import Foundation

/// Descriptor for a MASQUE CONNECT-UDP request (RFC 9298) over HTTP/3.
///
/// The client opens an extended-CONNECT stream to the masque proxy
/// (`proxyAuthority`, taken from the relay bundle's `masque_url`) carrying the
/// target endpoint inside the well-known URI template
/// `/.well-known/masque/udp/{target_host}/{target_port}/`. The proxy then
/// bridges UDP between the client and `targetHost:targetPort` (which must be
/// on the server allow-list — the VPS TURN ports 3478/5349 or h3 443).
///
/// Pure value logic — header assembly + URI building are testable without a
/// live QUIC stack. The actual H3 send lives in `MasqueDatagramTransport`.
public struct MasqueConnectUdpRequest: Equatable {

    /// `:authority` of the masque proxy (host[:port] from `masque_url`).
    public let proxyAuthority: String
    /// UDP target the proxy tunnels to — the TURN server.
    public let targetHost: String
    public let targetPort: UInt16
    /// Bearer JWT; the server authenticates the CONNECT-UDP request.
    public let bearerToken: String?

    public init(proxyAuthority: String, targetHost: String, targetPort: UInt16, bearerToken: String? = nil) {
        self.proxyAuthority = proxyAuthority
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.bearerToken = bearerToken
    }

    /// `:path` — the RFC 9298 well-known template with the target expanded.
    /// `target_host` is percent-encoded per RFC 6570 (so IPv6 colons / DNS
    /// names survive a single path segment).
    public var path: String {
        let h = Self.percentEncodeSegment(targetHost)
        return "/.well-known/masque/udp/\(h)/\(targetPort)/"
    }

    /// Ordered pseudo-header + signaling header list for the extended CONNECT.
    /// `capsule-protocol: ?1` is mandatory for connect-udp (RFC 9298 §3).
    public func headerFields() -> [(name: String, value: String)] {
        var fields: [(name: String, value: String)] = [
            (":method", "CONNECT"),
            (":protocol", "connect-udp"),
            (":scheme", "https"),
            (":authority", proxyAuthority),
            (":path", path),
            ("capsule-protocol", "?1"),
        ]
        if let token = bearerToken, !token.isEmpty {
            fields.append(("authorization", "Bearer " + token))
        }
        return fields
    }

    // MARK: - Helpers

    /// Percent-encode a single URI path segment (RFC 3986 unreserved set only).
    static func percentEncodeSegment(_ s: String) -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Parse a TURN ICE URL (`turn:host:port?transport=udp`, `turns:[v6]:port`)
    /// into a `(host, port)` UDP target. Returns `nil` for non-TURN URLs or a
    /// missing/invalid port (a port is required to address the UDP allocation).
    public static func parseTurnTarget(_ turnUrl: String) -> (host: String, port: UInt16)? {
        var rest = turnUrl
        if rest.hasPrefix("turns:") {
            rest.removeFirst("turns:".count)
        } else if rest.hasPrefix("turn:") {
            rest.removeFirst("turn:".count)
        } else {
            return nil
        }
        // Drop any ?transport= / query suffix.
        if let q = rest.firstIndex(of: "?") {
            rest = String(rest[..<q])
        }
        guard !rest.isEmpty else { return nil }

        let host: String
        let portStr: String
        if rest.hasPrefix("[") {
            // IPv6 literal: [::1]:3478
            guard let close = rest.firstIndex(of: "]") else { return nil }
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let after = rest[rest.index(after: close)...]
            guard after.hasPrefix(":") else { return nil }
            portStr = String(after.dropFirst())
        } else {
            // host:port — split on the last colon.
            guard let colon = rest.lastIndex(of: ":") else { return nil }
            host = String(rest[..<colon])
            portStr = String(rest[rest.index(after: colon)...])
        }
        guard !host.isEmpty, let port = UInt16(portStr) else { return nil }
        return (host, port)
    }
}

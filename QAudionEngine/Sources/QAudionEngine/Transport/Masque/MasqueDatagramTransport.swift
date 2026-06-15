import Foundation

/// Backend seam for the MASQUE CONNECT-UDP data plane.
///
/// A concrete transport owns an HTTP/3 connection to the masque proxy, opens
/// the extended-CONNECT stream described by `MasqueConnectUdpRequest`, and
/// shuttles RFC 9298 HTTP Datagram payloads in QUIC DATAGRAM frames (the
/// Quarter-Stream-ID wrapping is the backend's responsibility — callers pass
/// only the `MasqueDatagramCodec`-framed payload).
///
/// Apple's `NWProtocolQUIC` does NOT expose QUIC datagrams, so the backend
/// wraps Cloudflare quiche (datagram + HTTP/3, wire-compatible with the
/// Android Cronet client). To keep `engine-tests` quiche-free, the concrete
/// transport (`AppMasqueQuicheTransport`) lives in the APP target and is
/// registered via `MasqueTransportFactory.register(_:)` at launch. quiche is
/// built as `QAudionApp/Vendor/quiche.xcframework` by the CI step
/// "Build quiche xcframework" (scripts/build-quiche-xcframework.sh) and linked
/// into the app via project.yml.
public protocol MasqueDatagramTransport: AnyObject {

    /// Open the HTTP/3 connection + extended-CONNECT stream. Throws on
    /// handshake / CONNECT failure; the caller falls back to WSS-TURN / Tor.
    func connect(_ request: MasqueConnectUdpRequest) async throws

    /// Send one raw UDP packet. The transport applies the full H3/QUIC
    /// datagram framing (quarter-stream-id + context-id, via
    /// `MasqueDatagramCodec.encodeHttp3Datagram`) before transmission.
    func sendDatagram(_ udpPayload: Data)

    /// Invoked with each inbound raw UDP packet (the transport has already
    /// stripped the H3/QUIC datagram framing).
    var onDatagram: ((Data) -> Void)? { get set }

    /// Tear down the stream and the underlying HTTP/3 connection.
    func close()
}

/// Errors surfaced by MASQUE transports.
public enum MasqueTransportError: Error, Equatable {
    /// No datagram-capable QUIC/H3 backend is compiled into this build.
    case backendNotBuilt
    /// The CONNECT-UDP request was rejected (non-2xx) or the tunnel failed.
    case connectFailed(status: Int)
    /// HTTP/3 handshake or transport-level failure.
    case transportFailed(String)
}

/// Runtime gate for the MASQUE transport path.
///
/// OFF by default. A build flips this to `true` only when a real backend is
/// compiled in (`QAUDION_MASQUE_QUICHE`) AND ops opts the device in. With the
/// flag false the call controller never attempts MASQUE, so behaviour and the
/// TestFlight build are unchanged.
public enum MasqueFeature {
    public static var isEnabled: Bool = false
}

/// Produces a concrete `MasqueDatagramTransport`.
///
/// The QUIC/H3 backend (quiche) lives in the APP target, not this package, so
/// the engine stays QUIC-free and `engine-tests` never has to build quiche.
/// The app registers its quiche-backed maker into `register(_:)` at launch
/// (guarded by `#if canImport(Cquiche)`); until then `make()` returns nil and
/// the MASQUE path is inert.
public enum MasqueTransportFactory {
    /// App-supplied maker for the quiche-backed transport. Set once at launch.
    private static var maker: (() -> MasqueDatagramTransport?)?

    /// Register the backend maker (called by the app when Cquiche is linked).
    public static func register(_ maker: @escaping () -> MasqueDatagramTransport?) {
        self.maker = maker
    }

    public static func make() -> MasqueDatagramTransport? {
        guard let maker else { return nil }
        return maker()
    }
}

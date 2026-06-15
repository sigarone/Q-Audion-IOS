import Foundation

/// Backend seam for the MASQUE CONNECT-UDP data plane.
///
/// A concrete transport owns an HTTP/3 connection to the masque proxy, opens
/// the extended-CONNECT stream described by `MasqueConnectUdpRequest`, and
/// shuttles RFC 9298 HTTP Datagram payloads in QUIC DATAGRAM frames (the
/// Quarter-Stream-ID wrapping is the backend's responsibility — callers pass
/// only the `MasqueDatagramCodec`-framed payload).
///
/// Apple's `NWProtocolQUIC` does NOT expose QUIC datagrams, so there is no
/// first-party iOS implementation; a real backend wraps a datagram-capable
/// QUIC/H3 library (quiche — wire-compatible with the Android Cronet client).
///
/// FINISH LINE to activate MASQUE on iOS:
///   1. Build libquiche as an xcframework (cargo build --features ffi for
///      ios-arm64 + ios-sim-arm64; `xcodebuild -create-xcframework`).
///   2. Add a `CQuiche` C-shim SwiftPM target (mirror `CLiboqs`) + a
///      `.binaryTarget(name: "quiche", path: ...)` in Package.swift.
///   3. Add `MasqueQuicheTransport: MasqueDatagramTransport` driving quiche's
///      h3 extended-CONNECT + `quiche_h3_send_dgram`/`recv_dgram`.
///   4. Compile with `-D QAUDION_MASQUE_QUICHE` and set `MasqueFeature.isEnabled`.
///   5. Validate on-device against the live masque-go proxy (RFC 9298/9221).
/// Until then `MasqueTransportFactory.make()` returns `nil` and the MASQUE
/// call path is inert — the standard TestFlight build is unaffected.
public protocol MasqueDatagramTransport: AnyObject {

    /// Open the HTTP/3 connection + extended-CONNECT stream. Throws on
    /// handshake / CONNECT failure; the caller falls back to WSS-TURN / Tor.
    func connect(_ request: MasqueConnectUdpRequest) async throws

    /// Send one RFC 9298 HTTP Datagram payload (Context ID + UDP packet).
    func sendDatagram(_ payload: Data)

    /// Invoked for each inbound HTTP Datagram payload received on the tunnel.
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

/// Produces a concrete `MasqueDatagramTransport` when a QUIC/H3 backend is
/// linked, else `nil`. The default (CI / TestFlight) build links no QUIC
/// library, so this returns `nil` and the MASQUE path is a no-op.
public enum MasqueTransportFactory {
    public static func make() -> MasqueDatagramTransport? {
        #if QAUDION_MASQUE_QUICHE
        return MasqueQuicheTransport()   // provided when the quiche backend is added
        #else
        return nil
        #endif
    }
}

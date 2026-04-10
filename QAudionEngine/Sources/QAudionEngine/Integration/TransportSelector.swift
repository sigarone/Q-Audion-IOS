import Foundation

/// Selects the best transport for a call, preferring direct P2P over relay.
///
/// Selection order:
/// 1. UDP P2P via ICE (lowest latency, no server dependency)
/// 2. BCrypto WebSocket relay (server-mediated, encrypted)
/// 3. Loopback (testing / last resort)
public final class TransportSelector {
    public enum SelectedTransport: String { case udpP2P; case bcryptoWebSocket; case signalRelay }

    public init() {}

    /// Select a transport channel. Tries P2P first when remote ICE candidates are available.
    ///
    /// - Parameters:
    ///   - wsClient: An optional authenticated WebSocket client for relay fallback.
    ///   - remoteCandidates: ICE candidates received from the remote peer via signalling.
    /// - Returns: A tuple of the opened `SecureChannel` and the transport type selected.
    public func select(
        wsClient: BCryptoWebSocketClient?,
        remoteCandidates: [IceAgent.IceCandidate]? = nil
    ) async -> (SecureChannel, SelectedTransport) {

        // 1. Try UDP P2P via ICE (best: lowest latency, no server)
        if let candidates = remoteCandidates, !candidates.isEmpty {
            let iceAgent = IceAgent()
            if let bestCandidate = await iceAgent.checkConnectivity(remoteCandidates: candidates) {
                let udp = UdpPeerTransport()
                udp.connectToPeer(host: bestCandidate.ip, port: bestCandidate.port)
                return (udp, .udpP2P)
            }
        }

        // 2. Fall back to BCrypto WebSocket relay
        if let ws = wsClient, ws.state == .authenticated {
            let transport = BCryptoWebSocketTransport(wsClient: ws)
            return (transport, .bcryptoWebSocket)
        }

        // 3. Last resort: loopback for testing
        let loopback = LoopbackTransport()
        return (loopback, .signalRelay)
    }
}

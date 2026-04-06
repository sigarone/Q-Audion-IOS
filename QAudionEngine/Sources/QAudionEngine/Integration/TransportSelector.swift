import Foundation

public final class TransportSelector {
    public enum SelectedTransport: String { case udpP2P; case bcryptoWebSocket; case signalRelay }

    public init() {}

    public func select(wsClient: BCryptoWebSocketClient?) async -> (SecureChannel, SelectedTransport) {
        // Try BCrypto WebSocket first (most common for now)
        if let ws = wsClient, ws.state == .authenticated {
            let transport = BCryptoWebSocketTransport(wsClient: ws)
            return (transport, .bcryptoWebSocket)
        }
        // Fallback to loopback for testing
        let loopback = LoopbackTransport()
        return (loopback, .signalRelay)
    }
}

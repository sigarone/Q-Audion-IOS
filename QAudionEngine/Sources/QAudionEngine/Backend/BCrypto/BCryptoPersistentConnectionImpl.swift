import Foundation

public final class BCryptoPersistentConnectionImpl: PersistentConnection {
    private let ws: BCryptoWebSocketClient
    public var state: ConnectionState { ws.state }

    init(ws: BCryptoWebSocketClient) { self.ws = ws }

    public func connect() async throws { ws.connect() }
    public func disconnect() { ws.disconnect() }
    public func addStateListener(_ listener: @escaping (ConnectionState) -> Void) { ws.addStateListener(listener) }
    public func removeAllListeners() { /* ws manages listeners */ }

    public func ensureAuthenticated(timeoutSec: TimeInterval) async -> Bool {
        await ws.ensureAuthenticated(timeoutSec: timeoutSec)
    }
}

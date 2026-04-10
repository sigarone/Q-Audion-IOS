import Foundation

/// Persistent WebSocket connection to Signal's infrastructure.
///
/// Wraps `BCryptoWebSocketClient` which handles the actual WebSocket lifecycle
/// (connect, reconnect with exponential backoff, ping/pong, authentication).
/// The WebSocket URL is derived from the `BackendConfig.serverUrl` by the
/// underlying client (https -> wss, appending `/ws`).
///
/// For Signal's standard WebSocket endpoint (`wss://chat.signal.org/v1/websocket/`),
/// the config's `serverUrl` should be set to `https://chat.signal.org`.
public final class UpstreamPersistentConnectionImpl: PersistentConnection {
    private let ws: BCryptoWebSocketClient
    private let lock = NSLock()
    private var externalListeners: [(ConnectionState) -> Void] = []

    public var state: ConnectionState { ws.state }

    init(ws: BCryptoWebSocketClient) {
        self.ws = ws
    }

    /// Open the WebSocket connection.
    ///
    /// The underlying `BCryptoWebSocketClient` handles:
    /// - TLS certificate validation (or self-signed cert acceptance per config)
    /// - Automatic authentication if `config.accessToken` is set
    /// - Reconnection with exponential backoff on disconnect
    /// - Message dispatch to registered handlers
    public func connect() async throws {
        ws.connect()
    }

    /// Gracefully close the WebSocket connection.
    /// Clears reconnection state so no automatic reconnect occurs.
    public func disconnect() {
        ws.disconnect()
    }

    /// Register a listener that is called whenever the connection state changes.
    /// Listeners are invoked on the WebSocket client's internal dispatch queue.
    public func addStateListener(_ listener: @escaping (ConnectionState) -> Void) {
        lock.lock()
        externalListeners.append(listener)
        lock.unlock()

        ws.addStateListener(listener)
    }

    /// Remove all externally-registered state listeners.
    /// Note: internal listeners registered by API implementations are unaffected.
    public func removeAllListeners() {
        lock.lock()
        externalListeners.removeAll()
        lock.unlock()
    }
}

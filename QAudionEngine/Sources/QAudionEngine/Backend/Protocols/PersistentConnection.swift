import Foundation

public enum ConnectionState: String { case disconnected; case connecting; case connected; case authenticated }

public protocol PersistentConnection: AnyObject {
    var state: ConnectionState { get }
    /// Diagnostic only — the reason for the most recent transition into
    /// `.disconnected` (underlying network error description, or a
    /// synthetic label for an explicit local teardown). Nil before the
    /// first disconnect this instance has seen.
    var lastDisconnectReason: String? { get }
    func connect() async throws
    func disconnect()
    func addStateListener(_ listener: @escaping (ConnectionState) -> Void)
    func removeAllListeners()

    /// Block (asynchronously) until the connection is authenticated and the
    /// underlying transport is fresh, or `timeoutSec` elapses. Returns
    /// `true` on success. Implementations are responsible for triggering a
    /// reconnect when the connection has gone stale (iOS suspended task,
    /// network blip, etc.) — the caller does not need to detect that.
    ///
    /// Used by call setup paths to gate `sendCallOffer*` so the user never
    /// sees a sub-second CallKit flash on a dead WebSocket.
    func ensureAuthenticated(timeoutSec: TimeInterval) async -> Bool
}

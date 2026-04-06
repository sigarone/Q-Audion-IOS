import Foundation

public final class UpstreamPersistentConnectionImpl: PersistentConnection {
    public var state: ConnectionState = .disconnected
    private var listeners: [(ConnectionState) -> Void] = []
    public init() {}
    public func connect() async throws { state = .connected; listeners.forEach { $0(.connected) } }
    public func disconnect() { state = .disconnected; listeners.forEach { $0(.disconnected) } }
    public func addStateListener(_ listener: @escaping (ConnectionState) -> Void) { listeners.append(listener) }
    public func removeAllListeners() { listeners.removeAll() }
}

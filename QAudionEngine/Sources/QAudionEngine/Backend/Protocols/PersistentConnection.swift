import Foundation

public enum ConnectionState: String { case disconnected; case connecting; case connected; case authenticated }

public protocol PersistentConnection: AnyObject {
    var state: ConnectionState { get }
    func connect() async throws
    func disconnect()
    func addStateListener(_ listener: @escaping (ConnectionState) -> Void)
    func removeAllListeners()
}

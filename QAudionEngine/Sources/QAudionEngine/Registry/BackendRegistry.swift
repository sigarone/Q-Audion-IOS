import Foundation

public final class BackendRegistry: @unchecked Sendable {
    public static let shared = BackendRegistry()
    private let lock = NSLock()
    private var backends: [String: BackendProvider] = [:]

    private init() {}

    public func register(_ provider: BackendProvider) {
        lock.lock(); backends[provider.identifier] = provider; lock.unlock()
    }

    public func unregister(_ identifier: String) {
        lock.lock(); backends.removeValue(forKey: identifier); lock.unlock()
    }

    public func getProvider(_ identifier: String) -> BackendProvider? {
        lock.lock(); defer { lock.unlock() }; return backends[identifier]
    }

    public func getAllProviders() -> [BackendProvider] {
        lock.lock(); defer { lock.unlock() }; return Array(backends.values)
    }

    public func getBCryptoProvider() -> BCryptoBackendProvider? {
        getProvider("bcrypto") as? BCryptoBackendProvider
    }

    public func getUpstreamProvider() -> UpstreamBackendProvider? {
        getProvider("upstream") as? UpstreamBackendProvider
    }
}

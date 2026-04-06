import Foundation

public final class BackendSelectionPolicy {
    public enum Policy { case bcryptoPreferred; case upstreamOnly; case perContact }

    private var policy: Policy = .bcryptoPreferred
    private var contactOverrides: [String: String] = [:]  // contactId -> backendId

    public init() {}

    public func setPolicy(_ policy: Policy) { self.policy = policy }
    public func getPolicy() -> Policy { policy }

    public func setContactBackend(contactId: String, backendId: String) {
        contactOverrides[contactId] = backendId
    }

    public func selectBackend(for contactId: String) -> BackendProvider? {
        if let override = contactOverrides[contactId] {
            return BackendRegistry.shared.getProvider(override)
        }
        switch policy {
        case .bcryptoPreferred:
            return BackendRegistry.shared.getBCryptoProvider() ?? BackendRegistry.shared.getUpstreamProvider()
        case .upstreamOnly:
            return BackendRegistry.shared.getUpstreamProvider()
        case .perContact:
            return BackendRegistry.shared.getBCryptoProvider()
        }
    }
}

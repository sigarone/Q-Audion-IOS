import Foundation

public final class BackendInitializer {
    public init() {}

    public func initializeAll(bcryptoConfig: BackendConfig?) async throws {
        // Register BCrypto backend if configured
        if let config = bcryptoConfig {
            let bcrypto = BCryptoBackendProvider(config: config)
            try await bcrypto.initialize()
            BackendRegistry.shared.register(bcrypto)
        }
    }

    public func shutdownAll() {
        for provider in BackendRegistry.shared.getAllProviders() {
            provider.shutdown()
        }
    }
}

import Foundation

public final class BackendInitializer {
    public init() {}

    public func initializeAll(bcryptoConfig: BackendConfig?) async throws {
        // Register upstream (Signal) backend
        let upstream = UpstreamBackendProvider()
        try await upstream.initialize()
        BackendRegistry.shared.register(upstream)

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

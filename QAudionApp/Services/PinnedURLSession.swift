import Foundation
import QAudionEngine

/// App-layer cert-pinning helper — extends SECURITY C-6 to call sites that use
/// raw URLSession instead of BCryptoRestClient.
///
/// Uses BackendConfig.pinned() + BCryptoRestClient to obtain a URLSession backed
/// by the same CertPinningDelegate as the engine layer:
///   - For voip.bcrypto.com (and its known IP equivalents): pins Let's Encrypt
///     E8 intermediate + ISRG Root X1 (see PinnedServerHost.certChainPins).
///   - For any other host: returns a standard URLSession (system TLS validation),
///     matching the behaviour of BackendConfig.pinned() for non-prod servers.
///
/// **Do not call make(for:) per-request** — it allocates a new URLSession and its
/// thread pool. Cache the returned session as a stored property.
enum PinnedURLSession {
    static func make(for serverUrl: String) -> URLSession {
        BCryptoRestClient(config: .pinned(serverUrl: serverUrl)).urlSession
    }
}

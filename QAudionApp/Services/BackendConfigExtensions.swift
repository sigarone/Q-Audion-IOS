import Foundation
import QAudionEngine

/// IMPORTANT-2a: convenience factory that automatically applies cert pinning
/// when the serverUrl resolves to `voip.bcrypto.com`. For all other hosts
/// (test servers, staging, local dev) standard system TLS validation is used.
///
/// **Every new BackendConfig in QAudionApp MUST use this factory** instead of
/// `BackendConfig(serverUrl:...)` directly. The `pinnedConfig(token:)` helper
/// in AppState calls this internally; other Services that hold a serverUrl
/// string but not an AppState reference should call `BackendConfig.pinned(...)`.
///
/// Rotation note: cert hashes live in `PinnedServerHost.certChainPins`.
/// Update that constant before the Let's Encrypt E8 intermediate expires
/// (2027-03-13). The ISRG Root X1 backup pin is valid until 2035.
public extension BackendConfig {

    /// Build a BackendConfig with automatic cert pinning for the production
    /// VPS (`voip.bcrypto.com`). For any other host the pin is nil (uses
    /// default TLS chain validation, which is still secure for CA-signed certs).
    static func pinned(
        serverUrl: String,
        accessToken: String? = nil,
        refreshToken: String? = nil,
        userId: String? = nil,
        acceptSelfSignedCerts: Bool = false
    ) -> BackendConfig {
        let isPinnedHost: Bool = {
            guard let host = URL(string: serverUrl)?.host?.lowercased() else { return false }
            return host == PinnedServerHost.host.lowercased()
                || PinnedServerHost.knownAddresses.map({ $0.lowercased() }).contains(host)
        }()
        let pin: String? = isPinnedHost ? PinnedServerHost.certChainPins : nil
        return BackendConfig(
            serverUrl: serverUrl,
            accessToken: accessToken,
            refreshToken: refreshToken,
            userId: userId,
            acceptSelfSignedCerts: acceptSelfSignedCerts,
            certPinSha256B64: pin
        )
    }
}

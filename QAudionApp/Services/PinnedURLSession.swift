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

    /// W-AUXPIN (2026-09-01) — the session an AUXILIARY client (telemetry
    /// pump, bug reporter, feedback channel, self-test probe) uses for its
    /// bearer-token requests to `serverUrl`. Same pins and same
    /// `CertPinningDelegate` as `make(for:)` (both go through
    /// `BackendConfig.pinned(serverUrl:)` → `BCryptoRestClient`), but cached
    /// process-wide per host by `PinnedSessionCache`, so call sites that used
    /// to do `URLSession.shared.data(for:)` per request can swap in this
    /// one-liner without leaking a URLSession per call. Those four clients
    /// were the only bearer-token traffic to the VoIP host with NO pin
    /// (audit memory reference_ios_stability_audit_2026_09_01, P1 item 6).
    /// `PinnedSessionPolicy.auxiliaryClientsUsePinnedSession == false`
    /// restores `URLSession.shared` (the pre-W-AUXPIN behaviour) everywhere.
    static func auxiliary(for serverUrl: String) -> URLSession {
        guard PinnedSessionPolicy.auxiliaryClientsUsePinnedSession else { return URLSession.shared }
        return PinnedSessionCache.session(for: .pinned(serverUrl: serverUrl))
    }
}

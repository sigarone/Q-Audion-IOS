import Foundation

/// W-AUXPIN (2026-09-01) — pure decisions for the certificate-pinned
/// `URLSession` that AUXILIARY HTTP clients (telemetry batch pump, bug
/// reporter, feedback channel, self-test reachability probe) use when they
/// talk to the VoIP backend with a bearer token.
///
/// Why: those four clients called `URLSession.shared.data(for:)` directly —
/// system-default TLS chain validation, NO pin — while every other request
/// to the same host (REST client, WS, VPN control plane, update checker,
/// group membership, Track-B sync, FE-5 exchange) has been pinned since
/// SECURITY C-6. A bearer token on an unpinned session is exactly the gap the
/// audit flagged (see audit memory reference_ios_stability_audit_2026_09_01,
/// P1 item 6: TelemetryService.swift:333, BugReporter.swift:256/:375,
/// FeedbackService.swift:225/:239, SelfTestService.swift:240).
///
/// Design — risk-minimal, and by construction the SAME trust decision as
/// the REST client:
///   - NO second pinning mechanism. `PinnedSessionCache` obtains its session
///     from `BCryptoRestClient(config:).urlSession`, i.e. the same
///     `CertPinningDelegate`, the same pin string carried by
///     `BackendConfig.certPinSha256B64`, the same DEBUG/Release branch
///     selection (trust-all stays confined to an explicit
///     `acceptSelfSignedCerts: true`, never set by these callers) and the
///     same bounded request timeout (IOS-E2). Nothing here can diverge from
///     what the main REST traffic already does.
///   - ONE session per (host, trust configuration), cached for the process
///     lifetime. A `URLSession` created per request is a resource leak —
///     each instance owns a thread pool and retains its delegate until
///     invalidated — which is why the App-side `PinnedURLSession.make(for:)`
///     doc forbids per-request construction and why the call sites could
///     not simply inline it.
///   - Compile-time kill switch (`auxiliaryClientsUsePinnedSession`), same
///     style as `CallCapabilities.longAudioSendEnabled`: flipping it back to
///     `false` returns every auxiliary client to `URLSession.shared` exactly
///     as before; nothing else changes.
///
/// The helpers below hold no networking state so the contract is pinned by
/// `PinnedSessionPolicyTests` in CI — same discipline as
/// `RestartIceDecisions` / `IceTerminationPolicy`.
public enum PinnedSessionPolicy {

    /// W-AUXPIN kill switch. `true` = auxiliary clients use the cached pinned
    /// session; `false` = they use `URLSession.shared` (the pre-2026-09-01
    /// behaviour, no pin). Compile-time on purpose: a runtime toggle for a
    /// TLS trust decision is itself an attack surface. Rollback is this line.
    public static let auxiliaryClientsUsePinnedSession: Bool = true

    /// Session-reuse key for a server URL: lowercased `scheme://host[:port]`,
    /// with the scheme's default port (443/https, 80/http) omitted so
    /// `https://h` and `https://h:443` map to the same session. Path, query
    /// and fragment are ignored because the trust decision
    /// (`BackendConfig.pinned(serverUrl:)` → pin or no pin) depends on the
    /// host only, so two base URLs that differ only in path MUST share one
    /// session. `nil` when the string has no parseable host — `cacheKey`
    /// then falls back to the raw string so an odd input still maps to ONE
    /// cached session rather than a fresh one per call (unreachable from the
    /// four auxiliary clients: each guards `URL(string: serverUrl + path)`
    /// before it ever asks for a session).
    public static func reuseKey(for serverUrl: String) -> String? {
        guard let url = URL(string: serverUrl),
              let host = url.host, !host.isEmpty else { return nil }
        let scheme = (url.scheme ?? "https").lowercased()
        let defaultPort: Int? = (scheme == "https") ? 443 : ((scheme == "http") ? 80 : nil)
        let port: String
        if let p = url.port, p != defaultPort {
            port = ":" + String(p)
        } else {
            port = ""
        }
        return scheme + "://" + host.lowercased() + port
    }

    /// Cache key for a full trust configuration: the reuse key plus the pin
    /// set and the self-signed flag, so two configs for the same host with
    /// DIFFERENT trust settings can never share a session.
    public static func cacheKey(for config: BackendConfig) -> String {
        let base = reuseKey(for: config.serverUrl) ?? config.serverUrl
        return base
            + "|pin=" + (config.certPinSha256B64 ?? "")
            + "|selfsigned=" + (config.acceptSelfSignedCerts ? "1" : "0")
    }
}

/// W-AUXPIN (2026-09-01) — process-wide cache of pinned sessions, keyed by
/// `PinnedSessionPolicy.cacheKey(for:)`. See that type's doc for the why.
public enum PinnedSessionCache {

    private static let lock = NSLock()
    /// Guarded by `lock`; `nonisolated(unsafe)` matches the established
    /// pattern for lock-guarded mutable statics in this target (see
    /// `VideoBandwidthCap._peerCapBps`).
    private static nonisolated(unsafe) var sessions: [String: URLSession] = [:]

    /// The one `URLSession` for `config`'s host + trust settings, built on
    /// first use from `BCryptoRestClient(config:).urlSession` (same delegate,
    /// same pins, same timeout as the REST client) and retained for the
    /// process lifetime. Thread-safe; callable from any actor.
    public static func session(for config: BackendConfig) -> URLSession {
        let key = PinnedSessionPolicy.cacheKey(for: config)
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[key] { return existing }
        // Built while holding the lock on purpose: that is what makes
        // "exactly ONE session per key" true under concurrent first calls
        // (a lock-free build would race and leak the loser, since nothing
        // ever invalidates a session). Safe because construction does no
        // blocking I/O (URLSession init + NWPathMonitor.start are
        // asynchronous) and nothing it triggers calls back into this cache.
        // The temporary REST client is released right here (its
        // NWPathMonitor is cancelled in deinit); the returned URLSession
        // retains its own delegate until invalidated, which this cache never
        // does. Growth is bounded by (host × trust configuration): the
        // pinned primary plus the failover allowlist.
        let created = BCryptoRestClient(config: config).urlSession
        sessions[key] = created
        return created
    }
}

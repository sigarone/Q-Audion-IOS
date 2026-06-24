import Foundation
import CommonCrypto
import os

public final class BCryptoRestClient {
    /// Callback invoked when a protected request returns HTTP 401.
    /// Implementations should call POST /api/v1/auth/refresh with the current
    /// refresh token and return the new (accessToken, refreshToken) pair so
    /// the client can update its config and retry the original request. If
    /// refresh fails the callback should throw — the original request will
    /// then bubble up the 401 as BCryptoError.unauthorized.
    public typealias TokenRefresher = @Sendable () async throws -> (accessToken: String, refreshToken: String?)

    /// 2026-05-06 session-renewal Phase 2 — Ed25519 device-bound silent
    /// re-auth fallback. Invoked when the primary `tokenRefresher`
    /// throws (refresh token rejected or absent). On success returns
    /// the fresh tokens and the 401-retry proceeds; on failure the
    /// caller surfaces `BCryptoError.unauthorized`.
    public typealias DeviceRenewFallback = @Sendable () async throws -> (accessToken: String, refreshToken: String?)

    private var config: BackendConfig
    private let session: URLSession
    private var tokenRefresher: TokenRefresher?
    private var deviceRenewFallback: DeviceRenewFallback?
    /// Serialises concurrent refresh attempts so we don't fire N /auth/refresh
    /// calls when many in-flight requests simultaneously hit 401.
    private let refreshLock = OSAllocatedUnfairLock<Void>(initialState: ())
    private var refreshInFlight: Task<Bool, Error>?

    public init(config: BackendConfig) {
        self.config = config
        // SECURITY H-1 — `acceptSelfSignedCerts` is honoured ONLY in
        // DEBUG builds (local dev / unit tests against a self-signed
        // staging box). Release builds NEVER instantiate
        // `SelfSignedCertDelegate`; they fall through to cert pinning
        // (if a pin is configured) or the system default TLS chain.
        #if DEBUG
        if config.acceptSelfSignedCerts {
            self.session = URLSession(configuration: .default, delegate: SelfSignedCertDelegate(), delegateQueue: nil)
        } else if let pin = config.certPinSha256B64 {
            self.session = URLSession(configuration: .default, delegate: CertPinningDelegate(pinB64: pin), delegateQueue: nil)
        } else {
            self.session = URLSession.shared
        }
        #else
        if let pin = config.certPinSha256B64 {
            self.session = URLSession(configuration: .default, delegate: CertPinningDelegate(pinB64: pin), delegateQueue: nil)
        } else {
            self.session = URLSession.shared
        }
        #endif
    }

    /// Install the callback that knows how to perform a token refresh. The
    /// owning `BCryptoBackendProvider` wires this to `BCryptoAccountApiImpl.refreshToken`
    /// after construction to avoid a circular init-time dependency.
    public func setTokenRefresher(_ refresher: @escaping TokenRefresher) {
        self.tokenRefresher = refresher
    }

    /// Phase 2 — install the device-bound silent re-auth fallback.
    /// Called when the primary refresher throws OR when no refresh
    /// token is stored. The fallback is responsible for fetching a
    /// challenge, signing the canonical blob with the device's
    /// Ed25519 key, POSTing /auth/device-renew, and returning the
    /// fresh (access, refresh) pair.
    public func setDeviceRenewFallback(_ fallback: @escaping DeviceRenewFallback) {
        self.deviceRenewFallback = fallback
    }

    public func get(_ path: String, headers: [String: String] = [:]) async throws -> Data {
        try await request("GET", path: path, body: nil, headers: headers)
    }

    public func post(_ path: String, body: Data?, headers: [String: String] = [:]) async throws -> Data {
        try await request("POST", path: path, body: body, headers: headers)
    }

    public func put(_ path: String, body: Data?, headers: [String: String] = [:]) async throws -> Data {
        try await request("PUT", path: path, body: body, headers: headers)
    }

    public func delete(_ path: String, headers: [String: String] = [:]) async throws -> Data {
        try await request("DELETE", path: path, body: nil, headers: headers)
    }

    /// Multipart upload (avatar + fields).
    public func postMultipart(_ path: String, fields: [String: String], fileField: String?, fileData: Data?, headers: [String: String] = [:]) async throws -> Data {
        guard let url = URL(string: config.serverUrl + path) else { throw BCryptoError.invalidUrl }
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token = config.accessToken { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }

        var body = Data()
        for (key, value) in fields {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        if let field = fileField, let data = fileData {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(field)\"; filename=\"avatar.jpg\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw BCryptoError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }

    private func request(_ method: String, path: String, body: Data?, headers: [String: String]) async throws -> Data {
        // First attempt with the currently cached access token.
        let (data, status) = try await performRequest(method, path: path, body: body, headers: headers)
        if (200...299).contains(status) {
            return data
        }

        // On 401, try a single refresh-and-retry cycle. The cascade is:
        //   1. primary tokenRefresher (POST /auth/refresh) — if a
        //      refresh token is stored.
        //   2. 2026-05-06 session-renewal Phase 2 device-renew fallback
        //      (Ed25519 challenge-response) — fired when (1) is absent
        //      or fails, and the request path is not one of the auth
        //      endpoints themselves.
        let isAuthEndpoint = path.hasSuffix("/auth/refresh")
            || path.hasSuffix("/auth/device-renew")
            || path.hasSuffix("/auth/device-challenge")
        if status == 401, !isAuthEndpoint {
            let refreshed = try await tryRefreshToken()
            if refreshed {
                let (retryData, retryStatus) = try await performRequest(method, path: path, body: body, headers: headers)
                if (200...299).contains(retryStatus) {
                    return retryData
                }
                if retryStatus == 401 { throw BCryptoError.unauthorized }
                throw BCryptoError.httpError(retryStatus)
            }
            throw BCryptoError.unauthorized
        }

        if status == 401 { throw BCryptoError.unauthorized }
        throw BCryptoError.httpError(status)
    }

    private func performRequest(_ method: String, path: String, body: Data?, headers: [String: String]) async throws -> (Data, Int) {
        guard let url = URL(string: config.serverUrl + path) else { throw BCryptoError.invalidUrl }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = config.accessToken { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }
        // TODO attest: when App Attest (DCAppAttestService) is wired,
        // attach an OPTIONAL `X-Device-Attest` header HERE for the
        // `/api/v1/register` and `/api/v1/auth/login` paths only. It
        // MUST stay purely additive — the server has to work fine
        // without it (no client lockout, no behavior change if attest
        // generation fails). DEFERRED 2026-05-19: this builder is
        // shared by every endpoint incl. the token-refresh /
        // device-renew / device-challenge cascade (the explicitly
        // fragile auth path), so the attestation key/keyId lifecycle
        // and async generation must be plumbed via an injected
        // `@Sendable () async -> String?` closure on `config` (NOT
        // inline here) to avoid blocking or perturbing refresh. Left
        // unwired to protect the auth flow per directive.
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw BCryptoError.httpError(0) }
        return (data, http.statusCode)
    }

    /// Invoke the installed token refresher at most once per batch of concurrent
    /// 401-affected requests. Returns `true` if the refresh succeeded and
    /// `config.accessToken` was updated; `false` if neither path produced
    /// fresh tokens (caller surfaces 401).
    ///
    /// Cascade: primary `tokenRefresher` (POST /auth/refresh) → on
    /// failure or absence of a refresh token, the Phase 2
    /// `deviceRenewFallback` (Ed25519 challenge-response). Concurrent
    /// 401 callers coalesce on the same in-flight Task so we never
    /// fire two parallel cascades.
    private func tryRefreshToken() async throws -> Bool {
        // Read or create the in-flight task under the lock (non-async closure,
        // so OSAllocatedUnfairLock.withLock is safe here).
        let task: Task<Bool, Error> = refreshLock.withLock {
            if let existing = refreshInFlight { return existing }
            let primary = self.tokenRefresher
            let fallback = self.deviceRenewFallback
            let hasRefreshToken = self.config.refreshToken != nil
            let newTask = Task<Bool, Error> {
                // SECURITY H-2 — release the in-flight slot ONLY after
                // the new tokens have been written to `config`. The old
                // code cleared `refreshInFlight` in an outer `defer`
                // that ran around `task.value`, so a 3rd concurrent 401
                // could observe a nil slot, see the not-yet-written
                // stale `config.accessToken`, and spawn a *second*
                // refresh with the stale token. Holding the slot for
                // the full refresh + config-update window and clearing
                // it here makes the release atomic with the token swap.
                defer { self.refreshLock.withLock { self.refreshInFlight = nil } }
                // Step 1: try the primary refresher (POST /auth/refresh).
                if let refresher = primary, hasRefreshToken {
                    do {
                        let pair = try await refresher()
                        self.config.accessToken = pair.accessToken
                        if let newRefresh = pair.refreshToken { self.config.refreshToken = newRefresh }
                        return true
                    } catch {
                        // Fall through to the device-renew fallback.
                    }
                }
                // Step 2: device-bound silent re-auth (Phase 2).
                if let fallback {
                    do {
                        let pair = try await fallback()
                        self.config.accessToken = pair.accessToken
                        if let newRefresh = pair.refreshToken { self.config.refreshToken = newRefresh }
                        return true
                    } catch {
                        return false
                    }
                }
                return false
            }
            refreshInFlight = newTask
            return newTask
        }

        // NOTE (H-2): no outer `defer` clearing `refreshInFlight` here —
        // the slot is owned and released by the Task's own `defer`
        // above, AFTER `config` is updated, so the release is atomic
        // with the token swap. Persisting the refreshed tokens to the
        // Keychain (TokenVault) is done at the app layer: the installed
        // `tokenRefresher` / `deviceRenewFallback` closures (AppState)
        // write the new pair, and `AuthService.loadToken()` sweeps any
        // plaintext copy into the Keychain on the next cold start.
        return try await task.value
    }

    /// The base server URL from the current configuration.
    public var serverUrl: String { config.serverUrl }

    /// The user ID from the current configuration, if authenticated.
    public var userId: String? { config.userId }

    /// W443: current access token — used by TusUploadClient so it always
    /// reads the freshest token without holding a config reference.
    public var accessToken: String? { config.accessToken }

    /// Current refresh token — used by the WS auth-recovery bridge so the
    /// provider can re-broadcast the post-recovery pair to every transport
    /// (the cascade writes the fresh tokens into THIS client's config only).
    public var refreshToken: String? { config.refreshToken }

    /// W443: underlying URLSession — shared with TusUploadClient so both
    /// use the same TLS delegate (cert-pinning / self-signed-cert).
    public var urlSession: URLSession { session }

    public func updateConfig(_ newConfig: BackendConfig) { config = newConfig }

    /// Always-reachable Phase 2 — public entry point that runs the SAME silent
    /// token-recovery cascade as the 401-retry path (primary `tokenRefresher`
    /// POST /auth/refresh → Ed25519 `deviceRenewFallback` device-renew), used
    /// by the WebSocket client when the server rejects its token with
    /// `auth_failed`. Returns `true` if a fresh token was obtained (the
    /// installed closures already wrote it into `config` and broadcast it via
    /// the provider's `applyTokenPair`), `false` on genuine revocation.
    /// Concurrent callers coalesce on the same in-flight Task as the 401 path.
    /// Never throws to the caller — recovery failure is reported as `false` so
    /// the WS client can park its loop without QR.
    public func recoverAuth() async -> Bool {
        do {
            return try await tryRefreshToken()
        } catch {
            return false
        }
    }
}

public enum BCryptoError: Error {
    case invalidUrl
    case httpError(Int)
    case decodingError
    case unauthorized
    case notFound
    case certPinningFailed
    /// Server responded 200 but payload signalled a domain error via a
    /// string field (e.g. recovery-setup `{enrolled:false, error:"..."}`).
    case server(String)
}

// MARK: - Certificate Pinning Delegate

// SECURITY C-6 — internal (not `private`) so `BCryptoWebSocketClient`
// in the same module reuses this exact DER-SHA256 pinning logic for
// the WS `URLSession` instead of running with no pinning at all.
final class CertPinningDelegate: NSObject, URLSessionDelegate {
    /// Set of pinned DER SHA-256 hashes (base64-decoded). Multiple pins are
    /// supported: `pinB64` is a comma-separated list of base64 strings.
    /// A TLS handshake succeeds iff at least one cert in the server's chain
    /// has a DER SHA-256 that appears in this set.
    ///
    /// Design rationale: pinning the chain (not just the leaf) means
    /// the app survives Let's Encrypt 90-day leaf rotation as long as the
    /// intermediate CA hash is included. See `PinnedServerHost.certChainPins`.
    private let pinnedHashes: Set<Data>

    init(pinB64: String) {
        var hashes = Set<Data>()
        for token in pinB64.split(separator: ",") {
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            if let d = Data(base64Encoded: trimmed) {
                hashes.insert(d)
            }
        }
        self.pinnedHashes = hashes
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust,
              !pinnedHashes.isEmpty else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // IOS-MEDIUM (audit 2026-06-12): require the system's standard trust
        // evaluation to PASS before the pin check. The serverTrust carried by a
        // URLSession server-trust challenge already has the default SSL policy
        // (hostname + validity + chain-to-trusted-anchor) attached, so this
        // enforces that the cert is genuinely valid for THIS host. Without it,
        // because the pin set anchors on a public root (ISRG Root X1 / LE
        // intermediates) to survive 90-day leaf rotation, any cert chaining to
        // that public root for ANY hostname would satisfy the pin. The pin is
        // an ADDITIONAL constraint layered on top of — not a replacement for —
        // standard trust. Fail closed on evaluation error.
        var trustEvalError: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &trustEvalError) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Walk every cert in the server's TLS chain; accept if ANY cert's
        // DER SHA-256 matches one of the pinned hashes.
        guard let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              !chain.isEmpty else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        for cert in chain {
            let derData = SecCertificateCopyData(cert) as Data
            var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            derData.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(derData.count), &hash) }
            if pinnedHashes.contains(Data(hash)) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
        }

        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}

// MARK: - Self-Signed Cert Delegate

// SECURITY H-1 — DEBUG-only. This delegate blindly trusts any server
// cert; compiling it into a Release build would be a permanent MITM
// backdoor. The `#if DEBUG` guard guarantees Release binaries cannot
// even reference it.
#if DEBUG
private class SelfSignedCertDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else { completionHandler(.performDefaultHandling, nil) }
    }
}
#endif

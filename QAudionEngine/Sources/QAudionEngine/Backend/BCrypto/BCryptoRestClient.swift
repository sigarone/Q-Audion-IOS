import Foundation
import CommonCrypto
import os
import Network

public final class BCryptoRestClient {
    /// Callback invoked (through `AuthRefreshCoordinator`) when a protected request
    /// returns HTTP 401. Implementations call POST /api/v1/auth/refresh with the
    /// refresh token they are GIVEN — the coordinator reads it from the shared
    /// credential store, so a long-lived client never presents its own stale copy —
    /// and return the new tokens. They must NOT write them anywhere: persistence is
    /// the coordinator's compare-and-swap. If refresh fails the callback throws and
    /// the cascade continues with the device-renew fallback.
    public typealias TokenRefresher = @Sendable (_ refreshToken: String) async throws -> AuthTokenSet

    /// 2026-05-06 session-renewal Phase 2 — Ed25519 device-bound silent
    /// re-auth fallback. Invoked when the primary `tokenRefresher`
    /// throws (refresh token rejected or absent). On success returns
    /// the fresh tokens (not persisted by the closure, see above) and the
    /// 401-retry proceeds; on failure the caller surfaces
    /// `BCryptoError.unauthorized`.
    public typealias DeviceRenewFallback = @Sendable () async throws -> AuthTokenSet

    private var config: BackendConfig
    /// The server this client was BUILT with — the certificate-pinned primary,
    /// captured once at init and never reassigned by updateConfig.
    ///
    /// Only the primary holds the token-signing key, so anything that mints has
    /// to reach it even after the node selector has moved everything else
    /// somewhere nearer. Captured rather than read from a response on purpose: a
    /// server naming the host to retry against is a redirect a client must never
    /// learn to follow.
    private let primaryServerUrl: String
    private let session: URLSession
    private var tokenRefresher: TokenRefresher?
    private var deviceRenewFallback: DeviceRenewFallback?
    /// The ONE refresh single-flight of the process. Every path that refreshes the
    /// session (REST 401, socket `auth_failed`, the app's proactive refresh, the tus
    /// client) goes through it, so two refreshes are never in flight with the same
    /// refresh token no matter how many clients exist. Tests inject their own instance.
    public var authCoordinator: AuthRefreshCoordinator = .shared
    /// The app's shared credential store (Keychain). When set, the refresh token is read
    /// from it and results are written back with compare-and-swap; when nil (onboarding,
    /// tests) this client uses its own config copy and persists nothing.
    public var credentialStore: AuthCredentialStore?
    /// Called, for every caller of a coordinated refresh, with the tokens it should now
    /// use. The owning provider wires it to broadcast them to every transport.
    public var onTokensApplied: (@Sendable (AuthTokenSet) -> Void)?

    // MARK: - IOS-E2 — anti-zombie-pool HTTP trio + W-INFLIGHTCANCEL
    //
    // Mirror of Android's `StaleConnectionEvictor` + `NetworkBoundCallRegistry`
    // (core/core-data/.../net/StaleConnectionEvictor.kt) — SAME invariant
    // ("nothing on the handshake hot path waits out a dead pooled
    // connection"), DIFFERENT mechanism, because `URLSession` exposes none of
    // OkHttp's introspection: no `connectionPool`, no per-call `Call` handle
    // to cancel from outside, no `pingInterval()` builder knob. What Foundation
    // DOES give us, checked against `URLSession`'s public API surface:
    //   - `URLSession.reset(completionHandler:)` — "Empties all cookies,
    //     caches and credential stores, removes disk files, flushes
    //     in-progress downloads to disk, and ensures that future requests
    //     occur on a new socket." That last clause is the pool-evict
    //     equivalent of `OkHttpClient.connectionPool.evictAll()` — the
    //     closest public analogue that exists.
    //   - No public HTTP/2 PING knob exists on `URLSessionConfiguration`, so
    //     leg (2) below is a DIFFERENT mechanism for the SAME invariant
    //     ("a dead connection fails fast instead of hanging out the full
    //     default timeout"): a bounded `timeoutIntervalForRequest`, tight
    //     enough that no request — identity-key fetch included, the exact
    //     endpoint that hung 47.7 s on Android's zombie socket — can silently
    //     sit for anywhere near that long.
    //   - No handle to the underlying `URLSessionTask` comes back from the
    //     async `session.data(for:)` API used by `performRequest` below.
    //     What Swift's structured concurrency DOES give us: `data(for:)` is
    //     documented to observe cooperative cancellation — cancelling the
    //     `Task` that awaits it cancels the underlying request. `request()`
    //     below wraps each call in its own `Task`, keyed by the network
    //     generation live when it started, so a genuine network change can
    //     cancel every Task whose generation is now stale — the per-call
    //     filter Android's `cancelCallsNotOn(netId)` applies, restated in
    //     Task-cancellation terms instead of `Call.cancel()`.
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "com.qaudion.rest.pathmonitor", qos: .utility)
    private let netLock = NSLock()
    private var _networkGeneration: Int = 0
    private var _isOffline: Bool = false
    // `nil` = no path observation yet (distinct from "was previously
    // unsatisfied"). BUGFIX (2026-08-26): this used to default to `false`,
    // so a fresh client's very FIRST NWPathMonitor callback — which fires
    // shortly after `.start()` reporting the CURRENT path, not a change —
    // read as satisfied(true) != _lastPathSatisfied(false) on the common
    // case (device already has network), triggering a gratuitous pool
    // evict + in-flight-request cancel before the client had done
    // anything. Real symptom: 4 of the WireFormatTests suite's requests,
    // issued immediately after construction, raced this synthetic
    // "change" and were cancelled with NSURLErrorDomain -999 in CI even
    // after the DEBUG-gate fix (b141949) — confirmed via the
    // "[BCryptoRest] netchange satisfied=1 gen=1 cancelled=1" log line
    // printed at the moment of failure. See `handlePathUpdate` below for
    // the fix (first observation is recorded, not treated as a change).
    private var _lastPathSatisfied: Bool?
    private var _lastTransport: NWInterface.InterfaceType?

    /// W-INFLIGHTCANCEL — in-flight request cancellers, keyed by a per-call
    /// id, each tagged with the network generation live when that request
    /// started. A genuine network change cancels every entry whose
    /// generation predates the new one; a request that started on the
    /// CURRENT network is never touched (never a blanket cancel-all).
    private var inFlightCancellers: [UUID: (cancel: () -> Void, generation: Int)] = [:]
    private let inFlightLock = NSLock()

    /// Offline-aware identity-resolve — true iff the path monitor's most
    /// recent report was `.unsatisfied` (no usable network transport at
    /// all). Read by `BCryptoKmsClient`'s identity-key fetches so a call
    /// placed while offline (airplane mode, dead zone) returns immediately
    /// instead of burning `timeoutIntervalForRequest` finding out the hard
    /// way — the "bounded" half of "identity resolve offline-aware e
    /// bounded" (playbook §IOS-E2).
    public var isOffline: Bool {
        netLock.lock(); defer { netLock.unlock() }
        return _isOffline
    }

    /// - Parameter testURLProtocolClasses: test-only hook, honoured in EVERY
    ///   build configuration (not DEBUG-gated — CI runs tests with
    ///   `-configuration Release`, so a DEBUG-only version of this would be
    ///   silently inert there). Since IOS-E2 below made this client always
    ///   build its own dedicated `URLSession` instead of falling back to
    ///   `.shared`, a request-stubbing `URLProtocol` subclass registered
    ///   process-wide via `URLProtocol.registerClass()` is no longer
    ///   reliably picked up — that global mechanism is guaranteed for
    ///   `.shared`, not for a freshly-constructed session. Passing the stub
    ///   class here installs it directly on THIS instance's
    ///   `sessionConfig.protocolClasses`. `nil` for every real caller in
    ///   every configuration, so this has no production effect (unlike
    ///   `acceptSelfSignedCerts` below, which IS a real DEBUG-only security
    ///   trade-off — SECURITY H-1 — and stays gated).
    public init(config: BackendConfig, testURLProtocolClasses: [AnyClass]? = nil) {
        self.primaryServerUrl = config.serverUrl
        self.config = config
        // SECURITY H-1 — `acceptSelfSignedCerts` is honoured ONLY in
        // DEBUG builds (local dev / unit tests against a self-signed
        // staging box). Release builds NEVER instantiate
        // `SelfSignedCertDelegate`; they fall through to cert pinning
        // (if a pin is configured) or the system default TLS chain.
        //
        // IOS-E2: always a DEDICATED session (never `URLSession.shared`).
        // `.reset()` (the pool-evict leg below) affects every consumer of
        // whichever session it's called on; sharing `.shared` would evict
        // connections for unrelated `.shared` callers elsewhere in the app
        // on every one of THIS client's network-change events. TLS
        // behaviour is unchanged: the branch that used to fall through to
        // `.shared` (no pin, no self-signed override) gets a plain
        // `URLSessionConfiguration.default` session with no custom
        // delegate — identical system-default chain validation to what
        // `.shared` was already doing.
        let sessionConfig = URLSessionConfiguration.default
        // IOS-E2 leg (2) — bounded request timeout, the fail-fast substitute
        // for OkHttp's HTTP/2 `pingInterval(10s)` (no equivalent knob exists
        // on `URLSessionConfiguration`). Default is 60 s; this is the number
        // that let Android's identity-key fetch hang 47.7 s on a zombie
        // pooled connection before the PING probe existed.
        sessionConfig.timeoutIntervalForRequest = 15
        // Applied UNCONDITIONALLY (not inside the #if DEBUG below): CI runs
        // `xcodebuild test` with `-configuration Release` (forced there for
        // an unrelated OOM fix — see engine-tests.yml's own comment on that
        // flag), so a DEBUG-gated stub install is silently inert in exactly
        // the environment these tests run in, and every WireFormatTests call
        // site hit the real network against https://test.local instead of
        // the stub (confirmed: this was live-broken in CI even after the
        // stub-wiring fix landed, traced to this exact gate). Safe to hoist
        // out: `testURLProtocolClasses` is nil for every real caller in both
        // configurations, so this has zero effect outside tests either way.
        // The self-signed-cert/cert-pinning delegate choice below stays
        // Release-gated as originally intended (SECURITY H-1) — this only
        // moves the unrelated test-injection hook, not that security logic.
        if let testProtocols = testURLProtocolClasses {
            sessionConfig.protocolClasses = testProtocols
        }
        #if DEBUG
        if config.acceptSelfSignedCerts {
            self.session = URLSession(configuration: sessionConfig, delegate: SelfSignedCertDelegate(), delegateQueue: nil)
        } else if let pin = config.certPinSha256B64 {
            self.session = URLSession(configuration: sessionConfig, delegate: CertPinningDelegate(pinB64: pin), delegateQueue: nil)
        } else {
            self.session = URLSession(configuration: sessionConfig, delegate: nil, delegateQueue: nil)
        }
        #else
        if let pin = config.certPinSha256B64 {
            self.session = URLSession(configuration: sessionConfig, delegate: CertPinningDelegate(pinB64: pin), delegateQueue: nil)
        } else {
            self.session = URLSession(configuration: sessionConfig, delegate: nil, delegateQueue: nil)
        }
        #endif
        startNetworkMonitor()
    }

    deinit {
        pathMonitor.cancel()
    }

    // MARK: - IOS-E2 network-change reaction

    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path)
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    /// React to EVERY genuine network-kind change, including the
    /// satisfied→unsatisfied edge (network lost entirely) — mirrored from
    /// Android's evictor comment verbatim: the pool is just as dead on a
    /// local outage, and evicting is free, so there is no reason to gate
    /// this narrower than the WS client's flap-storm debounce does (that
    /// debounce protects a live authenticated socket from being torn down;
    /// nothing here is a standing connection worth protecting the same way
    /// — a pool evict + stale-Task cancel is idempotent and cheap even if
    /// it fires on a flapping path).
    private func handlePathUpdate(_ path: NWPath) {
        let satisfied = (path.status == .satisfied)
        let transport: NWInterface.InterfaceType? = satisfied
            ? path.availableInterfaces.first(where: { $0.type != .loopback })?.type
            : nil

        netLock.lock()
        // First-ever observation: NWPathMonitor.start() always delivers one
        // callback reporting the CURRENT path, which is not a "change" —
        // there is nothing to evict a pool for or cancel in-flight
        // requests against yet. Record the baseline and stop; only a
        // REAL subsequent transition (satisfied/transport actually
        // flipping from a KNOWN prior state) reaches the evict+cancel path
        // below.
        guard let lastSatisfied = _lastPathSatisfied else {
            _lastPathSatisfied = satisfied
            _lastTransport = transport
            _isOffline = !satisfied
            netLock.unlock()
            return
        }
        let changed = (satisfied != lastSatisfied) || (transport != _lastTransport)
        _lastPathSatisfied = satisfied
        _lastTransport = transport
        _isOffline = !satisfied
        guard changed else { netLock.unlock(); return }
        _networkGeneration &+= 1
        let generation = _networkGeneration
        netLock.unlock()

        // (1) Pool evict — see the class-level kdoc for why `.reset()` is
        // the mechanism here.
        session.reset {}

        // (4) W-INFLIGHTCANCEL — cancel every request whose captured
        // generation is now stale. Never a blanket cancel: a request that
        // started on the network we just moved TO (generation already
        // matches) is left alone.
        inFlightLock.lock()
        let stale = inFlightCancellers.filter { $0.value.generation != generation }
        inFlightLock.unlock()
        for (_, entry) in stale {
            entry.cancel()
        }

        // Numeric tail, lowercase greppable tag — iOS log-line rule.
        let line = "[BCryptoRest] netchange satisfied=\(satisfied ? 1 : 0) gen=\(generation) cancelled=\(stale.count)"
        print(line)
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

        // Data(_:) over the interpolated strings below instead of
        // .data(using: .utf8)! — String.utf8 (unlike .data(using:)) is a
        // non-optional view and UTF-8 can encode any valid Swift String
        // regardless of what boundary/key/value/field interpolate in, so
        // this can never fail; genuinely eliminates the optional rather
        // than just silencing the warning (same fix as HkdfLabels.swift).
        var body = Data()
        for (key, value) in fields {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }
        if let field = fileField, let data = fileData {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(field)\"; filename=\"avatar.jpg\"\r\n".utf8))
            body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
            body.append(data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        req.httpBody = body

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw BCryptoError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }

    /// W-INFLIGHTCANCEL — public chokepoint every `get`/`post`/`put`/`delete`
    /// funnels through. Wraps the real request in its own `Task`, registered
    /// under the network generation live when it started, so a network
    /// change (`handlePathUpdate` above) can cancel it outright instead of
    /// letting it run out `timeoutIntervalForRequest` on a connection that
    /// belonged to the network we just left. `session.data(for:)` inside
    /// `requestUncancellable` is Foundation's async URLSession API, which
    /// is documented to participate in cooperative `Task` cancellation —
    /// cancelling the wrapping `Task` cancels the underlying
    /// `URLSessionTask`. NOTE (honesty per playbook §0.8): that propagation
    /// is Apple's documented behaviour for `data(for:)`, not something this
    /// session could verify on-device (no Swift toolchain / iOS device in
    /// this environment) — the orchestrator's live handoff test is what
    /// closes that gap.
    private func request(_ method: String, path: String, body: Data?, headers: [String: String],
                          baseUrlOverride: String? = nil) async throws -> Data {
        let id = UUID()
        // W-ASYNCLOCK (2026-08-29) — scoped `withLock` rather than a bare
        // `lock()`/`unlock()` pair. This function is `async`, and manual
        // lock/unlock around a suspension point is unavailable from an
        // asynchronous context (a hard error in the Swift 6 language mode):
        // the two calls can land on different threads, and a suspension
        // between them would hold the lock across an await. The scoped form
        // is non-async and cannot span a suspension by construction, which
        // is the property that makes it safe. Same semantics as before —
        // the critical sections were already suspension-free.
        let generation = netLock.withLock { _networkGeneration }
        let task = Task<Data, Error> {
            try await self.requestUncancellable(method, path: path, body: body, headers: headers,
                                                 baseUrlOverride: baseUrlOverride)
        }
        inFlightLock.withLock {
            inFlightCancellers[id] = (cancel: { task.cancel() }, generation: generation)
        }
        defer {
            inFlightLock.withLock { _ = inFlightCancellers.removeValue(forKey: id) }
        }
        return try await task.value
    }

    private func requestUncancellable(_ method: String, path: String, body: Data?, headers: [String: String],
                                       baseUrlOverride: String? = nil) async throws -> Data {
        // First attempt with the currently cached access token.
        let (data, status, retryAfter) = try await performRequest(method, path: path, body: body, headers: headers,
                                                           baseUrlOverride: baseUrlOverride)
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
        // The challenge GET carries `?device_id=...`, which a plain `hasSuffix` never matched.
        let pathOnly = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? path
        let isAuthEndpoint = pathOnly.hasSuffix("/auth/refresh")
            || pathOnly.hasSuffix("/auth/device-renew")
            || pathOnly.hasSuffix("/auth/device-challenge")
        // The session-recovery endpoints are rate-limited per device and per IP and answer
        // 429 with `Retry-After`. `httpError(Int)` cannot carry the header, and the recovery
        // coordinator must honour it, so these (and only these) endpoints throw a typed error.
        if status == 429, isAuthEndpoint {
            throw BCryptoRateLimitedError(retryAfterSec: BCryptoRateLimitedError.parse(retryAfter))
        }
        if status == 401, !isAuthEndpoint {
            let refreshed = try await tryRefreshToken()
            if refreshed {
                let (retryData, retryStatus, _) = try await performRequest(method, path: path, body: body, headers: headers,
                                                                            baseUrlOverride: baseUrlOverride)
                if (200...299).contains(retryStatus) {
                    return retryData
                }
                if retryStatus == 401 { throw BCryptoError.unauthorized }
                // W-B10PAYREQ (2026-09-02) — same mapping as the primary
                // attempt below, applied here too so a 402 landing on the
                // post-refresh retry isn't left as the generic httpError
                // just because it arrived one attempt later.
                if retryStatus == 402 { throw BCryptoError.paymentRequired }
                throw BCryptoError.httpError(retryStatus)
            }
            throw BCryptoError.unauthorized
        }

        // 421 from a node that cannot issue tokens: the request reached the
        // wrong address, not a broken server. Retry once against the pinned
        // primary and leave config.serverUrl alone — this is a per-request
        // redirect, not a decision to abandon the node the selector chose for
        // everything else. Skipped when this request already targeted the
        // primary (baseUrlOverride) — a 421 from the primary itself is not
        // fixed by retrying the primary again.
        let effectiveBase = baseUrlOverride ?? config.serverUrl
        if status == 421, effectiveBase != primaryServerUrl {
            let (retryData, retryStatus, _) = try await performRequest(
                method, path: path, body: body, headers: headers,
                baseUrlOverride: primaryServerUrl)
            if (200...299).contains(retryStatus) {
                return retryData
            }
            if retryStatus == 401 { throw BCryptoError.unauthorized }
            if retryStatus == 402 { throw BCryptoError.paymentRequired }
            throw BCryptoError.httpError(retryStatus)
        }

        if status == 401 { throw BCryptoError.unauthorized }
        // W-B10PAYREQ (2026-09-02) — the primary chokepoint: a plain
        // non-2xx first attempt (not a 401/421 retry) is how the
        // overwhelming majority of a real 402 reaches this client — see
        // `BCryptoError.paymentRequired`'s own doc for why this is a bare
        // status check, no response-body parsing.
        if status == 402 { throw BCryptoError.paymentRequired }
        throw BCryptoError.httpError(status)
    }

    private func performRequest(_ method: String, path: String, body: Data?, headers: [String: String],
                                baseUrlOverride: String? = nil) async throws -> (Data, Int, String?) {
        guard let url = URL(string: (baseUrlOverride ?? config.serverUrl) + path) else { throw BCryptoError.invalidUrl }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = config.accessToken { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }
        // Device attestation is not used for register/login.
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw BCryptoError.httpError(0) }
        return (data, http.statusCode, http.value(forHTTPHeaderField: "Retry-After"))
    }

    // MARK: - Item A-iOS + G (2026-09-30 file-transfer plan, phase 1a)

    /// POST that always targets the pinned primary node instead of
    /// `config.serverUrl`. File endpoints (tus create/PATCH/HEAD, and
    /// `POST /files/issue-token`, which this backs) exist ONLY on the
    /// node that actually stores the file. The general node selector
    /// (`ServerSelector`, app layer) can legitimately move
    /// `config.serverUrl` to a DR/failover host (e.g. a Helsinki
    /// dev/DR box) for calling/signaling reasons — that host has no
    /// shared file storage and answers a tus create with 402
    /// ("abbonamento file mancante"). Every other behaviour (401
    /// refresh-and-retry, 402 mapping) is identical to
    /// `post(_:body:headers:)`; this only pins the base URL. Not
    /// `public` — every current caller (`BCryptoDownloadTokenClient`,
    /// `BCryptoStorageApiImpl`) lives in this module.
    func postToPrimary(_ path: String, body: Data?, headers: [String: String] = [:]) async throws -> Data {
        try await request("POST", path: path, body: body, headers: headers, baseUrlOverride: primaryServerUrl)
    }

    /// The certificate-pinned primary this client was constructed
    /// against — see `primaryServerUrl`'s own doc for why it never
    /// changes after `updateConfig`. `public` (not module-internal
    /// anymore) since `AppState.filesServerUrl` (QAudionApp) also reads
    /// this now, for the same reason the in-module callers
    /// (`BCryptoDownloadTokenClient`, `BCryptoStorageApiImpl`) do: legacy
    /// `/api/v1/files/{id}` avatar/thumbnail URLs must keep pointing at
    /// the node that actually stores the file even after `ServerSelector`
    /// moves `serverUrl` to a failover node with no shared storage
    /// (item G).
    public var pinnedPrimaryServerUrl: String { primaryServerUrl }

    /// One request attempt against the pinned primary, refreshing the
    /// access token once on a 401 — the same single refresh-and-retry
    /// bound `requestUncancellable` applies, just without its 421/402
    /// throw-on-status behaviour (the caller, `getFileEndpoint`, needs
    /// the raw status + `Retry-After` to drive its own retry loop).
    private func requestFileAttemptFromPrimary(
        method: String, path: String, headers: [String: String]
    ) async throws -> (data: Data, status: Int, retryAfter: String?) {
        let (data, status, retryAfter) = try await performRequest(
            method, path: path, body: nil, headers: headers, baseUrlOverride: primaryServerUrl)
        guard status == 401, try await tryRefreshToken() else {
            return (data, status, retryAfter)
        }
        let (retryData, retryStatus, retryRetryAfter) = try await performRequest(
            method, path: path, body: nil, headers: headers, baseUrlOverride: primaryServerUrl)
        return (retryData, retryStatus, retryRetryAfter)
    }

    /// Escalating backoff used when the server sends no usable
    /// `Retry-After`: 1s, 2s, 4s. Client-side retry pacing only —
    /// unrelated to the server/desktop progress-based request timeouts
    /// the 2026-09-30 file-transfer design covers separately.
    private static let defaultBackoffSecs: [Double] = [1, 2, 4]

    /// Delay before the next attempt of `getFileEndpoint`'s retry loop.
    /// Honours an RFC 7231 delta-seconds `Retry-After` (the only form
    /// this server's file endpoints send — never an HTTP-date) when
    /// present and positive, capped at 30s so a misbehaving/huge value
    /// can't stall the loop far beyond this client's own 15s
    /// single-request timeout budget; otherwise falls back to the fixed
    /// escalating schedule. **Visible for tests.**
    static func retryDelayNanos(afterHeader: String?, attempt: Int) -> UInt64 {
        if let afterHeader,
           let secs = Double(afterHeader.trimmingCharacters(in: .whitespaces)),
           secs > 0 {
            return UInt64(min(secs, 30) * 1_000_000_000)
        }
        let idx = min(max(attempt, 0), defaultBackoffSecs.count - 1)
        return UInt64(defaultBackoffSecs[idx] * 1_000_000_000)
    }

    /// GET dedicated to file downloads (tus recipient-token / owner-direct
    /// — `BCryptoDownloadTokenClient.downloadCiphertext`,
    /// `BCryptoStorageApiImpl.downloadFile`). Two departures from
    /// `get(_:headers:)`:
    ///   - Always targets the pinned primary node (see `postToPrimary`'s
    ///     doc for why) instead of `config.serverUrl` (item G).
    ///   - Retries a transient 429/5xx up to `maxAttempts` times,
    ///     honouring the server's `Retry-After` header when present
    ///     (item A: `ChatFileAttachmentReceiver` used to download the
    ///     whole ciphertext blob in ONE request with no retry and no
    ///     resume — this is the narrower "don't give up after one
    ///     shot" fix, NOT the full streaming/ranged-GET rewrite left
    ///     for phase 1b).
    /// 401 is refreshed-and-retried first, exactly as every other
    /// request this client makes. Any non-2xx status left after
    /// retries throws `BCryptoError`, same mapping as `get(_:headers:)`.
    /// Not `public` — every current caller lives in this module.
    func getFileEndpoint(
        _ path: String,
        headers: [String: String] = [:],
        maxAttempts: Int = 4
    ) async throws -> Data {
        precondition(maxAttempts >= 1)
        var lastStatus = 0
        for attempt in 0..<maxAttempts {
            let (data, status, retryAfter) = try await requestFileAttemptFromPrimary(
                method: "GET", path: path, headers: headers)
            if (200...299).contains(status) { return data }
            lastStatus = status
            let isRetryable = status == 429 || (500...599).contains(status)
            let isLastAttempt = attempt == maxAttempts - 1
            guard isRetryable, !isLastAttempt else { break }
            let delay = Self.retryDelayNanos(afterHeader: retryAfter, attempt: attempt)
            try? await Task.sleep(nanoseconds: delay)
        }
        if lastStatus == 401 { throw BCryptoError.unauthorized }
        if lastStatus == 402 { throw BCryptoError.paymentRequired }
        throw BCryptoError.httpError(lastStatus)
    }

    /// Run the session-recovery cascade for a 401-affected request. Returns `true` if
    /// fresh tokens are now available in this client's `config` (from the network or
    /// adopted from the shared store); `false` if the cascade failed (caller surfaces 401).
    ///
    /// The cascade itself (primary `tokenRefresher` = POST /auth/refresh, then the Phase 2
    /// `deviceRenewFallback`) and its single flight live in `AuthRefreshCoordinator`, which
    /// is shared by every client in the process: concurrent 401 callers, the socket's
    /// `auth_failed` recovery and the app's proactive refresh all await ONE network call.
    private func tryRefreshToken() async throws -> Bool {
        let outcome = await refreshSession(trigger: .rest401)
        return outcome.isSuccess
    }

    /// Run (or join) the coordinated session recovery and apply the result to this client.
    /// Never throws: failure is a value carrying a reason code.
    ///
    /// Every caller of a shared flight applies the tokens to its own config here, so a
    /// client that merely joined the flight (or adopted a pair rotated elsewhere) ends up
    /// on the same tokens as the one that did the network call.
    public func refreshSession(trigger: AuthRefreshTrigger,
                               ignoreCooldown: Bool = false) async -> AuthRefreshOutcome {
        let request = AuthRefreshRequest(
            trigger: trigger,
            staleAccessToken: trigger.adoptsNewerStoredAccess ? config.accessToken : nil,
            callerRefreshToken: config.refreshToken,
            store: credentialStore,
            refresher: tokenRefresher.map { Self.wrapRefresher($0) },
            renewer: deviceRenewFallback.map { Self.wrapRenewer($0) },
            ignoreCooldown: ignoreCooldown)
        let outcome = await authCoordinator.refresh(request)
        if let tokens = outcome.tokens {
            config.accessToken = tokens.accessToken
            if let newRefresh = tokens.refreshToken, !newRefresh.isEmpty { config.refreshToken = newRefresh }
            onTokensApplied?(tokens)
        }
        return outcome
    }

    /// Classify whatever the closures throw into reason codes, once, at the boundary.
    private static func wrapRefresher(_ refresher: @escaping TokenRefresher) -> AuthRefreshRequest.Refresher {
        return { (token: String) async throws -> AuthTokenSet in
            do {
                return try await refresher(token)
            } catch {
                throw AuthFailureClassifier.classifyRefresh(error)
            }
        }
    }

    private static func wrapRenewer(_ renewer: @escaping DeviceRenewFallback) -> AuthRefreshRequest.Renewer {
        return { () async throws -> AuthTokenSet in
            do {
                return try await renewer()
            } catch {
                throw AuthFailureClassifier.classifyRenew(error)
            }
        }
    }

    /// The base server URL from the current configuration.
    public var serverUrl: String { config.serverUrl }

    /// The user ID from the current configuration, if authenticated.
    public var userId: String? { config.userId }

    /// W443: current access token — used by TusUploadClient so it always
    /// reads the freshest token without holding a config reference.
    public var accessToken: String? { config.accessToken }

    /// W-TUSAUTHREFRESH (2026-08-29) — run this client's own token-refresh
    /// cascade on behalf of a component that builds its requests by hand
    /// and therefore cannot go through `requestUncancellable`'s built-in
    /// 401 refresh-and-retry (today: `TusUploadClient`, whose tus PATCH/
    /// HEAD semantics need raw header and offset control the JSON helpers
    /// do not expose).
    ///
    /// Same cascade, same coalescing, same `config.accessToken` update as
    /// the internal path — this only widens WHO may ask, never what
    /// happens. Returns `true` when a fresh access token is available.
    public func refreshAccessTokenForExternalClient() async throws -> Bool {
        await refreshSession(trigger: .external).isSuccess
    }

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
        await refreshSession(trigger: .wsAuthFailed).isSuccess
    }
}

/// HTTP 429 from one of the session-recovery endpoints (`/auth/refresh`, `/auth/device-challenge`,
/// `/auth/device-renew`), carrying the server's `Retry-After`. A separate type, not a case of
/// `BCryptoError`: that enum is switched exhaustively across the app and every other 429 keeps
/// arriving as `BCryptoError.httpError(429)`. Only `AuthFailureClassifier` consumes this.
public struct BCryptoRateLimitedError: Error, Sendable, Equatable {
    /// `Retry-After` in whole seconds when the server sent a delta-seconds value, else nil.
    public let retryAfterSec: Int?

    public init(retryAfterSec: Int?) {
        self.retryAfterSec = retryAfterSec
    }

    /// RFC 7231 delta-seconds only (the one form this server sends); an HTTP-date, a negative
    /// or an unparsable value is nil. Capped at an hour.
    static func parse(_ header: String?) -> Int? {
        guard let header,
              let secs = Double(header.trimmingCharacters(in: .whitespaces)),
              secs.isFinite, secs > 0 else { return nil }
        return Int(min(secs, 3600).rounded(.up))
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
    /// W-B1CRASHFRAME (2026-09-02) — `BCryptoBackendProvider.accountApi` is a
    /// public `var` (always `BCryptoAccountApiImpl` today, the only
    /// constructor site) that the token-refresher closure downcasts to reach
    /// `refreshToken(_:)`. Was `as!`; a future caller assigning a different
    /// `AccountApi` conformer there would otherwise crash the process on the
    /// very next 401 instead of failing this one refresh.
    case unexpectedAccountApiImplementation
    /// W-B10PAYREQ (2026-09-02) — HTTP 402, this app's server-side
    /// entitlement-denial status (`requireFeatureHTTP`/`requireAnyFeatureHTTP`
    /// in `entitlements_enforce.go`: "design doc §4.5 typed 402 body",
    /// written whenever a caller's current grant doesn't cover the `feat.*`
    /// capability a request needs). Previously indistinguishable from any
    /// other client error on THIS client — arrived as the generic
    /// `httpError(402)`, so no call site could show a dedicated "serve un
    /// account Pro" message instead of a raw status code (2026-09-01
    /// stability audit, item B10). Bare case, no associated status/body:
    /// matches this file's own existing convention for `.unauthorized`/
    /// `.notFound`/`.certPinningFailed`, and `performRequest` already
    /// discards the response BODY for every non-2xx status (see
    /// `UpgradeSheet.swift`'s `redemptionErrorMessage` doc for why parsing
    /// the `{"error","feature","package"}` shape server-side would need a
    /// wider, out-of-scope change to this type's error contract).
    ///
    /// SCOPE NOTE: the server writes this same 402 body for VPN and
    /// files-tus denials too, but on iOS those go through their OWN
    /// request paths with their OWN error types (`VpnApiService
    /// .VpnApiError.httpError(Int, String)`, `TusUploadClient
    /// .TusError.createFailed(Int)`/`.patchFailed(Int)`) — never through
    /// `BCryptoRestClient` — so this case does NOT cover a 402 on those two
    /// (confirmed by reading both files; out of scope for this fix, which
    /// only touches the shared client). Reachable today for KMS/PSK
    /// material, account, and entitlements requests, all of which DO go
    /// through this client.
    case paymentRequired
}

/// W-B10PAYREQ (2026-09-02) — a short, ready-to-show string for the ONE
/// case (`.paymentRequired`) this fix set out to give a dedicated message.
/// Deliberately narrow, not a general BCryptoError→String mapper: every
/// other case falls back to a generic line here, and `UpgradeSheet.swift`'s
/// own `UpgradeSheetContainer.redemptionErrorMessage(_:)` keeps owning the
/// full per-status routing for the redeem flow specifically (400/401/403/
/// 409/429/5xx) — that switch is NOT replaced or generalized by this one.
/// Any current or future call site that catches a `BCryptoError` from a
/// `feat.*`-gated request can show `error.userFacingMessage` (e.g. via
/// `QAudionSnackbar`, this app's one existing transient-message component —
/// see `QAudionSnackbar.swift`) instead of `error.localizedDescription`,
/// which for an untyped `httpError(402)` renders as an opaque NSError
/// string, not something a user can act on.
public extension BCryptoError {
    var userFacingMessage: String {
        switch self {
        case .paymentRequired:
            return "Questa funzione richiede un account Pro."
        default:
            return "Errore di rete — riprova."
        }
    }
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

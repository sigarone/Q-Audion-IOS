import Foundation

public final class BCryptoBackendProvider: BackendProvider {
    public let identifier = "bcrypto"
    public let displayName = "BCrypto"
    /// Current backend configuration. Read-only externally; mutated internally
    /// by `applyTokenPair` and `updateServerUrl`. External components (e.g.
    /// ServerSelector) read `config.serverUrl` and `config.accessToken` here.
    public private(set) var config: BackendConfig
    private let wsClient: BCryptoWebSocketClient
    private let restClient: BCryptoRestClient

    public lazy var callingApi: CallingApi = BCryptoCallingApiImpl(ws: wsClient, rest: restClient)
    public lazy var messageApi: MessageApi = BCryptoMessageApiImpl(ws: wsClient)
    public lazy var accountApi: AccountApi = BCryptoAccountApiImpl(rest: restClient)
    public lazy var contactsApi: ContactsApi = BCryptoContactsApiImpl(rest: restClient)
    public lazy var storageApi: StorageApi = BCryptoStorageApiImpl(rest: restClient)
    public lazy var securityApi: SecurityApi = BCryptoSecurityApiImpl(rest: restClient)
    /// 2026-05-06 — KMS HTTP client for the iOS pipeline
    /// (DeviceKeyManager + KmsPollerService consume this). Mirrors the
    /// `accountApi`/`contactsApi` pattern: lazy, lifetime-tied to the
    /// provider, lets AppState fetch via `provider.kmsClient` without
    /// instantiating its own RestClient.
    public lazy var kmsClient = BCryptoKmsClient(rest: restClient)
    /// W79 — voice-note recipient capability minter / redeemer.
    /// Used by the iOS-internal `qfile` v3 send pipeline so the recipient
    /// can `GET /api/v1/files/{id}` with the 3 download-token headers.
    public lazy var downloadTokenClient = BCryptoDownloadTokenClient(rest: restClient)
    public lazy var persistentConnection: PersistentConnection = BCryptoPersistentConnectionImpl(ws: wsClient)

    /// OIDC SSO client (lazy, only created if needed).
    public lazy var oidcClient = BCryptoOIDCClient(rest: restClient)

    /// Sovereign identity manager.
    public lazy var sovereignIdentity = SovereignIdentityManager()

    /// Online-status tracker for contacts. Subscribe via
    /// `presenceManager.subscribe(userIds:)` once the contacts view is shown.
    public lazy var presenceManager = BCryptoPresenceManager(ws: wsClient)

    public var isConnected: Bool { wsClient.state == .authenticated }

    public init(config: BackendConfig) {
        self.config = config
        self.wsClient = BCryptoWebSocketClient(config: config)
        self.restClient = BCryptoRestClient(config: config)

        // Wire the REST client so it can auto-refresh the JWT access token on
        // HTTP 401 and transparently retry the original request once. Any REST
        // or WebSocket component reading tokens from `self.config` will see the
        // new pair immediately because `updateConfig` is broadcast to both
        // clients here.
        self.restClient.setTokenRefresher { [weak self] in
            guard let self else { throw BCryptoError.unauthorized }
            guard let refresh = self.config.refreshToken else { throw BCryptoError.unauthorized }
            let pair = try await (self.accountApi as! BCryptoAccountApiImpl).refreshToken(refresh)
            self.applyTokenPair(access: pair.accessToken, refresh: pair.refreshToken)
            return (accessToken: pair.accessToken, refreshToken: pair.refreshToken)
        }

        // Always-reachable Phase 2 — bridge the WebSocket's `auth_failed`
        // handler to the SAME silent recovery cascade the REST 401 path uses
        // (refresh → Ed25519 device-renew). The cascade writes the fresh tokens
        // into the REST client's own config; we then broadcast them to EVERY
        // transport (including the WS client) via `applyTokenPair` so the WS's
        // next connect() authenticates with the new access token. Returns
        // `true` on success → WS resumes reconnect; `false` on genuine
        // revocation → WS parks its loop (never forces QR).
        self.wsClient.onAuthFailedRecover = { [weak self] in
            guard let self = self else { return false }
            let ok = await self.restClient.recoverAuth()
            guard ok, let fresh = self.restClient.accessToken else { return false }
            self.applyTokenPair(access: fresh, refresh: self.restClient.refreshToken)
            return true
        }
    }

    /// Propagate a refreshed (access, refresh) pair to the internal clients so
    /// subsequent requests and WebSocket reconnects authenticate with the new
    /// credentials. Called by the REST client's auto-refresh flow and by
    /// external code that performed a manual refresh (e.g. AuthService).
    public func applyTokenPair(access: String, refresh: String?) {
        config.accessToken = access
        if let r = refresh { config.refreshToken = r }
        wsClient.updateConfig(config)
        restClient.updateConfig(config)
    }

    /// Switch all transport components to a different server URL.
    /// Used by ServerSelector after probing finds a lower-latency node.
    /// The currently connected WebSocket is disconnected — it will
    /// reconnect automatically (with backoff) to the new URL.
    public func updateServerUrl(to newUrl: String) {
        config.serverUrl = newUrl
        wsClient.updateConfig(config)
        restClient.updateConfig(config)
    }

    public func initialize() async throws { wsClient.connect() }
    public func shutdown() { wsClient.disconnect() }
    public func getWebSocketClient() -> BCryptoWebSocketClient { wsClient }
    public func getRestClient() -> BCryptoRestClient { restClient }
}

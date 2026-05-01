import Foundation

public final class BCryptoBackendProvider: BackendProvider {
    public let identifier = "bcrypto"
    public let displayName = "BCrypto"
    private var config: BackendConfig
    private let wsClient: BCryptoWebSocketClient
    private let restClient: BCryptoRestClient

    public lazy var callingApi: CallingApi = BCryptoCallingApiImpl(ws: wsClient, rest: restClient)
    public lazy var messageApi: MessageApi = BCryptoMessageApiImpl(ws: wsClient)
    public lazy var accountApi: AccountApi = BCryptoAccountApiImpl(rest: restClient)
    public lazy var contactsApi: ContactsApi = BCryptoContactsApiImpl(rest: restClient)
    public lazy var storageApi: StorageApi = BCryptoStorageApiImpl(rest: restClient)
    public lazy var securityApi: SecurityApi = BCryptoSecurityApiImpl(rest: restClient)
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

    public func initialize() async throws { wsClient.connect() }
    public func shutdown() { wsClient.disconnect() }
    public func getWebSocketClient() -> BCryptoWebSocketClient { wsClient }
    public func getRestClient() -> BCryptoRestClient { restClient }
}

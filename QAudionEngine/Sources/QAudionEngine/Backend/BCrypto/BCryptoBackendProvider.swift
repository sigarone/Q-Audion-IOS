import Foundation

public final class BCryptoBackendProvider: BackendProvider {
    public let identifier = "bcrypto"
    public let displayName = "BCrypto"
    /// Current backend configuration. Read-only externally; mutated internally
    /// by `applyTokenPair` and `updateServerUrl`. External components (e.g.
    /// ServerSelector) read `config.serverUrl` and `config.accessToken` here.
    public private(set) var config: BackendConfig
    /// Lazily-created WebSocket client. A transient, REST-only provider — the
    /// ~20 per-use providers spun up for one-off account/contacts/storage/
    /// security calls — never touches a WS-backed API, so this stays nil and
    /// NO socket is ever opened. Only a provider that uses `callingApi` /
    /// `messageApi` / `presenceManager` / `persistentConnection`, or that
    /// calls `initialize()` (the single persistent `liveProvider`), brings a
    /// socket into being. This kills the "zombie WS + duplicate
    /// apns-voip-token" churn from transient providers each opening their own
    /// short-lived `/ws`. Built + wired on first access by the `wsClient`
    /// computed accessor below.
    private var _wsClient: BCryptoWebSocketClient?
    private let restClient: BCryptoRestClient

    /// On-demand accessor for the WebSocket client. The FIRST access builds
    /// it from the CURRENT `config` (so a socket created AFTER an
    /// `applyTokenPair` / `updateServerUrl` still authenticates with the
    /// latest token / URL) and wires the silent auth-recovery bridge — the
    /// same wiring that used to live in `init`, moved here so merely
    /// constructing a provider no longer forces a socket into existence.
    private var wsClient: BCryptoWebSocketClient {
        if let c = _wsClient { return c }
        let c = BCryptoWebSocketClient(config: config)
        // Always-reachable Phase 2 — bridge the WebSocket's `auth_failed`
        // handler to the SAME silent recovery cascade the REST 401 path uses
        // (refresh → Ed25519 device-renew). The cascade writes the fresh
        // tokens into the REST client's own config; we then broadcast them to
        // EVERY transport (including this WS) via `applyTokenPair` so the WS's
        // next connect() authenticates with the new access token. Returns
        // `true` on success → WS resumes reconnect; `false` on genuine
        // revocation → WS parks its loop (never forces QR).
        c.onAuthFailedRecover = { [weak self] in
            guard let self = self else { return false }
            let ok = await self.restClient.recoverAuth()
            guard ok, let fresh = self.restClient.accessToken else { return false }
            self.applyTokenPair(access: fresh, refresh: self.restClient.refreshToken)
            return true
        }
        _wsClient = c
        return c
    }

    public lazy var callingApi: CallingApi = {
        let impl = BCryptoCallingApiImpl(ws: wsClient, rest: restClient)
        // W-ACTIVECALLASSERT — hand the WS layer a live view of the bound
        // call id so every `authenticate` frame asserts it and the server's
        // mid-call blip recovery can cancel its pending disconnect-grace
        // teardown (or answer with the late definitive `call_hangup` for a
        // call that already ended). The impl's accessor is NSLock-guarded,
        // so the read is safe from the WS delegate thread. No call bound =
        // nil = the field is omitted — "I hold no call state" is exactly
        // what a fresh session should say.
        wsClient.activeCallIdProvider = { [weak impl] in impl?.getActiveCallId() }
        return impl
    }()
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

    /// True only once a socket exists AND is authenticated. A REST-only
    /// provider (no socket) is correctly `false` — reading this never forces a
    /// socket into existence.
    public var isConnected: Bool { _wsClient?.state == .authenticated }

    public init(config: BackendConfig) {
        self.config = config
        self.restClient = BCryptoRestClient(config: config)

        // Wire the REST client so it can auto-refresh the JWT access token on
        // HTTP 401 and transparently retry the original request once. Any REST
        // or WebSocket component reading tokens from `self.config` will see the
        // new pair immediately because `updateConfig` is broadcast to both
        // clients on `applyTokenPair`.
        self.restClient.setTokenRefresher { [weak self] in
            guard let self else { throw BCryptoError.unauthorized }
            guard let refresh = self.config.refreshToken else { throw BCryptoError.unauthorized }
            let pair = try await (self.accountApi as! BCryptoAccountApiImpl).refreshToken(refresh)
            self.applyTokenPair(access: pair.accessToken, refresh: pair.refreshToken)
            return (accessToken: pair.accessToken, refreshToken: pair.refreshToken)
        }

        // NOTE: the WebSocket client and its `onAuthFailedRecover` bridge are
        // created lazily on first use (see the `wsClient` accessor). A
        // REST-only provider never reaches that path, so it never opens a
        // socket nor registers anything WS-side.
    }

    /// Invoked every time `applyTokenPair` rotates the token pair — leg-1
    /// REST `/auth/refresh` (wired automatically by `init`'s default
    /// `tokenRefresher`), leg-2 Ed25519 device-renew, or an external manual
    /// call. Lets the app layer persist the rotated pair to the shared
    /// Keychain (`TokenVault`) for EVERY provider construction, not just the
    /// hand-wired main-session ones. Without this, a provider built with a
    /// stored refresh token (e.g. `AppState.makeUploadProvider()`'s ephemeral
    /// fallback when `liveProvider` is nil, or the cold-start `getProfile`
    /// provider) whose 401-triggered leg-1 refresh fires rotates the family
    /// on the SERVER but keeps the new pair ONLY in this instance's
    /// in-memory `config`, discarded when the provider is deallocated right
    /// after the call — leaving the Keychain holding an already-consumed
    /// refresh token. The NEXT unrelated refresh (main session, another
    /// one-off call, WS reconnect) then presents that dead token; the
    /// server's reuse detector treats it as theft outside its 15s
    /// benign-race grace window and invalidates the WHOLE refresh-token
    /// family, forcing a full logout + QR re-pair even though nothing was
    /// compromised. Confirmed via the prod audit log (`refresh_token_reuse`
    /// / "family invalidated") recurring for weeks on two real accounts.
    public var onTokenRotated: ((_ access: String, _ refresh: String?) -> Void)?

    /// Propagate a refreshed (access, refresh) pair to the internal clients so
    /// subsequent requests and WebSocket reconnects authenticate with the new
    /// credentials. Called by the REST client's auto-refresh flow and by
    /// external code that performed a manual refresh (e.g. AuthService).
    public func applyTokenPair(access: String, refresh: String?) {
        config.accessToken = access
        if let r = refresh { config.refreshToken = r }
        // `_wsClient?` — never force-create a socket just to push a token. A
        // socket built later reads the now-updated `config` at creation time.
        _wsClient?.updateConfig(config)
        restClient.updateConfig(config)
        onTokenRotated?(access, refresh)
    }

    /// Switch all transport components to a different server URL.
    /// Used by ServerSelector after probing finds a lower-latency node.
    /// The currently connected WebSocket is disconnected — it will
    /// reconnect automatically (with backoff) to the new URL.
    public func updateServerUrl(to newUrl: String, reconnectSocket: Bool = true) {
        // Nothing to do when the selector re-affirms the node we are already on,
        // which is most of what it does — the primary-snap check re-asserts the
        // pinned host on every monitor tick.
        guard config.serverUrl != newUrl else { return }

        config.serverUrl = newUrl
        // `_wsClient?` — a not-yet-created socket reads the new URL on first
        // connect; no need to force one into existence here.
        _wsClient?.updateConfig(config)
        restClient.updateConfig(config)

        // updateConfig only STORES the value: a socket that is already open
        // keeps talking to the node it dialled, indefinitely, while REST has
        // already moved. That left the two halves of this client disagreeing
        // about which node it was on for as long as the connection happened to
        // survive — hours, in practice.
        //
        // Reconnecting costs a few seconds of signaling, which this client is
        // built to absorb (it reconnects with backoff and surfaces a
        // reconnecting state); media rides WebRTC and is not on this socket at
        // all. An indefinite disagreement is the worse of the two.
        //
        // `reconnectSocket: false` exists for the caller that knows this is a
        // bad moment — mid call-setup, offer and answer in flight. Wiring that
        // signal in is the remaining refinement: the selector cannot see call
        // state today, so nothing passes false yet.
        if reconnectSocket, let ws = _wsClient {
            ws.disconnect()
            ws.connect()
        }
    }

    public func initialize() async throws { wsClient.connect() }
    public func shutdown() { _wsClient?.disconnect() }
    public func getWebSocketClient() -> BCryptoWebSocketClient { wsClient }
    public func getRestClient() -> BCryptoRestClient { restClient }
}

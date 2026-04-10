import Foundation

/// Backend provider that routes Q-Audion traffic through Signal's infrastructure.
///
/// Architecture: reuses `BCryptoRestClient` and `BCryptoWebSocketClient` as generic
/// HTTP/WS transport clients, pointed at Signal-compatible endpoints. Signal serves
/// purely as a transport layer -- all Q-Audion PQC encryption (ML-KEM + AES-256-GCM)
/// is handled upstream by `MessageCrypto` before payloads reach this provider.
///
/// - Q-Audion <-> Q-Audion calls: our PQC encryption, routed through Signal transport
/// - Q-Audion -> Signal user: opaque message falls through to Signal's standard protocol
/// - Signal -> Q-Audion: accepted and decrypted via Signal protocol at the engine layer
public final class UpstreamBackendProvider: BackendProvider {
    public let identifier = "upstream"
    public let displayName = "Signal"

    private let config: BackendConfig
    private let restClient: BCryptoRestClient
    private let wsClient: BCryptoWebSocketClient

    public lazy var callingApi: CallingApi = UpstreamCallingApiImpl(
        rest: restClient, ws: wsClient
    )
    public lazy var messageApi: MessageApi = UpstreamMessageApiImpl(
        rest: restClient
    )
    public lazy var accountApi: AccountApi = UpstreamAccountApiImpl(
        rest: restClient
    )
    public lazy var contactsApi: ContactsApi = UpstreamContactsApiImpl(
        rest: restClient
    )
    public lazy var storageApi: StorageApi = UpstreamStorageApiImpl(
        rest: restClient
    )
    public lazy var persistentConnection: PersistentConnection = UpstreamPersistentConnectionImpl(
        ws: wsClient
    )

    public var isConnected: Bool { wsClient.state == .authenticated }

    /// Initialize with a `BackendConfig`.
    ///
    /// The config's `serverUrl` should point to a Signal-compatible server
    /// (default: `https://chat.signal.org`). The same `BCryptoRestClient` and
    /// `BCryptoWebSocketClient` are reused -- they are generic HTTP/WS clients
    /// that work with any server URL.
    public init(config: BackendConfig) {
        self.config = config
        self.restClient = BCryptoRestClient(config: config)
        self.wsClient = BCryptoWebSocketClient(config: config)
    }

    /// Convenience initializer using Signal's default production server.
    public convenience init() {
        self.init(config: BackendConfig(serverUrl: "https://chat.signal.org"))
    }

    public func initialize() async throws {
        wsClient.connect()
    }

    public func shutdown() {
        wsClient.disconnect()
    }

    /// Expose the WebSocket client for components that need direct access
    /// (e.g., call signaling that requires low-latency opaque message delivery).
    public func getWebSocketClient() -> BCryptoWebSocketClient { wsClient }

    /// Expose the REST client for components that need direct HTTP access.
    public func getRestClient() -> BCryptoRestClient { restClient }
}

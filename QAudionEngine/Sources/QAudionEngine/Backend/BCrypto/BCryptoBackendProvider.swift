import Foundation

public final class BCryptoBackendProvider: BackendProvider {
    public let identifier = "bcrypto"
    public let displayName = "BCrypto"
    private let config: BackendConfig
    private let wsClient: BCryptoWebSocketClient
    private let restClient: BCryptoRestClient

    public lazy var callingApi: CallingApi = BCryptoCallingApiImpl(ws: wsClient)
    public lazy var messageApi: MessageApi = BCryptoMessageApiImpl(ws: wsClient)
    public lazy var accountApi: AccountApi = BCryptoAccountApiImpl(rest: restClient)
    public lazy var contactsApi: ContactsApi = BCryptoContactsApiImpl(rest: restClient)
    public lazy var storageApi: StorageApi = BCryptoStorageApiImpl(rest: restClient)
    public lazy var persistentConnection: PersistentConnection = BCryptoPersistentConnectionImpl(ws: wsClient)

    public var isConnected: Bool { wsClient.state == .authenticated }

    public init(config: BackendConfig) {
        self.config = config
        self.wsClient = BCryptoWebSocketClient(config: config)
        self.restClient = BCryptoRestClient(config: config)
    }

    public func initialize() async throws { wsClient.connect() }
    public func shutdown() { wsClient.disconnect() }
    public func getWebSocketClient() -> BCryptoWebSocketClient { wsClient }
}

import Foundation

public final class UpstreamBackendProvider: BackendProvider {
    public let identifier = "upstream"
    public let displayName = "Signal"
    public var isConnected: Bool = false

    public lazy var callingApi: CallingApi = UpstreamCallingApiImpl()
    public lazy var messageApi: MessageApi = UpstreamMessageApiImpl()
    public lazy var accountApi: AccountApi = UpstreamAccountApiImpl()
    public lazy var contactsApi: ContactsApi = UpstreamContactsApiImpl()
    public lazy var storageApi: StorageApi = UpstreamStorageApiImpl()
    public lazy var persistentConnection: PersistentConnection = UpstreamPersistentConnectionImpl()

    public init() {}
    public func initialize() async throws { isConnected = true }
    public func shutdown() { isConnected = false }
}

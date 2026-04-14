import Foundation

public protocol BackendProvider {
    var identifier: String { get }
    var displayName: String { get }
    var isConnected: Bool { get }
    func initialize() async throws
    func shutdown()
    var callingApi: CallingApi { get }
    var messageApi: MessageApi { get }
    var accountApi: AccountApi { get }
    var contactsApi: ContactsApi { get }
    var storageApi: StorageApi { get }
    var securityApi: SecurityApi { get }
    var persistentConnection: PersistentConnection { get }
}

import Foundation

public final class UpstreamContactsApiImpl: ContactsApi {
    public init() {}
    public func discoverContacts(phoneHashes: [String]) async throws -> [DiscoveredContact] { [] }
    public func addContact(userId: String) async throws {}
    public func removeContact(userId: String) async throws {}
    public func listContacts() async throws -> [DiscoveredContact] { [] }
}

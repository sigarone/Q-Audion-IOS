import Foundation

public protocol ContactsApi {
    func discoverContacts(phoneHashes: [String]) async throws -> [DiscoveredContact]
    func addContact(userId: String) async throws
    func removeContact(userId: String) async throws
    func listContacts() async throws -> [DiscoveredContact]
}

public struct DiscoveredContact: Codable {
    public var userId: String
    public var phoneHash: String
    public var displayName: String?
    public init(userId: String, phoneHash: String, displayName: String? = nil) {
        self.userId = userId; self.phoneHash = phoneHash; self.displayName = displayName
    }
}

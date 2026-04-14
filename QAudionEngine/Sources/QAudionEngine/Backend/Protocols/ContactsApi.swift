import Foundation

public protocol ContactsApi {
    func discoverContacts(phoneHashes: [String]) async throws -> [DiscoveredContact]
    func addContact(userId: String) async throws
    func removeContact(userId: String) async throws
    func listContacts() async throws -> [DiscoveredContact]
    /// Sync contacts with server (batch upload).
    func syncContacts(phoneHashes: [String]) async throws
    /// Block a contact.
    func blockContact(userId: String) async throws
    /// Unblock a contact.
    func unblockContact(userId: String) async throws
    /// Get blocked contacts list.
    func getBlockedContacts() async throws -> [DiscoveredContact]
}

public struct DiscoveredContact: Codable {
    public var userId: String
    public var phoneHash: String
    public var displayName: String?
    public var avatarUrl: String?
    public var statusMessage: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case phoneHash = "phone_hash"
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case statusMessage = "status_message"
    }

    public init(userId: String, phoneHash: String, displayName: String? = nil, avatarUrl: String? = nil, statusMessage: String? = nil) {
        self.userId = userId; self.phoneHash = phoneHash
        self.displayName = displayName; self.avatarUrl = avatarUrl
        self.statusMessage = statusMessage
    }
}

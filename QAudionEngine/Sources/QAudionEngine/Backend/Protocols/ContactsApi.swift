import Foundation

public protocol ContactsApi {
    func discoverContacts(phoneHashes: [String]) async throws -> [DiscoveredContact]
    func addContact(userId: String) async throws
    func removeContact(userId: String) async throws
    func listContacts() async throws -> [DiscoveredContact]
    /// Sync contacts with server (batch upload).
    ///
    /// Android `SyncContactsRequest` body shape:
    /// `{"contacts":[{"contact_user_id":"…","display_name":"…","local_alias":"…"}]}`.
    /// The per-entry fields other than `contact_user_id` are optional.
    func syncContacts(entries: [SyncContactEntry]) async throws
    /// Block a contact.
    func blockContact(userId: String) async throws
    /// Unblock a contact.
    func unblockContact(userId: String) async throws
    /// Get blocked contacts list. The server responds with
    /// `{"blocked":[{"user_id":"…","blocked_at":"…"}]}`.
    func getBlockedContacts() async throws -> [BlockedContact]
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

/// Per-entry payload for `POST /api/v1/contacts/sync`. Matches Android
/// `SyncContactEntry` (see `ContactsDto.kt`).
public struct SyncContactEntry: Codable, Hashable {
    public var contactUserId: String
    public var displayName: String?
    public var localAlias: String?

    enum CodingKeys: String, CodingKey {
        case contactUserId = "contact_user_id"
        case displayName = "display_name"
        case localAlias = "local_alias"
    }

    public init(contactUserId: String, displayName: String? = nil, localAlias: String? = nil) {
        self.contactUserId = contactUserId
        self.displayName = displayName
        self.localAlias = localAlias
    }
}

/// Entry in the `blocked` array returned by `GET /api/v1/contacts/blocked`.
/// Matches Android `BlockedEntryDto` (see `ContactsDto.kt`).
public struct BlockedContact: Codable, Hashable {
    public var userId: String
    public var blockedAt: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case blockedAt = "blocked_at"
    }

    public init(userId: String, blockedAt: String? = nil) {
        self.userId = userId
        self.blockedAt = blockedAt
    }
}

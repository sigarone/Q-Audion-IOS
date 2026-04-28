import Foundation

/// Local persistence for the contacts list (peppered hash → user metadata).
///
/// Stores the result of a discover-v2 fetch so subsequent app launches show
/// contacts immediately without re-fetching. Refresh re-runs the peppered
/// hash + discover-v2 flow.
public final class ContactsStore {

    public struct StoredContact: Codable, Equatable {
        public let userId: String
        public let displayName: String
        public let phoneHash: String  // peppered hash that resolved to userId
        public let avatarUrl: URL?
        public let lastSeen: Date?
        public let isVerified: Bool

        public init(userId: String, displayName: String, phoneHash: String,
                    avatarUrl: URL?, lastSeen: Date?, isVerified: Bool) {
            self.userId = userId
            self.displayName = displayName
            self.phoneHash = phoneHash
            self.avatarUrl = avatarUrl
            self.lastSeen = lastSeen
            self.isVerified = isVerified
        }
    }

    private let defaults: UserDefaults
    private let key = "qaudion.contacts.list"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [StoredContact] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([StoredContact].self, from: data)) ?? []
    }

    public func save(_ contacts: [StoredContact]) {
        guard let data = try? JSONEncoder().encode(contacts) else { return }
        defaults.set(data, forKey: key)
    }

    public func upsert(_ contact: StoredContact) {
        var current = load()
        if let idx = current.firstIndex(where: { $0.userId == contact.userId }) {
            current[idx] = contact
        } else {
            current.append(contact)
        }
        save(current)
    }

    public func remove(userId: String) {
        var current = load()
        current.removeAll { $0.userId == userId }
        save(current)
    }

    public func wipeAll() {
        defaults.removeObject(forKey: key)
    }
}

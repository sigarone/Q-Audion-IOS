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
        /// Long-term identity public key, when known. Populated by the QR-scan
        /// pairing flow (IdentityQrCode / DeviceLinkBinaryQR carry the pubkey
        /// alongside the userId) and by future discover-v2 results that
        /// include published pubkeys. nil for legacy rows persisted before
        /// this field was added — old JSON decodes with pubkey=nil because
        /// Optional fields are absent-tolerant in Codable synthesis.
        public let pubkey: Data?

        public init(userId: String, displayName: String, phoneHash: String,
                    avatarUrl: URL?, lastSeen: Date?, isVerified: Bool,
                    pubkey: Data? = nil) {
            self.userId = userId
            self.displayName = displayName
            self.phoneHash = phoneHash
            self.avatarUrl = avatarUrl
            self.lastSeen = lastSeen
            self.isVerified = isVerified
            self.pubkey = pubkey
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
        // Notify observers (e.g. AppState.cachedContacts) so they can
        // refresh without polling. All writes funnel through save(), so
        // a single post here covers upsert(), remove(), and bulk saves.
        NotificationCenter.default.post(name: .contactsDidChange, object: nil)
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

    /// Convenience: look up a stored contact's pubkey by userId. Returns nil
    /// if the contact is unknown or was persisted before pubkey was tracked.
    /// Used by the contact-detail surface to render the canonical fingerprint
    /// without requiring callers to walk the full contact list themselves.
    public func findPubkey(userId: String) -> Data? {
        load().first(where: { $0.userId == userId })?.pubkey
    }
}

// MARK: - Notification names

public extension Notification.Name {
    /// Posted by ContactsStore.save() (and transitively by upsert/remove)
    /// whenever the persisted contacts list changes. Observers can use this
    /// to refresh in-memory caches without polling.
    static let contactsDidChange = Notification.Name("qaudion.contactsDidChange")
}

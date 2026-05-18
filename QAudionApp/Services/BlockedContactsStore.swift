import Foundation

/// Lightweight UserDefaults-backed persistence for locally blocked contact IDs.
///
/// The server is the canonical source of truth (`ContactsApi.blockContact` /
/// `ContactsApi.unblockContact`), but the local set provides instant UI
/// feedback (blocked tab, row indicators) without a network round-trip.
///
/// Thread safety (NIM-MINOR-2): all read-modify-write sequences are
/// serialised on a private serial DispatchQueue. Without this, two
/// concurrent `add()` calls can both read the same base set, each insert a
/// different userId, and the second write overwrites the first entry.
struct BlockedContactsStore {

    private static let key = "qaudion.contacts.blocked"
    /// Serial queue that serialises every load-modify-persist cycle.
    private static let queue = DispatchQueue(label: "com.qaudion.blocked", attributes: [])

    // MARK: - Read

    static func loadBlockedIds() -> Set<String> {
        let array = UserDefaults.standard.stringArray(forKey: key) ?? []
        return Set(array)
    }

    static func isBlocked(_ userId: String) -> Bool {
        // SECURITY M-30: this is called from the WS call-signalling
        // path on a non-main thread concurrently with add()/remove()
        // (which mutate on `queue`). Reading UserDefaults outside the
        // serial queue races a concurrent persist() and can observe a
        // torn / stale set. Serialise the read on the same queue.
        return queue.sync { loadBlockedIds().contains(userId) }
    }

    // MARK: - Write

    static func add(_ userId: String) {
        queue.sync {
            var current = loadBlockedIds()
            current.insert(userId)
            persist(current)
        }
    }

    static func remove(_ userId: String) {
        queue.sync {
            var current = loadBlockedIds()
            current.remove(userId)
            persist(current)
        }
    }

    // MARK: - Private

    private static func persist(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids), forKey: key)
    }
}

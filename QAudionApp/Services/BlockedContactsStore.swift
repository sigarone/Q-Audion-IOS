import Foundation
import QAudionEngine

extension Notification.Name {
    /// Posted on the main queue whenever the local blocked list changes (a block, an unblock, a reload from the
    /// server, a sign-out). Screens that show the block state refresh from `BlockedContactsStore`.
    static let blockedContactsDidChange = Notification.Name("qaudion.blockedContactsDidChange")
}

/// Lightweight UserDefaults-backed persistence for locally blocked contact IDs.
///
/// The server is the canonical source of truth (`ContactsApi.blockContact` /
/// `ContactsApi.unblockContact`), but the local set lets the receive paths answer
/// "is this sender blocked" synchronously, without a network round-trip, and gives
/// instant UI feedback (blocked tab, row indicators).
///
/// Nobody writes here directly except `BlockedContactsStorage` (the adapter the
/// shared `ContactBlockCoordinator` uses): a screen that blocks or unblocks goes
/// through `ContactBlockService`, which asks the server first. The list is replaced
/// by the server's at sign-in and on every socket reconnect.
///
/// Identifiers compare trimmed and case-insensitively (`BlockPolicy`).
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

    /// The whole list. Read on the serial queue, like every other access (SECURITY M-30, see `isBlocked`).
    static func loadBlockedIds() -> Set<String> {
        return queue.sync { readIds() }
    }

    static func isBlocked(_ userId: String) -> Bool {
        // SECURITY M-30: this is called from the WS call-signalling
        // path on a non-main thread concurrently with add()/remove()
        // (which mutate on `queue`). Reading UserDefaults outside the
        // serial queue races a concurrent persist() and can observe a
        // torn / stale set. Serialise the read on the same queue.
        return queue.sync { BlockPolicy.isBlocked(userId, in: readIds()) }
    }

    // MARK: - Write

    static func add(_ userId: String) {
        let changed: Bool = queue.sync {
            let id = userId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return false }
            var current = readIds()
            if BlockPolicy.isBlocked(id, in: current) { return false }
            current.insert(id)
            persist(current)
            return true
        }
        if changed { notifyChanged() }
    }

    static func remove(_ userId: String) {
        let changed: Bool = queue.sync {
            let wanted = BlockPolicy.normalized(userId)
            let current = readIds()
            let kept = current.filter { BlockPolicy.normalized($0) != wanted }
            guard kept.count != current.count else { return false }
            persist(kept)
            return true
        }
        if changed { notifyChanged() }
    }

    /// Replace the whole list (the server's list at sign-in / reconnect).
    static func replaceAll(_ ids: Set<String>) {
        let changed: Bool = queue.sync {
            var cleaned = Set<String>()
            for id in ids {
                let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { cleaned.insert(trimmed) }
            }
            // Compared normalised: a list that differs only by case is the same list.
            let same = BlockPolicy.normalizedSet(cleaned) == BlockPolicy.normalizedSet(readIds())
            persist(cleaned)
            return !same
        }
        if changed { notifyChanged() }
    }

    /// Forget the list (sign-out, remote wipe, account deletion): it belongs to the account that left.
    static func clear() {
        replaceAll([])
    }

    // MARK: - Private

    /// Must run on `queue`.
    private static func readIds() -> Set<String> {
        let array = UserDefaults.standard.stringArray(forKey: key) ?? []
        return Set(array)
    }

    private static func persist(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids), forKey: key)
    }

    /// On the main queue: observers update SwiftUI state.
    private static func notifyChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .blockedContactsDidChange, object: nil)
        }
    }
}

/// `BlockedContactsStore` as the storage of the shared `ContactBlockCoordinator`.
struct BlockedContactsStorage: BlockedListStorage {
    func blockedIds() -> Set<String> { BlockedContactsStore.loadBlockedIds() }
    func insert(_ userId: String) { BlockedContactsStore.add(userId) }
    func remove(_ userId: String) { BlockedContactsStore.remove(userId) }
    func replaceAll(_ ids: Set<String>) { BlockedContactsStore.replaceAll(ids) }
}

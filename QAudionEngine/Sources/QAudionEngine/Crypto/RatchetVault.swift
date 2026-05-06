import Foundation

/// Persistence contract for the symmetric-ratchet engine (`MessageRatchet`).
///
/// **Threading**: implementations MUST be thread-safe. Concurrent calls
/// are expected from send and receive paths.
///
/// **Synchrony**: `save` MUST flush durably before returning. The
/// encrypt path persists `CK_{n+1}` BEFORE the network `send()` and
/// depends on this contract — an asynchronous flush would re-introduce
/// the catastrophic nonce-reuse hazard (spec §6).
///
/// **Trust boundary**: the snapshot contains live chain keys. Production
/// implementations MUST encrypt at rest (Keychain-wrapped AES key, the
/// equivalent of Android's `EncryptedSharedPreferences`).
public protocol RatchetVault: AnyObject {
    /// Load a previously persisted snapshot, or `nil` if none exists.
    func load(epochId: String, peerId: String) -> RatchetSnapshot?

    /// Persist a snapshot — synchronous flush required.
    func save(epochId: String, peerId: String, snapshot: RatchetSnapshot)

    /// Delete the snapshot for `(epochId, peerId)`. No-op if missing.
    func delete(epochId: String, peerId: String)
}

/// In-memory ratchet vault — useful for tests and the initial rollover
/// before the Keychain-backed production vault lands. NOT suitable for
/// production: snapshots are lost on process death, breaking decryption
/// of in-flight skipped messages.
public final class InMemoryRatchetVault: RatchetVault, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: RatchetSnapshot] = [:]

    public init() {}

    public func load(epochId: String, peerId: String) -> RatchetSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return store[Self.key(epochId, peerId)]
    }

    public func save(epochId: String, peerId: String, snapshot: RatchetSnapshot) {
        lock.lock()
        store[Self.key(epochId, peerId)] = snapshot
        lock.unlock()
    }

    public func delete(epochId: String, peerId: String) {
        lock.lock()
        store.removeValue(forKey: Self.key(epochId, peerId))
        lock.unlock()
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return store.count
    }

    private static func key(_ epoch: String, _ peer: String) -> String {
        return "\(epoch)|\(peer)"
    }
}

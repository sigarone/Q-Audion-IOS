import Foundation
#if canImport(Security)
import Security
#endif

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

    /// Persist a snapshot — synchronous durable flush required.
    ///
    /// SECURITY C-7: this MUST throw on persistence failure. The encrypt
    /// path depends on a durable `CK_{n+1}` write BEFORE returning the
    /// wire blob; a silently-dropped write re-introduces the catastrophic
    /// nonce-reuse hazard (spec §6). Callers MUST treat a throw as fatal
    /// and NOT transmit the ciphertext.
    func save(epochId: String, peerId: String, snapshot: RatchetSnapshot) throws

    /// Delete the snapshot for `(epochId, peerId)`. No-op if missing.
    func delete(epochId: String, peerId: String)
}

/// SECURITY C-7: persistence failures the ratchet vault may surface.
public enum VaultError: Error, Equatable {
    /// Keychain `SecItemAdd`/`SecItemUpdate` returned a non-success status.
    case persistFailed(OSStatus)
}

/// In-memory ratchet vault — useful for tests and the initial rollover
/// before the Keychain-backed production vault lands. NOT suitable for
/// production: snapshots are lost on process death, breaking decryption
/// of in-flight skipped messages.
@available(*, deprecated, renamed: "KeychainRatchetVault", message: "InMemoryRatchetVault loses state on process death — nonce reuse risk")
public final class InMemoryRatchetVault: RatchetVault, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: RatchetSnapshot] = [:]

    public init() {}

    public func load(epochId: String, peerId: String) -> RatchetSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return store[Self.key(epochId, peerId)]
    }

    // SECURITY C-7: signature is `throws` to conform to the hardened
    // protocol. In-memory storage cannot fail, so this never throws.
    public func save(epochId: String, peerId: String, snapshot: RatchetSnapshot) throws {
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

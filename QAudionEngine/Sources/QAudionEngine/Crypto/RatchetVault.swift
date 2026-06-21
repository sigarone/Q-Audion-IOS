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

    // ── v4 PQ-ratchet session blob (WIRE-FORMAT §4) ──────────────────────────
    //
    // The v4 native session (``MessageRatchet/serializeV4Session(_:)``) is an
    // OPAQUE byte blob owned end-to-end by the Rust core — NOT a
    // ``RatchetSnapshot``. It is stored under a SEPARATE keyspace so it never
    // collides with the v3.1 snapshot for the same `(epochId, peerId)`. Default
    // no-op / nil bodies (see the protocol extension below) so test doubles and
    // non-v4 implementations need not override them; only the production vault
    // provides durable v4 storage. Same write-ahead + encrypt-at-rest contract
    // as the v3.1 methods. Mirrors Android `RatchetVault.loadV4/saveV4/deleteV4`.

    /// Load a persisted v4 session blob (opaque ``MessageRatchet/serializeV4Session(_:)``
    /// output) for `(epochId, peerId)`, or `nil` if none exists. Default returns
    /// `nil` so a non-v4 vault transparently forces a re-bootstrap.
    func loadV4(epochId: String, peerId: String) -> Data?

    /// Persist a v4 session blob. MUST flush synchronously before returning
    /// (same write-ahead contract as ``save(epochId:peerId:snapshot:)``).
    ///
    /// SECURITY: `throws` so a persistence failure is fatal on the encrypt path
    /// — ``MessageRatchet/encryptV4Routed(peerId:plaintext:)`` write-ahead-saves
    /// the advanced send chain BEFORE returning the frame; a silently-dropped
    /// write would re-introduce a nonce-reuse window on crash. Default no-op.
    func saveV4(epochId: String, peerId: String, blob: Data) throws

    /// Delete the v4 session blob for `(epochId, peerId)`. Default no-op.
    func deleteV4(epochId: String, peerId: String)
}

// SECURITY / back-compat: default v4 bodies so existing vaults (and test
// doubles) that only implement the v3.1 surface keep compiling and transparently
// force a v4 re-bootstrap (loadV4 → nil). Production vaults (``KeychainRatchetVault``)
// and the in-memory test vault override these with durable storage. Mirrors
// Android's `interface RatchetVault { fun loadV4(...) = null; ... }` defaults.
public extension RatchetVault {
    func loadV4(epochId: String, peerId: String) -> Data? { nil }
    func saveV4(epochId: String, peerId: String, blob: Data) throws {}
    func deleteV4(epochId: String, peerId: String) {}
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
    // v4 opaque-blob keyspace — SEPARATE map so a v4 session never collides with
    // a v3.1 snapshot for the same (epochId, peerId). Mirrors the production
    // vault's separate Keychain service.
    private var storeV4: [String: Data] = [:]

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

    // ── v4 opaque-blob storage (in-memory; for tests / pre-Keychain rollover) ──

    public func loadV4(epochId: String, peerId: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return storeV4[Self.key(epochId, peerId)]
    }

    // In-memory storage cannot fail, so this never throws.
    public func saveV4(epochId: String, peerId: String, blob: Data) throws {
        lock.lock()
        storeV4[Self.key(epochId, peerId)] = blob
        lock.unlock()
    }

    public func deleteV4(epochId: String, peerId: String) {
        lock.lock()
        storeV4.removeValue(forKey: Self.key(epochId, peerId))
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

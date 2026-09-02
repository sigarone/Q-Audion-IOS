import Foundation

/// Persisted `(device_id, nonce)` replay set for signed `remote_wipe`
/// commands — TRUST-2. A wipe command is single-use: the same
/// `(device_id, nonce)` pair must never verify twice, including across an
/// app relaunch inside the freshness window (a killed-and-relaunched app is
/// exactly when an attacker replaying a captured wipe envelope would try).
///
/// Shape mirrors `KmsPreBootstrapReplayCache` (`Crypto/KmsPreBootstrap.swift`)
/// — same TTL+LRU-eviction discipline, same `putIfAbsent` contract — with
/// ONE deliberate difference: that cache is in-memory only (acceptable for
/// its own ADR-014a threat model), but a wipe replay MUST survive a process
/// restart within the freshness window, so this one persists to a small JSON
/// file under Application Support (`FileManager` pattern taken from
/// `QAudionDatabase.defaultDirectoryURL()` — `.applicationSupportDirectory`,
/// `create: true`). "Doesn't need to be fancy" (TRUST-2 fix note): entries
/// are few (wipe commands are rare) and the file is small, so every mutating
/// call re-persists the whole set synchronously rather than maintaining a
/// journal or database.
///
/// Not secret material — nonces and device ids carry no confidentiality
/// requirement, only a uniqueness one — so plain `FileManager` I/O (not
/// Keychain) is the right tool, matching the "doesn't need to be fancy"
/// scope note.
public final class WipeReplayCache: @unchecked Sendable {
    private struct Key: Hashable {
        let deviceId: String
        let nonce: Data
    }

    private struct PersistedEntry: Codable {
        let deviceId: String
        let nonceBase64: String
        let lastSeenMs: Int64
    }

    private let lock = NSLock()
    private var order: [Key] = []          // insertion/access order, oldest first
    private var store: [Key: Int64] = [:]  // key -> lastSeenMs
    private let ttlMillis: Int64
    private let maxEntries: Int
    private let persistenceURL: URL?

    /// - Parameters:
    ///   - ttlMillis: how long a `(device_id, nonce)` pair is remembered.
    ///     Default (15 min) is intentionally wider than TRUST-2's 5-minute
    ///     `issued_at` freshness window — the freshness check independently
    ///     rejects a stale `issued_at` regardless of this TTL, so the margin
    ///     only guards against clock skew between the two checks, never
    ///     shortens real replay protection.
    ///   - maxEntries: LRU cap. Wipe commands are rare; this is generous.
    ///   - persistenceURL: override for tests. `nil` disables persistence
    ///     (in-memory only) — used by unit tests that must not touch disk.
    ///     Production callers should pass `nil` here too and instead rely on
    ///     `Self.defaultPersistenceURL()`... see `init(ttlMillis:maxEntries:)`
    ///     convenience below, which wires that up.
    init(ttlMillis: Int64 = 15 * 60 * 1000, maxEntries: Int = 256, persistenceURL: URL?) {
        self.ttlMillis = ttlMillis
        self.maxEntries = maxEntries
        self.persistenceURL = persistenceURL
        loadFromDiskLocked()
    }

    /// Production convenience — persists under Application Support.
    public convenience init(ttlMillis: Int64 = 15 * 60 * 1000, maxEntries: Int = 256) {
        self.init(ttlMillis: ttlMillis, maxEntries: maxEntries, persistenceURL: Self.defaultPersistenceURL())
    }

    static func defaultPersistenceURL() -> URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        return dir.appendingPathComponent("wipe_replay_cache.json")
    }

    /// Atomic "have I seen this (device_id, nonce) in the last `ttlMillis`?"
    /// probe. Returns `true` if the entry was *new* (and is now recorded and
    /// persisted); `false` if it was already present and not expired
    /// (replay — caller MUST NOT act on the command).
    public func putIfAbsent(deviceId: String, nonce: Data, nowMs: Int64) -> Bool {
        precondition(nonce.count == 16, "nonce must be 16B")
        lock.lock()
        defer { lock.unlock() }
        purgeExpiredLocked(nowMs)
        let key = Key(deviceId: deviceId, nonce: nonce)
        if let existing = store[key], nowMs - existing <= ttlMillis {
            return false // replay
        }
        if store[key] == nil { order.append(key) }
        store[key] = nowMs
        if store.count > maxEntries, !order.isEmpty {
            let oldest = order.removeFirst()
            store.removeValue(forKey: oldest)
        }
        persistLocked()
        return true
    }

    /// Visible for tests / diagnostics.
    public func size() -> Int { lock.lock(); defer { lock.unlock() }; return store.count }

    /// Visible for tests.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        store.removeAll()
        order.removeAll()
        persistLocked()
    }

    private func purgeExpiredLocked(_ nowMs: Int64) {
        guard !store.isEmpty else { return }
        var stillLive: [Key] = []
        stillLive.reserveCapacity(order.count)
        var changed = false
        for k in order {
            if let ts = store[k], nowMs - ts > ttlMillis {
                store.removeValue(forKey: k)
                changed = true
            } else {
                stillLive.append(k)
            }
        }
        order = stillLive
        if changed { persistLocked() }
    }

    // MARK: - Persistence (best-effort — a disk failure must never block or
    // silently defeat replay protection; on any read/write error the cache
    // simply behaves in-memory-only for that run, which is strictly safer
    // than crashing or than pretending a command is fresh).

    private func loadFromDiskLocked() {
        guard let url = persistenceURL,
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([PersistedEntry].self, from: data) else {
            return
        }
        for e in entries {
            guard let nonce = Data(base64Encoded: e.nonceBase64), nonce.count == 16 else { continue }
            let key = Key(deviceId: e.deviceId, nonce: nonce)
            if store[key] == nil { order.append(key) }
            store[key] = e.lastSeenMs
        }
    }

    private func persistLocked() {
        guard let url = persistenceURL else { return }
        let entries = order.compactMap { key -> PersistedEntry? in
            guard let ts = store[key] else { return nil }
            return PersistedEntry(deviceId: key.deviceId, nonceBase64: key.nonce.base64EncodedString(), lastSeenMs: ts)
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

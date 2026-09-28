import Foundation

/// W-MEDIAATACCEPT (option b) — §6: a per-`callId` PQC session-key store,
/// replacing the single global `AppState.callPqcSessionKey` SLOT as the
/// durable write target. `AppState.callPqcSessionKey` itself stays a
/// `@Published` projection of `get(canonicalActiveCallId())`, recomputed
/// whenever the active call id changes or this store is written/wiped for
/// that id — see that property's doc.
///
/// **Why this exists:** the responder PQC integration instance is shared
/// and reused across calls (`ensureResponderIntegration`, see its doc). With
/// option (b) trattenendo the media plane (and therefore the PC/cryptor
/// seed) until accept, the window between "a handshake for call B
/// completes" and "call A's media plane reads the active key" grows —
/// without per-call isolation, call B's key could land in the projection
/// while call A is still active. Keying by `callId` here removes that
/// class of cross-call contamination regardless of timing.
///
/// **Thread-safety:** one `NSLock`, coarse-grained — a handful of writes
/// per call, never a hot per-frame path.
public final class CallKeyStore: @unchecked Sendable {

    public static let shared = CallKeyStore()

    public enum Origin: Equatable {
        case pqc
        case transitional
    }

    public struct Entry {
        /// Always a defensive copy (`put` wraps the caller's bytes in a
        /// fresh `Data(key)`), and `var` on purpose: `wipe` scrubs this
        /// field IN PLACE via `CryptoConstants.zeroize(&entries[id]!.key)`
        /// before removing the dictionary entry, so it forces copy-on-write
        /// uniqueness against the store's OWN backing buffer rather than a
        /// throwaway local copy — see that function's doc.
        public var key: Data
        public let epoch: Int32
        public let origin: Origin
        public let createdAtMs: Int64
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public static let maxEntries = 4
    /// TTL for a call that was never marked active in this store — mirrors
    /// `RingSignalingRegistry.ttlMs`'s "never accepted" cleanup, but this
    /// store has no accept/wipe coupling of its own beyond `sweep`, so it
    /// uses a slightly longer window (spec §6: 120s) as its own safety net
    /// independent of the ring-time cleanup chain.
    public static let ttlMs: Int64 = 120_000

    private init() {}

    private static func normalize(_ callId: String) -> String {
        callId.lowercased()
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// Store (or replace) the key for `callId`. A `.pqc` write always wins
    /// over — and may replace — a `.transitional` (W369) seed for the same
    /// call; the reverse (a transitional write arriving after a real PQC
    /// key is already in place) is accepted too since callers only ever
    /// seed transitionally BEFORE the handshake completes in practice, and
    /// this store does not itself enforce call ordering beyond "last write
    /// wins" — same simple semantics as the slot it replaces.
    public func put(callId: String, key: Data, epoch: Int32 = 0, origin: Origin = .pqc) {
        guard !callId.isEmpty else { return }
        let id = Self.normalize(callId)
        lock.lock()
        defer { lock.unlock() }
        if entries[id] == nil, entries.count >= Self.maxEntries {
            if let oldestKey = entries.min(by: { $0.value.createdAtMs < $1.value.createdAtMs })?.key {
                entries.removeValue(forKey: oldestKey)
            }
        }
        entries[id] = Entry(key: Data(key), epoch: epoch, origin: origin, createdAtMs: Self.nowMs())
    }

    public func get(_ callId: String?) -> Data? {
        guard let callId = callId, !callId.isEmpty else { return nil }
        let id = Self.normalize(callId)
        lock.lock(); defer { lock.unlock() }
        return entries[id]?.key
    }

    public func entry(_ callId: String?) -> Entry? {
        guard let callId = callId, !callId.isEmpty else { return nil }
        let id = Self.normalize(callId)
        lock.lock(); defer { lock.unlock() }
        return entries[id]
    }

    /// Read-and-remove, used as the incoming media-plane builder's key
    /// seed (§4.4 `callKeyStore.take(callId)`): once the PC is seeded, the
    /// per-call copy has done its job and staying around only widens the
    /// window in which a later bug could read a stale key for an ended
    /// call. Per spec §6 this does NOT remove the entry — "take" here
    /// means "read for the controller seed", not "consume once"; the
    /// active-call projection (`AppState.callPqcSessionKey`) still needs
    /// `get` to keep resolving after this call. Kept as a distinct method
    /// (rather than reusing `get`) so the two call sites read differently
    /// at a glance and either can change independently later.
    public func take(_ callId: String?) -> Data? {
        get(callId)
    }

    /// Zeroes and removes the entry for `callId`. `why` is caller-logged
    /// (T3), not stored.
    public func wipe(_ callId: String, why: Int) {
        let id = Self.normalize(callId)
        lock.lock()
        defer { lock.unlock() }
        if entries[id] != nil {
            CryptoConstants.zeroize(&entries[id]!.key)
        }
        entries.removeValue(forKey: id)
    }

    public func wipeAll(why: Int) {
        lock.lock()
        for id in entries.keys {
            CryptoConstants.zeroize(&entries[id]!.key)
        }
        entries.removeAll()
        lock.unlock()
    }

    /// TTL sweep — spec §6, 120s. Cheap no-op on the common near-empty table.
    public func sweep(nowMs: Int64? = nil) {
        let now = nowMs ?? Self.nowMs()
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { (now - $0.value.createdAtMs) < Self.ttlMs }
    }

    /// Test-only full reset.
    func resetForTesting() {
        lock.lock(); entries.removeAll(); lock.unlock()
    }
}

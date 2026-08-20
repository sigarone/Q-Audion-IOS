import Foundation

/// W-VNACK (2026-08-16) — sender-side cache of recently-sent, already-
/// SEALED video-relay fragments, so a peer's VNACK retransmission
/// request can be served immediately with the byte-identical wire bytes
/// (no re-fragmentation, no re-sealing).
///
/// Direct port of Android's `BcryptoWsVideoRelayTransport.sentFragmentCache`
/// (W-VNACK-2): time-based retention, not count-based. A NACK round trip
/// (150ms stall-detect + two WS relay hops) routinely exceeds what a small
/// fixed-count cache holds at real fragment rates — Android's own live data
/// showed a count-capped cache produced a 100% miss rate under exactly the
/// degraded-network conditions NACK exists for. `maxAgeMs` bounds by wall-
/// clock instead; `maxEntries` is a hard safety net against a pathological
/// insert-rate spike, sized well above any realistic fragment burst.
final class VideoNackFragmentCache: @unchecked Sendable {

    struct Entry {
        let wire: Data
        /// Original total-fragment-count / keyframe flag for this fragment's
        /// frame — carried along purely for WS-envelope/logging parity with
        /// the original send (mirrors Android's `CachedFragment`); the
        /// receiver's actual reassembly reads these from the INNER
        /// sub-header inside `wire`, not from these top-level values.
        let totalFrags: Int
        let isKeyFrame: Bool
        let sentAtMs: Int64
    }

    private let lock = NSLock()
    /// Insertion-ordered (Swift dictionaries don't preserve insertion
    /// order across mutation the way Kotlin's LinkedHashMap does), so a
    /// parallel FIFO of keys tracks eviction order explicitly. Advancing
    /// `firstLiveIndex` is O(1); periodically compacting amortizes the copy
    /// instead of shifting the whole queue for every eviction.
    private var entries: [Int64: Entry] = [:]
    private var insertionOrder: [Int64] = []
    private var firstLiveIndex = 0

    private let maxAgeMs: Int64
    private let maxEntries: Int

    init(maxAgeMs: Int64 = 3000, maxEntries: Int = 4096) {
        self.maxAgeMs = maxAgeMs
        self.maxEntries = maxEntries
    }

    private static func key(frameId: Int, fragIdx: Int) -> Int64 {
        (Int64(frameId) << 8) | Int64(fragIdx & 0xFF)
    }

    /// Cache one sealed fragment's wire bytes. Call BEFORE sending, same
    /// as Android, so a NACK that races in immediately after always finds it.
    func store(frameId: Int, fragIdx: Int, wire: Data, totalFrags: Int, isKeyFrame: Bool, nowMs: Int64) {
        lock.lock()
        defer { lock.unlock() }
        let k = Self.key(frameId: frameId, fragIdx: fragIdx)
        if entries[k] == nil {
            insertionOrder.append(k)
        }
        entries[k] = Entry(wire: wire, totalFrags: totalFrags, isKeyFrame: isKeyFrame, sentAtMs: nowMs)
        evictStaleLocked(nowMs: nowMs)
    }

    /// Look up a cached fragment for a (frameId, fragIdx) the peer says it
    /// is missing. `nil` on a miss (aged out, or never sent by this
    /// instance — e.g. a stale/duplicate NACK) — same best-effort, no-
    /// error-path contract Android's `handleIncomingNack` has.
    func lookup(frameId: Int, fragIdx: Int) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[Self.key(frameId: frameId, fragIdx: fragIdx)]
    }

    /// Must be called with `lock` held. Advances past stale entries from the
    /// front (oldest first) — insertionOrder IS chronological order since
    /// each (frameId, fragIdx) key is unique and never re-inserted.
    private func evictStaleLocked(nowMs: Int64) {
        let cutoff = nowMs - maxAgeMs
        while firstLiveIndex < insertionOrder.count {
            let k = insertionOrder[firstLiveIndex]
            guard let entry = entries[k] else {
                firstLiveIndex += 1
                continue
            }
            if entry.sentAtMs >= cutoff {
                break
            }
            entries.removeValue(forKey: k)
            firstLiveIndex += 1
        }
        // Hard safety net, independent of the age-based sweep above.
        while entries.count > maxEntries, firstLiveIndex < insertionOrder.count {
            let oldest = insertionOrder[firstLiveIndex]
            entries.removeValue(forKey: oldest)
            firstLiveIndex += 1
        }
        // Avoid retaining an ever-growing prefix while only copying the
        // bounded live window once enough consumed keys have accumulated.
        if firstLiveIndex >= maxEntries {
            insertionOrder.removeFirst(firstLiveIndex)
            firstLiveIndex = 0
        }
    }

    func reset() {
        lock.lock()
        entries.removeAll()
        insertionOrder.removeAll()
        firstLiveIndex = 0
        lock.unlock()
    }
}

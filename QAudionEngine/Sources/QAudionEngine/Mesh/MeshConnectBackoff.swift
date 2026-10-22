import Foundation

/// Retry backoff for outgoing mesh connections (docs/mesh/MESH_LINK_SPEC.md section 3.5).
///
/// After an outgoing attempt to an advertiser fails (the connect timed out, discovery or the subscription timed
/// out, or the link dropped before the first ANNOUNCE was received on it) the same advertiser is not tried again
/// before its backoff expires:
///
/// - the first failure sets 15 s, every further consecutive failure doubles it, up to 300 s;
/// - each value is randomised by plus or minus 20 %;
/// - a link on which an ANNOUNCE is received clears the entry of its identifier (``clear(_:)``);
/// - at most 64 identifiers are remembered, the oldest entry is dropped first;
/// - the table lives in memory only and the owner empties it when the antenna is turned off (``removeAll()``).
///
/// The key is whatever the platform calls an advertiser (on iOS the peripheral identifier). A different key is a
/// different advertiser. Time is passed in as plain milliseconds from any monotonic clock, so the table is testable
/// without a radio; the randomisation is injectable for the same reason.
public struct MeshConnectBackoff {

    /// Backoff after the first failure.
    public static let firstMs: Int64 = 15_000
    /// Backoff after the sixth and every later consecutive failure (before the randomisation).
    public static let maxMs: Int64 = 300_000
    /// The randomisation range in permille: a value is scaled by `1 + n / 1000` with `n` in `-200...200`.
    public static let jitterRangePermille = 200
    /// Identifiers remembered at most.
    public static let capacity = 64

    /// What one recorded failure set.
    public struct Failure: Equatable {
        /// Consecutive failures of this identifier, this one included.
        public let failures: Int
        /// The backoff that now applies, in milliseconds, randomisation included.
        public let waitMs: Int64
    }

    private struct Entry {
        var failures: Int
        var untilMs: Int64
        /// Recency: larger is newer. The entry with the smallest stamp is the oldest.
        var stamp: UInt64
    }

    private var entries: [String: Entry] = [:]
    private var nextStamp: UInt64 = 0
    private let jitterPermille: () -> Int

    /// - Parameter jitter: the randomisation in permille, drawn once per recorded failure. Values outside
    ///   `-200...200` are clamped into it.
    public init(jitter: @escaping () -> Int = {
        Int.random(in: -MeshConnectBackoff.jitterRangePermille...MeshConnectBackoff.jitterRangePermille)
    }) {
        self.jitterPermille = jitter
    }

    /// Identifiers currently remembered.
    public var count: Int { entries.count }

    /// Consecutive failures recorded for `key` since its last clear, 0 if none.
    public func failures(_ key: String) -> Int {
        entries[key]?.failures ?? 0
    }

    /// Milliseconds until `key` may be tried again; 0 when it has no entry or the backoff has expired.
    public func remainingMs(_ key: String, nowMs: Int64) -> Int64 {
        guard let entry = entries[key] else { return 0 }
        return max(0, entry.untilMs - nowMs)
    }

    /// True while a new attempt to `key` is not allowed.
    public func isBackedOff(_ key: String, nowMs: Int64) -> Bool {
        remainingMs(key, nowMs: nowMs) > 0
    }

    /// Records one failed attempt and returns the backoff it sets. The entry stays after the backoff expired, so the
    /// next failure of the same identifier doubles the value (consecutive failures), until ``clear(_:)`` is called.
    @discardableResult
    public mutating func recordFailure(_ key: String, nowMs: Int64) -> Failure {
        let failures = (entries[key]?.failures ?? 0) + 1
        let jitter = min(max(jitterPermille(), -Self.jitterRangePermille), Self.jitterRangePermille)
        let base = Self.baseMs(afterFailures: failures)
        let wait = base + base * Int64(jitter) / 1000
        if entries[key] == nil, entries.count >= Self.capacity {
            dropOldest()
        }
        nextStamp += 1
        entries[key] = Entry(failures: failures, untilMs: nowMs + wait, stamp: nextStamp)
        return Failure(failures: failures, waitMs: wait)
    }

    /// An ANNOUNCE was received on a link to `key`: the advertiser answered, so its history is forgotten.
    public mutating func clear(_ key: String) {
        entries.removeValue(forKey: key)
    }

    /// The antenna was turned off: the whole table is forgotten.
    public mutating func removeAll() {
        entries.removeAll()
        nextStamp = 0
    }

    /// The `link.down` reasons that count as a failed attempt: the connect, discovery or subscribe timed out
    /// (`timeout`), or the other side or the platform dropped the link (`remote`).
    public static let failureReasons: Set<String> = ["timeout", "remote"]

    /// Whether a link that just went down was a failed outgoing attempt (section 3.5): a link we opened that never
    /// received an ANNOUNCE and ended in one of the ``failureReasons`` (a positive list: a reason added later does not
    /// count until it is listed). Never a failure of the advertiser: a link closed on purpose (`stop`: the antenna
    /// stopped or a pause gave up the attempt; `blocked`: the malformed-input block), an eviction, or one the peer
    /// opened to us.
    public static func isFailedAttempt(outgoing: Bool, announceReceived: Bool, reason: String) -> Bool {
        outgoing && !announceReceived && failureReasons.contains(reason)
    }

    /// The backoff after `failures` consecutive failures, before the randomisation: 15 s, 30 s, 60 s, 120 s, 240 s,
    /// then 300 s.
    public static func baseMs(afterFailures failures: Int) -> Int64 {
        var base = firstMs
        var step = 1
        while step < failures, base < maxMs {
            base *= 2
            step += 1
        }
        return min(base, maxMs)
    }

    private mutating func dropOldest() {
        guard let oldest = entries.min(by: { $0.value.stamp < $1.value.stamp })?.key else { return }
        entries.removeValue(forKey: oldest)
    }
}

import Foundation

/// Safety valve for a locally persisted value that cannot be read back.
///
/// Why this exists: a store that treats "the stored bytes cannot be opened or
/// decoded" as a FAILED read (not as "empty") never overwrites those bytes with
/// a list built from nothing, which is the right call while the cause may be
/// transient (a key that is briefly unavailable). The price is a value that is
/// unreadable for good: the store stays blocked forever and every new write is
/// dropped. This file decides when "unreadable for now" has lasted long enough
/// to be treated as "unreadable for good", and moves the bytes aside instead
/// of deleting them.
///
/// The rule, in words: the first time a read fails, remember the instant. Every
/// later failed read compares the clock with that instant; while the value has
/// been unreadable for no longer than `maxAgeMs` nothing is touched. Past that
/// the raw value is copied under a companion quarantine key (only the latest
/// quarantined value is kept), the original key and the marker are cleared and
/// the store starts empty. ANY successful read clears the marker, so a value
/// that comes back, even once, restarts the window.
///
/// `maxAgeMs` is meant to be the useful lifetime of what the value holds. The
/// bytes cannot change while they are unreadable (mutators leave them alone),
/// so by the time the window has run out every item they hold is already older
/// than that lifetime: quarantining a value that only LOOKED permanently
/// unreadable loses nothing that would still have been delivered.
///
/// `UnreadableStoredValuePolicy` is the pure decision (no I/O, no clock, same
/// discipline as `OutboxRetryPolicy`); `UnreadableStoredValueValve` applies it
/// to a `UserDefaults` domain so the marker / quarantine bookkeeping is pinned
/// by tests too.
public enum UnreadableStoredValuePolicy {

    /// What to do about a value that has just been observed unreadable.
    public enum Verdict: Equatable {
        /// No usable marker (first failure, or the stored one is nonsense or
        /// lies in the future because the clock moved back): record `now` as
        /// the start of the window and leave the bytes alone.
        case startWindow
        /// Still inside the window: leave the bytes and the marker alone.
        case keep
        /// Unreadable for longer than the window: move the bytes aside and
        /// start from an empty value.
        case quarantine
    }

    /// Earliest epoch-millisecond instant a stored marker may carry (2001-09-09).
    /// Anything below it (a zero, a small integer or a boolean that ended up in
    /// the marker slot) cannot be a real observation instant.
    public static let minPlausibleMarkerMs: Int64 = 1_000_000_000_000

    /// Pure verdict. The window is exclusive at its end: a value unreadable for
    /// exactly `maxAgeMs` is kept, one millisecond more is quarantined.
    /// A marker that is not a plausible epoch-millisecond instant, that lies
    /// after `nowMs`, or whose distance from `nowMs` overflows is treated like
    /// no marker at all, so a corrupt marker can delay a quarantine by one
    /// window but never trigger one early.
    public static func verdict(nowMs: Int64, firstUnreadableAtMs: Int64?, maxAgeMs: Int64) -> Verdict {
        guard let first = firstUnreadableAtMs, first >= minPlausibleMarkerMs else { return .startWindow }
        let gap = nowMs.subtractingReportingOverflow(first)
        if gap.overflow || gap.partialValue < 0 { return .startWindow }
        if gap.partialValue > maxAgeMs { return .quarantine }
        return .keep
    }
}

/// Applies `UnreadableStoredValuePolicy` to one `UserDefaults` value. Holds no
/// state of its own: the marker and the quarantined copy live in the same
/// domain, under `<valueKey>.unreadable_since` and `<valueKey>.quarantine`, so
/// they survive a relaunch. Callers are expected to be serialised (the outbox
/// that uses it runs on the main actor), exactly like the stores it protects.
public struct UnreadableStoredValueValve {

    /// What the caller must do after reporting an unreadable value.
    public enum Outcome: Equatable {
        /// The bytes were NOT touched (window running or just started): keep
        /// treating the read as failed.
        case blocked
        /// The bytes were moved to the quarantine key and the original key was
        /// cleared: the store may start from an empty value.
        case quarantined
        /// The window ran out but the quarantine copy could not be confirmed,
        /// so nothing was removed: keep treating the read as failed and try
        /// again on the next failed read.
        case quarantineFailed
    }

    public let valueKey: String
    public let markerKey: String
    public let quarantineKey: String
    public let maxAgeMs: Int64
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard, valueKey: String, maxAgeMs: Int64) {
        self.defaults = defaults
        self.valueKey = valueKey
        self.markerKey = valueKey + ".unreadable_since"
        self.quarantineKey = valueKey + ".quarantine"
        self.maxAgeMs = maxAgeMs
    }

    /// The value was read (or there was nothing stored): forget any earlier
    /// failure. Cheap when no marker exists, which is the normal case.
    public func noteReadable() {
        guard defaults.object(forKey: markerKey) != nil else { return }
        defaults.removeObject(forKey: markerKey)
    }

    /// The stored value could not be read back at `nowMs`. Returns what the
    /// caller must do; the only place the stored bytes are ever moved.
    public func noteUnreadable(nowMs: Int64) -> Outcome {
        let recorded: Int64? = recordedMarker()
        let decision = UnreadableStoredValuePolicy.verdict(
            nowMs: nowMs, firstUnreadableAtMs: recorded, maxAgeMs: maxAgeMs)
        switch decision {
        case .startWindow:
            defaults.set(nowMs, forKey: markerKey)
            return .blocked
        case .keep:
            return .blocked
        case .quarantine:
            return quarantineStoredValue()
        }
    }

    private func recordedMarker() -> Int64? {
        guard let raw = defaults.object(forKey: markerKey) else { return nil }
        guard let number = raw as? NSNumber else { return nil }
        return number.int64Value
    }

    /// Copy first, verify, only then remove: a crash or a failed write in the
    /// middle leaves the original bytes exactly where they were (the next
    /// failed read simply repeats the move).
    private func quarantineStoredValue() -> Outcome {
        guard let raw = defaults.object(forKey: valueKey) else {
            // Nothing left to move (the value went away since the failed
            // read): the store is effectively empty already.
            defaults.removeObject(forKey: markerKey)
            return .quarantined
        }
        defaults.set(raw, forKey: quarantineKey)
        let copy: Any? = defaults.object(forKey: quarantineKey)
        guard UnreadableStoredValueValve.sameStoredValue(raw, copy) else {
            return .quarantineFailed
        }
        defaults.removeObject(forKey: valueKey)
        defaults.removeObject(forKey: markerKey)
        return .quarantined
    }

    /// Equality for the two property-list shapes a store persists (sealed
    /// text, or a raw blob). Anything else is "not confirmed", which keeps the
    /// original in place.
    private static func sameStoredValue(_ original: Any, _ copy: Any?) -> Bool {
        if let lhs = original as? String, let rhs = copy as? String {
            return lhs == rhs
        }
        if let lhs = original as? Data, let rhs = copy as? Data {
            return lhs == rhs
        }
        return false
    }
}

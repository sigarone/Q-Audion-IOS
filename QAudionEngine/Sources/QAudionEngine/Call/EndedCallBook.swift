import Foundation

/// The ids of the 1:1 calls that ended on this device recently (bounded by count and by age), and the decision about a
/// handshake fatal that names a call id.
///
/// A confirmation timer or a late event can name a call whose teardown already ran. It must not end anything a second
/// time: no second `hsfatal` line, no second hang-up, and no close reason left behind for the next call.
///
/// The book never shields the call that is active now: when the active call id equals the id in question, the event
/// is for the live call and is acted on whatever the book says. An entry is dropped when a call with that id is
/// admitted again (`forget`), and after `ttlMs`, which is longer than the longest confirmation wait (30 s).
public struct EndedCallBook: Equatable, Sendable {
    public static let capacity = 16
    public static let ttlMs = 120_000

    private struct Entry: Equatable, Sendable { let id: String; let atMs: Int }
    private var entries: [Entry] = []

    public init() {}

    /// Remember that the call `callId` ended at `nowMs` (monotonic). Case-insensitive; empty or nil ids are ignored.
    public mutating func noteEnded(_ callId: String?, nowMs: Int) {
        guard let id = callId?.lowercased(), !id.isEmpty else { return }
        entries.removeAll { $0.id == id || nowMs - $0.atMs >= Self.ttlMs }
        entries.append(Entry(id: id, atMs: nowMs))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    /// A call with this id is admitted (again): it must not be shielded by an earlier end.
    public mutating func forget(_ callId: String) {
        let id = callId.lowercased()
        entries.removeAll { $0.id == id }
    }

    public func hasEnded(_ callId: String, nowMs: Int) -> Bool {
        let id = callId.lowercased()
        return entries.contains { $0.id == id && nowMs - $0.atMs < Self.ttlMs }
    }

    /// True when an event naming `callId` is for a call that already ended. Fails closed: false for the active call,
    /// and false whenever some call is in flight that is not positively identified as a different one (`anyCallInFlight`
    /// with no active id bound yet, e.g. only the CallKit id exists).
    public func isStale(callId: String, activeCallId: String?, anyCallInFlight: Bool, nowMs: Int) -> Bool {
        if let active = activeCallId, !active.isEmpty {
            return active.lowercased() != callId.lowercased() && hasEnded(callId, nowMs: nowMs)
        }
        if anyCallInFlight { return false }
        return hasEnded(callId, nowMs: nowMs)
    }
}

/// What to do with a handshake fatal for `callId`.
public enum HandshakeFatalDecision: Equatable, Sendable {
    /// Another call is the active one, or this call already ended: ignore it (log `hsfatal stale=1`).
    case stale
    /// End the call.
    case proceed

    public static func decide(callId: String, activeCallId: String?, anyCallInFlight: Bool, ended: EndedCallBook,
                              nowMs: Int) -> HandshakeFatalDecision {
        if let active = activeCallId, !active.isEmpty {
            return active.lowercased() == callId.lowercased() ? .proceed : .stale
        }
        if anyCallInFlight { return .proceed }
        return ended.hasEnded(callId, nowMs: nowMs) ? .stale : .proceed
    }
}

/// The assurance verdict persisted at teardown for a call that ended on a handshake failure `reason`. A failed
/// handshake never persists a positive outcome: a key-confirmation failure persists `.kcFailed`, every other
/// failure persists nothing (`nil`).
public enum FatalAssuranceOutcome {
    public static func persisted(forReason reason: String) -> AssuranceState? {
        reason == "kcmac_mismatch" ? .kcFailed : nil
    }

    /// The keys of the stashed verdicts a fatal applies to: the call named by the fatal, else the active call,
    /// else (no id known) every stashed verdict, so that a positive outcome is never persisted for a call that
    /// ended on a failure.
    public static func affectedKeys(callId: String, activeCallId: String?, stashedKeys: [String]) -> [String] {
        if !callId.isEmpty { return [callId.lowercased()] }
        if let active = activeCallId, !active.isEmpty { return [active.lowercased()] }
        return stashedKeys
    }
}

import Foundation

/// A small local note: an OFFER that reached this device before its `call_incoming` and failed the first-OFFER
/// checks was dropped. When the same peer's `call_incoming` for the same call id then arrives, the call ends the way
/// a call whose OFFER arrived second does.
///
/// Local only: nothing is sent or stored on the wire. It is keyed by (call id, sender), bounded by count and by
/// age, consumed once, and dropped when a valid OFFER of the same call and sender is held.
public struct EarlyRejectedOfferBook: Equatable, Sendable {
    public static let capacity = 4
    public static let ttlMs = 60_000

    private struct Entry: Equatable, Sendable { let callId: String; let senderId: String; let atMs: Int }
    private var entries: [Entry] = []

    public init() {}

    private mutating func prune(nowMs: Int) {
        entries.removeAll { nowMs - $0.atMs >= Self.ttlMs }
    }

    public mutating func note(callId: String, senderId: String, nowMs: Int) {
        let id = callId.lowercased()
        guard !id.isEmpty, !senderId.isEmpty else { return }
        prune(nowMs: nowMs)
        entries.removeAll { $0.callId == id && $0.senderId == senderId }
        entries.append(Entry(callId: id, senderId: senderId, atMs: nowMs))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    /// A valid OFFER of this call and sender is held: it supersedes the earlier invalid one.
    public mutating func clear(callId: String, senderId: String) {
        let id = callId.lowercased()
        entries.removeAll { $0.callId == id && $0.senderId == senderId }
    }

    /// True once, when `call_incoming` from `senderId` names a call whose early OFFER from that same sender was dropped.
    public mutating func consume(callId: String, senderId: String, nowMs: Int) -> Bool {
        prune(nowMs: nowMs)
        let id = callId.lowercased()
        let before = entries.count
        entries.removeAll { $0.callId == id && $0.senderId == senderId }
        return entries.count != before
    }

    /// The call is over: nothing may name it afterwards.
    public mutating func forget(callId: String) {
        let id = callId.lowercased()
        entries.removeAll { $0.callId == id }
    }
}

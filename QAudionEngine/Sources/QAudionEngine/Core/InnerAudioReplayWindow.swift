import Foundation

/// MEDIA-5 (W-INNERAUDIOAAD) — the receive-side anti-replay window of the inner sealed-audio wire,
/// keyed on the frame's wire sequence number.
///
/// A circular ring of 1024 slots. Slot `seq % 1024` stores the sequence number accepted into it
/// (or nothing), so a sequence number is a duplicate exactly when its own slot holds it. Nothing
/// is ever shifted: advancing the highest sequence number only changes `highest`, and the entries
/// that fall out of the window are not erased, they simply stop being consulted (a slot's stale
/// value can never equal an in-window sequence number, because they differ by a multiple of 1024).
/// That is the shape Android's `CallController.InnerAudioReplayWindow` and Desktop's `ReplayWindow`
/// use. The previous bitmask had to age its bits on every advance and aged them the wrong way, so
/// only the highest sequence number stayed protected.
///
/// Two operations, so that the window only ever moves for AUTHENTICATED frames (RFC 3711 order):
///   1. ``check(_:)`` is read-only and runs BEFORE the AEAD open. A rejection here costs no crypto.
///   2. ``commit(_:)`` records the sequence number and runs only AFTER the open succeeded.
/// A frame that fails authentication therefore leaves the window untouched: it cannot burn the
/// genuine copy of its own sequence number, and an unauthenticated far-ahead sequence number
/// cannot drag `highest` forward (which would make every genuine frame "too old").
///
/// Not thread-safe by itself: the owner serialises `check` + AEAD open + `commit` under one lock
/// (`QAudionEngine.lock`), which is what makes the pair atomic.
struct InnerAudioReplayWindow {

    enum Verdict: Equatable {
        /// Never accepted and inside (or ahead of) the window: may be processed.
        case fresh
        /// Already accepted: a replay.
        case duplicate
        /// `highest - seq >= windowSize`: older than the window can vouch for.
        case tooOld
    }

    /// Slots in the ring = how far behind the highest accepted sequence number a frame may be.
    static let windowSize: UInt64 = 1024

    /// Highest accepted sequence number; nil until the first commit.
    private var highest: UInt64?
    /// `slots[seq % windowSize]` = the sequence number accepted into that slot.
    private var slots: [UInt64?]

    init() {
        slots = [UInt64?](repeating: nil, count: Int(Self.windowSize))
    }

    /// Would `seq` be accepted right now? Never modifies the window.
    func check(_ seq: UInt64) -> Verdict {
        guard let highest else { return .fresh }
        if seq > highest { return .fresh }
        if highest - seq >= Self.windowSize { return .tooOld }
        return slots[Self.slotIndex(seq)] == seq ? .duplicate : .fresh
    }

    /// Record `seq`. Call ONLY for a frame whose authentication tag verified. Re-checks first and
    /// returns `.fresh` only if the sequence number was actually recorded; any other verdict means
    /// the window was left unchanged.
    @discardableResult
    mutating func commit(_ seq: UInt64) -> Verdict {
        let verdict = check(seq)
        guard verdict == .fresh else { return verdict }
        if let current = highest {
            if seq > current { highest = seq }
        } else {
            highest = seq
        }
        slots[Self.slotIndex(seq)] = seq
        return .fresh
    }

    /// Forget everything. A fresh session/epoch restarts the sender's counter at 0, so the
    /// window restarts with it.
    mutating func reset() {
        highest = nil
        for i in slots.indices { slots[i] = nil }
    }

    private static func slotIndex(_ seq: UInt64) -> Int {
        Int(seq % windowSize)
    }
}

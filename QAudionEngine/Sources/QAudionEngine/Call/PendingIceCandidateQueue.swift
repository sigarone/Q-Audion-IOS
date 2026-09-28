import Foundation

/// W-MEDIAATACCEPT (option b) — §4.7 (G1/iOS-9): a per-`call_id` remote ICE
/// candidate/removal queue, replacing the single GLOBAL, call-id-blind FIFO
/// (`AppState.pendingRemoteIceCandidates`, cap 25) that used to queue
/// whatever `call_ice` envelope arrived before `webRtcController` existed,
/// regardless of which call it was for.
///
/// **Why this had to change under option (b):** the pre-controller window
/// that FIFO existed for (W-ICEQUEUE, 2026-08-13) used to be a few hundred
/// ms — the caller's own ICE trickle racing this device's controller
/// assignment. For a `mode == 1` callee that window is now the WHOLE ring
/// (the media plane, and therefore the controller, does not exist until
/// accept — spec §2.1 RING/KEYED/ACCEPTED). A single global cap-25 FIFO fed
/// for an entire ring either starves out a call's own few candidates behind
/// an unrelated call's, or — worse — could hand a SUPERSEDED call's stale
/// candidates to a brand-new call that happens to reuse the same queue.
///
/// **Not folded into `RingSignalingRegistry`:** that store only ever has an
/// entry for a CALLEE call under a latched ring plan (`latch(...)`, called
/// exclusively from `AppState.latchIncomingNativeSrtpSnapshot`) — an
/// OUTGOING (caller) call never gets one. Candidates for the caller's own
/// brief pre-controller window (this queue's original, pre-option-(b)
/// purpose) must still queue even though no ring plan exists for that call
/// id at all. This store therefore accepts an entry for ANY call id,
/// independent of whether that id ever has a ring-time plan — keyed the
/// same way (lowercased), same coarse `NSLock`, same bounded-eviction shape
/// as `CallKeyStore`/`RingSignalingRegistry`.
///
/// **Admission (§4.7):** every candidate is checked against
/// `RingSignalingDecisions.iceAdmit` — a candidate whose envelope `call_id`
/// does not match the call this device currently considers itself bound to
/// (`AppState.canonicalActiveCallId()`, passed in as `boundCallId`) is
/// dropped, not queued; so is one past the per-call cap (100) or an exact
/// duplicate of one already queued (a WS retransmit).
///
/// **Thread-safety:** one `NSLock`, coarse-grained — enqueue happens per ICE
/// candidate, not a hot per-frame path.
public final class PendingIceCandidateQueue: @unchecked Sendable {

    public static let shared = PendingIceCandidateQueue()

    public struct Candidate: Equatable {
        public let candidate: String
        public let sdpMid: String?
        public let sdpMLineIndex: Int32
        public let removed: Bool

        public init(candidate: String, sdpMid: String?, sdpMLineIndex: Int32, removed: Bool) {
            self.candidate = candidate
            self.sdpMid = sdpMid
            self.sdpMLineIndex = sdpMLineIndex
            self.removed = removed
        }
    }

    private let lock = NSLock()
    private var queues: [String: [Candidate]] = [:]
    /// Insertion order of the call ids currently holding a queue — oldest
    /// first — purely to pick an eviction victim; not itself exposed.
    private var order: [String] = []

    /// Per-call cap — spec §4.7: 100 (up from the old GLOBAL 25).
    public static let perCallCap = 100
    /// Distinct CALLS tracked at once. A little larger than
    /// `RingSignalingRegistry.maxEntries`/`CallKeyStore.maxEntries` since
    /// this queue also covers ordinary outgoing calls that never get a ring
    /// plan at all, not only `mode == 1` ring-time ones.
    public static let maxCalls = 6

    private init() {}

    private static func normalize(_ callId: String) -> String { callId.lowercased() }

    /// Admits (queues) one candidate/removal for `callId`. Returns whether
    /// it was actually queued — `false` covers every drop reason (wrong
    /// call, cap reached, exact duplicate) uniformly; callers that want to
    /// log why can re-derive it from `RingSignalingDecisions.iceAdmit`
    /// themselves if needed, same as this method does internally.
    @discardableResult
    public func enqueue(callId: String, boundCallId: String, _ candidate: Candidate) -> Bool {
        let id = Self.normalize(callId)
        guard !id.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        let count = queues[id]?.count ?? 0
        let decision = RingSignalingDecisions.iceAdmit(
            envelopeCallId: id, boundCallId: Self.normalize(boundCallId), count: count
        )
        guard decision == .queue else { return false }
        if queues[id] == nil {
            evictOldestIfNeededLocked()
            order.append(id)
        }
        if queues[id]?.contains(candidate) == true { return false }
        queues[id, default: []].append(candidate)
        return true
    }

    /// Oldest-call eviction when a call beyond `maxCalls` would start a new
    /// queue — same bounded-slots reasoning as
    /// `RingSignalingRegistry`/`CallKeyStore`.
    private func evictOldestIfNeededLocked() {
        guard order.count >= Self.maxCalls, let oldest = order.first else { return }
        order.removeFirst()
        queues[oldest] = nil
    }

    /// Read-and-clear every queued candidate for `callId`, oldest first —
    /// call once a controller exists for `callId` so it can replay every
    /// candidate that arrived while it didn't. A no-op empty read when
    /// nothing is queued.
    public func drain(_ callId: String) -> [Candidate] {
        let id = Self.normalize(callId)
        lock.lock(); defer { lock.unlock() }
        guard let q = queues[id] else { return [] }
        queues[id] = nil
        order.removeAll { $0 == id }
        return q
    }

    /// Drops every queued candidate for `callId` WITHOUT returning them —
    /// call teardown (`AppState.wipeRingState`, reject, cancel, timeout).
    public func wipe(_ callId: String) {
        let id = Self.normalize(callId)
        lock.lock(); defer { lock.unlock() }
        queues[id] = nil
        order.removeAll { $0 == id }
    }

    /// Drops EVERY call's queue — the broad teardown paths that, before
    /// this queue existed, called `pendingRemoteIceCandidates.removeAll()`
    /// with no call id in scope at all (CallKit reset, `endCall()`,
    /// `dropFailedOutgoingWebRtcController`).
    public func wipeAll() {
        lock.lock(); defer { lock.unlock() }
        queues.removeAll()
        order.removeAll()
    }

    /// Test-only full reset.
    func resetForTesting() {
        lock.lock(); queues.removeAll(); order.removeAll(); lock.unlock()
    }

    /// Test-only peek without draining.
    func peekForTesting(_ callId: String) -> [Candidate] {
        let id = Self.normalize(callId)
        lock.lock(); defer { lock.unlock() }
        return queues[id] ?? []
    }
}

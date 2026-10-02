import Foundation

/// W-MEDIAATACCEPT (option b, owner decision 2026-09-28) — the callee's
/// per-call state while the phone is RINGING. There is ONE callee path (WIRE_SPEC §3.7.4
/// R-ANSWER-FIRST, T2 of the v6 timer round): while the phone rings, only the application-layer
/// handshake material is held (the OFFER is stashed, nothing is sent). No ACCEPT, no handshake timer, no
/// PeerConnection, no SDP answer, no ICE, no DTLS-SRTP, no cryptors and no audio session exist before the
/// human answer. There is no pre-answer mode and no flag selects another one: the former
/// `calls.ring_signaling_only` setting is no longer read. A call without a `callId` never gets an
/// entry here: it cannot run v6 and ends with `handshake_malformed` before any ACCEPT.
///
/// Lives in `QAudionEngine` (not `QAudionApp`) because both
/// `BCryptoCallingApiImpl` (answer/ICE send counters, §4.6) and
/// `QAudionCallIntegration` (ACCEPT hold, §4.5) need to reach it from
/// outside the app target's `AppState`.
///
/// **Thread-safety:** a single `NSLock` guards the whole table. Calls are
/// rare (per-ring, not per-frame) so a coarse lock is the right tradeoff —
/// same pattern as `CallCapabilities`'s `nativeSrtpSnapshotLock` and
/// `QAudionCallIntegration`'s own `lock`.
///
/// **I8:** `native`/`kill` are latched ONCE per `callId` — the first
/// `latch(...)` call wins; a duplicate `call_incoming` for the same call
/// never changes them (`Entry.latchedAtMs` marks when the FIRST write
/// happened, not the most recent).
///
/// **I13:** every ring-time artifact is keyed by the network `call_id`,
/// lowercased, and is wiped together (`wipe(_:why:)`) on reject, cancel,
/// timeout, call end, or supersession by a newer call.
public final class RingSignalingRegistry: @unchecked Sendable {

    public static let shared = RingSignalingRegistry()

    /// One offer stashed while the phone rings — the caller's SDP + peer
    /// capabilities, kept fresh across duplicate `call_incoming`/`call_offer`
    /// envelopes (W-BLANKRERINGSDP parity, see `RingSignalingDecisions.offerUpdate`).
    public struct OfferInfo: Equatable {
        public let sdp: String
        public let capabilities: [String]?
        public let hasVideo: Bool
        public let len: Int

        public init(sdp: String, capabilities: [String]?, hasVideo: Bool) {
            self.sdp = sdp
            self.capabilities = capabilities
            self.hasVideo = hasVideo
            self.len = sdp.count
        }
    }

    /// Media-plane build state for the callee, once accepted. `.none` before
    /// accept; the state machine only ever moves forward (never back to an
    /// earlier stage for the SAME call) except that a later call may reuse a
    /// fresh `.none` entry after `wipe`.
    public enum MediaPlaneState: Equatable {
        case none
        case awaitingSdp
        case building
        case ready
        case failed
    }

    public struct Entry {
        /// Effective native-SRTP snapshot for this call (post kill-switch),
        /// latched once alongside `kill` — I8.
        public var native: Bool
        /// The `calls.native_srtp_kill` value read at latch time.
        public var kill: Bool
        public var latchedAtMs: Int64

        public var offer: OfferInfo?
        public var mediaPlane: MediaPlaneState = .none
        public var acceptedAtMs: Int64?
        public var answerSent: Bool = false
        public var acceptReleased: Bool = false

        /// T4 counters — must read 0 at accept time (I3 invariant table, §11 T4).
        /// Only incremented while `acceptedAtMs == nil`.
        public var preAcceptIce: Int = 0
        public var preAcceptAnswers: Int = 0
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    /// Evicted rather than grown without bound — a device can only be
    /// ringing for a small, bounded number of calls at once (single-dialer
    /// guarantee elsewhere already keeps this near 1 in practice).
    public static let maxEntries = 4

    /// TTL for a ring-time entry that never reaches accept — a caller that
    /// vanished without a `call_hangup`/`call_cancel` (network loss) must
    /// not pin a slot forever.
    public static let ttlMs: Int64 = 90_000

    /// Fires (off the lock) after a `call_answer` send is recorded via
    /// `noteAnswerSent`. AppState wires this to `releaseHeldAcceptIfDue`.
    ///
    /// Review fix: guarded by `lock` like the rest of the table — AppState
    /// (re)assigns it on the main actor at every `call_incoming`, while
    /// `noteAnswerSent` reads it from whatever thread `sendCallAnswer` runs
    /// on; an unguarded closure property read concurrently with a write is
    /// a torn two-word value.
    private var _onAnswerSent: ((String) -> Void)?
    public var onAnswerSent: ((String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onAnswerSent }
        set { lock.lock(); _onAnswerSent = newValue; lock.unlock() }
    }

    private init() {}

    private static func normalize(_ callId: String) -> String {
        callId.lowercased()
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    // MARK: - Latch (I8: first write wins)

    /// Latch the per-call plan. A `callId` empty string is never stored: a call with no id to index by
    /// cannot run v6 (the commitment binds the callId) and is rejected by the caller before any ACCEPT
    /// (T2); there is no other path to fall back to.
    @discardableResult
    public func latch(_ callId: String, native: Bool, kill: Bool) -> Entry? {
        guard !callId.isEmpty else { return nil }
        let id = Self.normalize(callId)
        lock.lock()
        defer { lock.unlock() }
        if let existing = entries[id] {
            return existing
        }
        evictOldestIfNeededLocked()
        let entry = Entry(native: native, kill: kill, latchedAtMs: Self.nowMs())
        entries[id] = entry
        return entry
    }

    /// Oldest-by-`latchedAtMs` eviction when a 5th call would be latched —
    /// spec §4.1: "Massimo 4 voci; oltre, si scarta la più vecchia con
    /// `why=5`." Caller logs `why=5` itself; this just makes room.
    private func evictOldestIfNeededLocked() {
        guard entries.count >= Self.maxEntries else { return }
        if let oldestKey = entries.min(by: { $0.value.latchedAtMs < $1.value.latchedAtMs })?.key {
            entries.removeValue(forKey: oldestKey)
        }
    }

    public func entry(_ callId: String) -> Entry? {
        let id = Self.normalize(callId)
        lock.lock(); defer { lock.unlock() }
        return entries[id]
    }

    // MARK: - Offer (W-DCSTUCK parity: SDP stays stashed, never wiped by an empty replay)

    public enum OfferUpdate: Equatable {
        case accepted(len: Int)
        case ignoredEmpty
        case noPlan
    }

    /// Applies `RingSignalingDecisions.offerUpdate` under the lock. Returns
    /// `.noPlan` when there is no latched entry for this call (nothing to
    /// update: the caller drops an OFFER for a call that was never latched).
    @discardableResult
    public func updateOffer(_ callId: String, sdp: String, capabilities: [String]?, hasVideo: Bool) -> OfferUpdate {
        let id = Self.normalize(callId)
        lock.lock(); defer { lock.unlock() }
        guard var e = entries[id] else { return .noPlan }
        switch RingSignalingDecisions.offerUpdate(existingSdp: e.offer?.sdp, incomingSdp: sdp) {
        case .keepIncoming:
            e.offer = OfferInfo(sdp: sdp, capabilities: capabilities, hasVideo: hasVideo)
            entries[id] = e
            return .accepted(len: sdp.count)
        case .keepExisting:
            return .ignoredEmpty
        }
    }

    // MARK: - Accept / media plane

    public func markAccepted(_ callId: String, nowMs: Int64? = nil) {
        let id = Self.normalize(callId)
        lock.lock(); defer { lock.unlock() }
        guard var e = entries[id] else { return }
        guard e.acceptedAtMs == nil else { return }
        e.acceptedAtMs = nowMs ?? Self.nowMs()
        entries[id] = e
    }

    public func setMediaPlane(_ callId: String, _ plane: MediaPlaneState) {
        let id = Self.normalize(callId)
        lock.lock(); defer { lock.unlock() }
        guard var e = entries[id] else { return }
        e.mediaPlane = plane
        entries[id] = e
    }

    /// T4 — `pre_accept_local_cands`. Only counts while the call hasn't
    /// been accepted yet (I3: must read 0 at accept).
    public func noteLocalIceSent(_ callId: String) {
        let id = Self.normalize(callId)
        lock.lock(); defer { lock.unlock() }
        guard var e = entries[id] else { return }
        guard e.acceptedAtMs == nil else { return }
        e.preAcceptIce += 1
        entries[id] = e
    }

    /// T4 — `answer` sent before accept (must read 0), AND
    /// the I11 release trigger once the call HAS been accepted. `sdpEmpty`
    /// is carried only for the caller's own logging (T5/T6 `why`).
    public func noteAnswerSent(_ callId: String, sdpEmpty: Bool) {
        let id = Self.normalize(callId)
        var shouldFireCallback = false
        lock.lock()
        if var e = entries[id] {
            if e.acceptedAtMs == nil {
                e.preAcceptAnswers += 1
            } else if !e.answerSent {
                shouldFireCallback = true
            }
            e.answerSent = true
            entries[id] = e
        }
        let callback = _onAnswerSent
        lock.unlock()
        if shouldFireCallback {
            callback?(id)
        }
    }

    // MARK: - ACCEPT hold (I11)

    public func shouldHoldAccept(_ callId: String, nowMs: Int64? = nil) -> Bool {
        let id = Self.normalize(callId)
        // A call with no id can never be answered (it ends as `handshake_malformed`): no ACCEPT may leave.
        guard !id.isEmpty else { return true }
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[id] else {
            // No plan for this call (OFFER arrived before call_incoming,
            // W-OFFERBUFFER, or the call was wiped): an ACCEPT is never sent
            // for a call nobody answered, so hold (fail closed).
            return true
        }
        return RingSignalingDecisions.shouldHoldAccept(
            acceptedAtMs: e.acceptedAtMs,
            answerSent: e.answerSent,
            released: e.acceptReleased,
            nowMs: nowMs ?? Self.nowMs()
        )
    }

    public func markReleased(_ callId: String) {
        let id = Self.normalize(callId)
        lock.lock(); defer { lock.unlock() }
        guard var e = entries[id] else { return }
        e.acceptReleased = true
        entries[id] = e
    }

    // MARK: - Teardown (I13)

    /// Removes every ring-time artifact for `callId`. `why` is caller-logged
    /// (T3) — this call itself has no side effect beyond the table entry;
    /// `CallKeyStore.wipe`, `QAudionCallIntegration.dropHeldAccept`, the
    /// pending-ICE queue and the 2s/5s/8s timers are each torn down by their
    /// own owners from the same `wipeRingState` chokepoint (AppState).
    public func wipe(_ callId: String, why: Int) {
        let id = Self.normalize(callId)
        lock.lock(); defer { lock.unlock() }
        entries.removeValue(forKey: id)
    }

    /// TTL sweep for entries that latched but never got accepted — spec
    /// §4.1 `sweep(nowMs:)`, 90s. Call from a low-frequency timer (or before
    /// each new `latch`); cheap no-op when the table is small.
    public func sweep(nowMs: Int64? = nil) {
        let now = nowMs ?? Self.nowMs()
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { _, e in
            if e.acceptedAtMs != nil { return true }
            return (now - e.latchedAtMs) < Self.ttlMs
        }
    }

    /// Test-only full reset.
    func resetForTesting() {
        lock.lock(); entries.removeAll(); lock.unlock()
    }
}

/// Pure decision functions behind `RingSignalingRegistry` — no locks, no
/// I/O, no `Date()` calls (callers pass `nowMs`) so every branch is a plain
/// unit test. Kept in the same file as the registry per spec §4.1.
public enum RingSignalingDecisions {

    public enum OfferUpdateDecision: Equatable {
        case keepIncoming
        case keepExisting
    }

    /// W-BLANKRERINGSDP parity (Android `WsCallSignaller:1320-1338`): a
    /// blank SDP never overwrites a previously-stashed non-blank one — a
    /// duplicate `call_incoming`/`call_offer` envelope that races the SDP
    /// field being populated must not blank out an offer already stashed.
    /// An incoming NON-blank SDP always replaces whatever was there
    /// (including a previous non-blank one — the peer's latest OFFER wins).
    public static func offerUpdate(existingSdp: String?, incomingSdp: String) -> OfferUpdateDecision {
        if incomingSdp.isEmpty {
            return .keepExisting
        }
        return .keepIncoming
    }

    /// Whether `startIncomingMediaPlane` should actually build the PC now.
    /// `state` is the call's CURRENT `RingSignalingRegistry.MediaPlaneState`
    /// — building starts only from `.none`/`.awaitingSdp` (idempotent: a
    /// second accept-time call, or an offer arriving mid-build, is a no-op).
    public static func shouldStartMediaPlane(
        accepted: Bool,
        hasSdp: Bool,
        state: RingSignalingRegistry.MediaPlaneState
    ) -> Bool {
        guard accepted else { return false }
        switch state {
        case .none, .awaitingSdp:
            return hasSdp
        case .building, .ready, .failed:
            return false
        }
    }

    /// I11 — the callee's ACCEPT is trattenuto (held) until either its own
    /// `call_answer` is sent, or a 5s reserve timer from accept elapses.
    /// An already-released/answered call never holds.
    public static let acceptReserveMs: Int64 = 5_000

    public static func shouldHoldAccept(
        acceptedAtMs: Int64?,
        answerSent: Bool,
        released: Bool,
        nowMs: Int64
    ) -> Bool {
        guard !released else { return false }
        guard let acceptedAt = acceptedAtMs else {
            // Not yet accepted at all — always hold.
            return true
        }
        if answerSent { return false }
        let elapsed = nowMs - acceptedAt
        return elapsed < acceptReserveMs
    }

    /// §4.6 — whether `startAudioIOIfReady` must defer to avoid racing
    /// CallKit's `didActivate` against the still-building PeerConnection
    /// (two VoiceProcessingIO units, W-ADMFALLBACK). Only gates when the
    /// call is predicted to end up native — a call that will use the custom
    /// (non-native) audio path never needs to wait on the PC.
    public enum AudioIOGateDecision: Equatable {
        case deferGate5
        case proceed
    }

    public static func audioIOGate(
        mediaPlane: RingSignalingRegistry.MediaPlaneState,
        predictedNative: Bool
    ) -> AudioIOGateDecision {
        guard predictedNative else { return .proceed }
        switch mediaPlane {
        case .none, .awaitingSdp, .building:
            return .deferGate5
        case .ready, .failed:
            return .proceed
        }
    }

    /// §4.7 — per-`call_id` remote ICE queue admission. A candidate for a
    /// DIFFERENT call than the one currently bound/ringing is always
    /// dropped (it belongs to a superseded or unrelated call); the queue
    /// itself has a 100-candidate cap per call.
    public enum IceAdmitDecision: Equatable {
        case queue
        case drop
    }

    public static let iceQueueCap = 100

    public static func iceAdmit(envelopeCallId: String, boundCallId: String, count: Int) -> IceAdmitDecision {
        guard !boundCallId.isEmpty, envelopeCallId.lowercased() == boundCallId.lowercased() else {
            return .drop
        }
        guard count < iceQueueCap else { return .drop }
        return .queue
    }
}

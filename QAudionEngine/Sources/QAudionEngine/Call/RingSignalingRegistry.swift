import Foundation

/// W-MEDIAATACCEPT (option b, owner decision 2026-09-28) — the callee's
/// per-call state while the phone is RINGING, when `calls.ring_signaling_only`
/// (`mode == 1`) is on: only the application-layer PQC handshake and caller-
/// identity verification run during RING (signaling channel only). The
/// WebRTC media plane (`QAudionWebRtcCallController`/`QAudionPeerConnection`,
/// SDP answer, ICE, DTLS-SRTP, cryptors, audio session) starts only after the
/// human accept — see spec §2.1/§4.
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
/// **I8:** `mode`/`native`/`kill` are latched ONCE per `callId` — the first
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
        /// 1 = signaling-only (media plane starts at accept); 0 = legacy
        /// (today's iOS behavior: full setup at ring).
        public var mode: Int
        /// Effective native-SRTP snapshot for this call (post kill-switch),
        /// latched once alongside `mode`/`kill` — I8.
        public var native: Bool
        /// The `calls.native_srtp_kill` value read at latch time.
        public var kill: Bool
        public var latchedAtMs: Int64

        public var offer: OfferInfo?
        public var mediaPlane: MediaPlaneState = .none
        public var acceptedAtMs: Int64?
        public var answerSent: Bool = false
        public var acceptReleased: Bool = false

        /// T4 counters — must read 0 at accept time under `mode == 1` (I3
        /// invariant table, §11 T4). Only incremented while `acceptedAtMs == nil`.
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

    /// Fleet-wide fallback for a callId with no latched entry yet (e.g. an
    /// OFFER arriving before its `call_incoming`, W-OFFERBUFFER). AppState
    /// keeps this in sync with the compiled/remote flag at login and at
    /// every `call_incoming` — see `FeatureFlags.bool("calls.ring_signaling_only", true)`.
    /// Guarded by `lock` like everything else here (not a hot path — read
    /// once per ring/OFFER, not per frame).
    private var _defaultMode: Int = 1
    public var defaultMode: Int {
        get { lock.lock(); defer { lock.unlock() }; return _defaultMode }
        set { lock.lock(); _defaultMode = newValue; lock.unlock() }
    }

    /// Fires (off the lock) after a `call_answer` send is recorded via
    /// `noteAnswerSent`. AppState wires this to `releaseHeldAcceptIfDue`.
    public var onAnswerSent: ((String) -> Void)?

    private init() {}

    private static func normalize(_ callId: String) -> String {
        callId.lowercased()
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    // MARK: - Latch (I8: first write wins)

    /// Latch the per-call plan. A `callId` empty string is never stored —
    /// callers with no id to index by (spec §3: "iOS: con callIdStr vuoto si
    /// forza mode=0, why=7") must go through the legacy path instead; use
    /// `mode: 0` at the call site rather than latching here.
    @discardableResult
    public func latch(_ callId: String, mode: Int, native: Bool, kill: Bool) -> Entry? {
        guard !callId.isEmpty else { return nil }
        let id = Self.normalize(callId)
        lock.lock()
        defer { lock.unlock() }
        if let existing = entries[id] {
            return existing
        }
        evictOldestIfNeededLocked()
        let entry = Entry(mode: mode, native: native, kill: kill, latchedAtMs: Self.nowMs())
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
    /// update — the legacy path handles the OFFER itself in that case).
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
    /// been accepted yet (I3: must read 0 at accept under `mode == 1`).
    public func noteLocalIceSent(_ callId: String) {
        let id = Self.normalize(callId)
        lock.lock(); defer { lock.unlock() }
        guard var e = entries[id] else { return }
        guard e.acceptedAtMs == nil else { return }
        e.preAcceptIce += 1
        entries[id] = e
    }

    /// T4 — `answer` sent before accept (must read 0 under `mode == 1`), AND
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
        lock.unlock()
        if shouldFireCallback {
            onAnswerSent?(id)
        }
    }

    // MARK: - ACCEPT hold (I11)

    public func shouldHoldAccept(_ callId: String, nowMs: Int64? = nil) -> Bool {
        let id = Self.normalize(callId)
        guard !id.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[id] else {
            // No plan for this call (OFFER arrived before call_incoming,
            // W-OFFERBUFFER) — fall back to the fleet default. Reads
            // `_defaultMode` directly: `lock` is already held here and
            // `NSLock` is not reentrant, so the public `defaultMode`
            // computed property (which re-locks) would deadlock.
            return _defaultMode == 1
        }
        return RingSignalingDecisions.shouldHoldAccept(
            mode: e.mode,
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

    /// Test-only full reset. Sets `_defaultMode` directly under the same
    /// lock (see `shouldHoldAccept`'s note on why the public setter can't
    /// be used here).
    func resetForTesting() {
        lock.lock(); entries.removeAll(); _defaultMode = 1; lock.unlock()
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
        mode: Int,
        accepted: Bool,
        hasSdp: Bool,
        state: RingSignalingRegistry.MediaPlaneState
    ) -> Bool {
        guard mode == 1, accepted else { return false }
        switch state {
        case .none, .awaitingSdp:
            return hasSdp
        case .building, .ready, .failed:
            return false
        }
    }

    /// I11 — the callee's ACCEPT is trattenuto (held) until either its own
    /// `call_answer` is sent, or a 5s reserve timer from accept elapses.
    /// `mode == 0` (legacy) or an already-released/answered call never
    /// holds.
    public static let acceptReserveMs: Int64 = 5_000

    public static func shouldHoldAccept(
        mode: Int,
        acceptedAtMs: Int64?,
        answerSent: Bool,
        released: Bool,
        nowMs: Int64
    ) -> Bool {
        guard mode == 1 else { return false }
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
    /// call is BOTH signaling-only-mode AND predicted to end up native —
    /// a call that will use the custom (non-native) audio path never needs
    /// to wait on the PC.
    public enum AudioIOGateDecision: Equatable {
        case deferGate5
        case proceed
    }

    public static func audioIOGate(
        mode: Int,
        mediaPlane: RingSignalingRegistry.MediaPlaneState,
        predictedNative: Bool
    ) -> AudioIOGateDecision {
        guard mode == 1, predictedNative else { return .proceed }
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

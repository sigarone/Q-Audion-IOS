import Foundation

// Call hold on the sealed in-call control lane, WIRE_SPEC section 16 (1:1 calls only).
//
// This file holds the pure parts, byte compatible with Android `CallHold.kt` / `HoldLegPolicy.kt` / `HoldTone.kt`: the two
// frame bodies and the serial arithmetic (`CallHoldWire`), the leg rules of 16.3 (`HoldLegPolicy`), the sender state
// machine (`CallHoldSender`: cause set, seq, retransmission), the receiver state machine (`CallHoldReceiver`: seq
// de-duplication, 30 minute expiry, lost-RESUMED clearing), the 10 s hint of 16.6 (`PeerAudibleHint`), the silence gate of
// 16.4 item 3 (`HoldSilenceGate`), the local hold tone (`HoldToneSynth`) and the iOS audio triggers (`AudioHoldTriggerState`).
// Nothing here touches a socket, a clock of its own or AVFoundation: the call code feeds it.

// MARK: - Wire

public enum CallHoldWire {
    public static let ver: UInt8 = 0x01

    public static let stateHeld: UInt8 = 0x01
    public static let stateResumed: UInt8 = 0x02

    public static let causeUnspecified: UInt8 = 0x00
    /// System call (CallKit hold).
    public static let causeSystemCall: UInt8 = 0x01
    /// Audio interruption (AVAudioSession interruption, or the system deactivated the session).
    public static let causeAudioInterruption: UInt8 = 0x02
    public static let causeUser: UInt8 = 0x03

    public static let holdBodySize = 5
    public static let ackBodySize = 3

    /// A decoded CALL_HOLD body. `cause` is already normalised: an unknown value reads as unspecified.
    public struct Hold: Equatable, Sendable {
        public let state: UInt8
        public let cause: UInt8
        public let seq: UInt16
        public var held: Bool { state == CallHoldWire.stateHeld }
        public init(state: UInt8, cause: UInt8, seq: UInt16) {
            self.state = state
            self.cause = cause
            self.seq = seq
        }
    }

    /// `ver || state || cause || seq(2, big endian)`.
    public static func encodeHold(state: UInt8, cause: UInt8, seq: UInt16) -> Data {
        Data([ver, state, cause, UInt8(seq >> 8), UInt8(seq & 0xFF)])
    }

    /// `ver || seq(2, big endian)`.
    public static func encodeAck(seq: UInt16) -> Data {
        Data([ver, UInt8(seq >> 8), UInt8(seq & 0xFF)])
    }

    /// The whole CALL_HOLD control frame: `03 04 || body`.
    public static func holdFrame(state: UInt8, cause: UInt8, seq: UInt16) -> Data {
        WireRelayFrameCodec.encodeControl(kind: WireRelayFrameCodec.controlKindCallHold,
                                          body: encodeHold(state: state, cause: cause, seq: seq))
    }

    /// The whole CALL_HOLD_ACK control frame: `03 05 || body`.
    public static func ackFrame(seq: UInt16) -> Data {
        WireRelayFrameCodec.encodeControl(kind: WireRelayFrameCodec.controlKindCallHoldAck, body: encodeAck(seq: seq))
    }

    /// Decodes a CALL_HOLD body. nil (dropped, never acknowledged) for a body shorter than 5 bytes, a `ver` other than 1
    /// or a `state` other than 1 and 2. Trailing bytes are ignored.
    public static func decodeHold(_ body: Data) -> Hold? {
        let b = [UInt8](body)
        guard b.count >= holdBodySize, b[0] == ver else { return nil }
        let state = b[1]
        guard state == stateHeld || state == stateResumed else { return nil }
        let cause: UInt8 = (b[2] == causeSystemCall || b[2] == causeAudioInterruption || b[2] == causeUser) ? b[2] : causeUnspecified
        let seq = (UInt16(b[3]) << 8) | UInt16(b[4])
        return Hold(state: state, cause: cause, seq: seq)
    }

    /// Decodes a CALL_HOLD_ACK body into its seq; nil for a body shorter than 3 bytes or a `ver` other than 1.
    public static func decodeAck(_ body: Data) -> UInt16? {
        let b = [UInt8](body)
        guard b.count >= ackBodySize, b[0] == ver else { return nil }
        return (UInt16(b[1]) << 8) | UInt16(b[2])
    }

    /// Serial number arithmetic: `seq` is newer than `last` when `(seq - last) mod 65536` is in 1...32767.
    public static func isNewer(_ seq: UInt16, than last: UInt16) -> Bool {
        let d = seq &- last
        return d >= 1 && d <= 32767
    }
}

// MARK: - Legs

/// How a hold frame is routed over the two legs (WIRE_SPEC 16.3).
public enum HoldRoute: Equatable, Sendable {
    /// The first send of a state: the DataChannel when open and carrying, else the sealed relay leg.
    case first
    /// Every retry (and every re-send after an event): both legs where the relay leg is allowed.
    case both
    /// An ACK for a frame that arrived on the DataChannel: the DataChannel.
    case replyDc
    /// An ACK for a frame that arrived on the relay leg: the relay leg, when it is allowed.
    case replyRelay
}

public enum HoldLeg: Equatable, Sendable {
    case dc
    case relay
}

/// The outer layer of the call as the hold frames see it (WIRE_SPEC 16.1).
public enum HoldOuterState: Equatable, Sendable {
    /// `srtpDirKeyV1` negotiated and the sealer installed: every frame of both legs is sealed.
    case sealed
    /// No outer seal for this call: the DataChannel carries the bare inner frame inside DTLS, the relay is never used.
    case off
    /// Before the session key installs the sealers: nothing is sent, the state is remembered.
    case undecided

    /// Maps the engine's outer-layer mode and the sealer's presence. `.unknown` with a sealer installed already seals
    /// (as `OuterLayerPolicy.tx` does); `.sealed` without a sealer, and `.unknown` without one, are undecided.
    public static func from(mode: OuterLayerMode, sealerInstalled: Bool) -> HoldOuterState {
        switch mode {
        case .sealed, .unknown:
            return sealerInstalled ? .sealed : .undecided
        case .noOuter, .offLocalInstall, .offPeerInstall:
            return .off
        }
    }
}

/// WIRE_SPEC 16.3 leg selection for the hold frames, and the capability gate of the control kinds, as pure functions.
public enum HoldLegPolicy {
    /// The legs a hold frame is written to.
    ///
    /// - undecided: none (the frame is not sent; the sender re-sends once the outer layer is decided).
    /// - first: the DataChannel when it is open and carrying; otherwise the sealed relay leg when it is allowed;
    ///   otherwise the DataChannel (the only leg there is, the schedule is all there is).
    /// - both: the DataChannel, and the relay leg when it is allowed.
    /// - replyDc / replyRelay: the leg the frame arrived on (the relay only when allowed).
    /// - off never reaches the relay: `relayAllowed` is ignored there, and only the DataChannel audio write path is used.
    ///
    /// - Parameter relayAllowed: the relay leg exists, is armed and the signalling socket is up.
    public static func select(route: HoldRoute, dcOpenCarrying: Bool, relayAllowed: Bool, outer: HoldOuterState) -> [HoldLeg] {
        if outer == .undecided { return [] }
        let relay = relayAllowed && outer == .sealed
        switch route {
        case .first:
            if dcOpenCarrying { return [.dc] }
            if relay { return [.relay] }
            return [.dc]
        case .both:
            return relay ? [.dc, .relay] : [.dc]
        case .replyDc:
            return [.dc]
        case .replyRelay:
            return relay ? [.relay] : []
        }
    }

    /// The capability tag a control kind is gated on. The hold kinds have their own branch: a peer with `dc-hangup-v1`
    /// and no `call-hold-v1` must receive no hold frame.
    public static func requiredTag(kind: UInt8) -> String {
        switch kind {
        case WireRelayFrameCodec.controlKindNackRequest:
            return CallCapabilities.audioNackV1
        case WireRelayFrameCodec.controlKindCallHold, WireRelayFrameCodec.controlKindCallHoldAck:
            return CallCapabilities.callHoldV1
        default:
            return CallCapabilities.dcHangupV1
        }
    }
}

// MARK: - Receive trust

/// Whether a received hold frame (kind `0x04` or `0x05`) may act. A hold frame changes what the user sees and suspends a
/// silence watchdog, so it must be authenticated: either the outer seal was really opened (a frame of a SEALED call), or the
/// call has no outer seal and the frame came over the DTLS DataChannel (OFF; the relay leg of such a call is closed). A frame
/// that merely passed through unopened (no recv sealer yet, the relay in OFF, a call whose outer state is unknown) is dropped,
/// as is every hold frame of a call for which `call-hold-v1` was not negotiated.
public enum HoldRxTrust {
    public static func accept(mode: OuterLayerMode, leg: OuterLayerLeg, recvSealerInstalled: Bool, peerHasTag: Bool) -> Bool {
        guard peerHasTag else { return false }
        return frameIsAuthenticated(rx: OuterLayerPolicy.rx(mode: mode, leg: leg, recvSealerInstalled: recvSealerInstalled),
                                    mode: mode, leg: leg)
    }

    /// The same decision taken from what the receive path did with THIS frame: `rx` is the decision it acted on, `mode` the
    /// mode it was taken under. The caller keeps the answer with the frame and never re-reads the sealer slot or the mode.
    public static func frameIsAuthenticated(rx: OuterLayerPolicy.Rx, mode: OuterLayerMode, leg: OuterLayerLeg) -> Bool {
        switch rx {
        case .open:
            return true
        case .passThrough:
            return mode.isOuterOff && leg == .dataChannel
        case .hold, .drop:
            return false
        }
    }
}

// MARK: - Sender

public typealias HoldCancel = () -> Void
/// Runs `work` after `delaySeconds` and returns a closure that cancels it.
public typealias HoldSchedule = (_ delaySeconds: TimeInterval, _ work: @escaping () -> Void) -> HoldCancel

public enum HoldSchedulers {
    /// The production scheduler: the main queue.
    public static let mainQueue: HoldSchedule = { delay, work in
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }
}

/// Sender side of WIRE_SPEC 16.3: a set of active hold causes, one seq per HELD/RESUMED change, a retransmission schedule
/// (t=0, then after 0.4 s, 1 s, 2 s, 4 s and 8 s: six sends) that ends on the matching ACK or a newer state, and a re-send
/// of an unacknowledged state after the events the call code reports through `resendAfter`.
///
/// The transport is reached through the `send` closure and time through `schedule`, so the class is testable in virtual
/// time. It never blocks a call operation on an ACK. State is guarded by a lock; no closure runs under it.
public final class CallHoldSender: @unchecked Sendable {
    /// Six sends in all: t=0, then after 0.4 s, 1 s, 2 s, 4 s and 8 s from the first.
    public static let sendCount = 6
    /// Gaps between two consecutive sends: the absolute times are 0, 0.4, 1, 2, 4, 8 s.
    public static let retryDelays: [TimeInterval] = [0.4, 0.6, 1.0, 2.0, 4.0]
    /// After the sixth send an ACK may still be on its way; the never-acknowledged counter waits this long.
    public static let neverAckedGrace: TimeInterval = 2.0

    private let lock = NSLock()
    private var causes: [UInt8] = []
    private var seq: UInt16 = 0
    /// At least one state change was made (seq 0 is a legitimate value after 65536 changes).
    private var hasChange = false
    private var state: UInt8 = CallHoldWire.stateResumed
    private var frameCause: UInt8 = CallHoldWire.causeUnspecified
    /// The last state change has been acknowledged (or there is none).
    private var acked = true
    /// The last state change could not be sent because the peer tag was not known: send it when it is.
    private var pendingTag = false
    private var cancelTimer: HoldCancel?
    private var closed = false

    private let peerHasTag: () -> Bool
    private let send: (_ kind: UInt8, _ body: Data, _ route: HoldRoute) -> Bool
    private let schedule: HoldSchedule
    private let onStateChange: (_ held: Bool, _ cause: UInt8, _ seq: UInt16) -> Void
    private let onNeverAcked: (_ seq: UInt16) -> Void

    /// - Parameters:
    ///   - peerHasTag: whether the peer advertised `call-hold-v1` for this call (the gate; never another kind's tag).
    ///   - send: writes one CALL_HOLD frame under the given route; true when something was written.
    public init(peerHasTag: @escaping () -> Bool,
                send: @escaping (_ kind: UInt8, _ body: Data, _ route: HoldRoute) -> Bool,
                schedule: @escaping HoldSchedule = HoldSchedulers.mainQueue,
                onStateChange: @escaping (_ held: Bool, _ cause: UInt8, _ seq: UInt16) -> Void = { _, _, _ in },
                onNeverAcked: @escaping (_ seq: UInt16) -> Void = { _ in }) {
        self.peerHasTag = peerHasTag
        self.send = send
        self.schedule = schedule
        self.onStateChange = onStateChange
        self.onNeverAcked = onNeverAcked
    }

    public var held: Bool { lock.lock(); defer { lock.unlock() }; return !causes.isEmpty }
    public var currentSeq: UInt16 { lock.lock(); defer { lock.unlock() }; return seq }
    public var acknowledged: Bool { lock.lock(); defer { lock.unlock() }; return acked }

    /// Adds `cause`; the first one makes the call HELD (one state change, next seq, immediate CALL_HOLD). Returns true when
    /// the state changed.
    @discardableResult
    public func addCause(_ cause: UInt8) -> Bool {
        lock.lock()
        if closed { lock.unlock(); return false }
        let wasEmpty = causes.isEmpty
        if !causes.contains(cause) { causes.append(cause) }
        if !wasEmpty { lock.unlock(); return false }
        state = CallHoldWire.stateHeld
        frameCause = cause
        let mySeq = nextSeqLocked()
        lock.unlock()
        onStateChange(true, cause, mySeq)
        start(mySeq)
        return true
    }

    /// Removes `cause`; when the set becomes empty the call is RESUMED (one state change). The first CALL_HOLD RESUMED is
    /// written before this returns, so the caller restarts audio only after it (16.3: RESUMED goes out before the first
    /// audio frame). Returns true when the state changed.
    @discardableResult
    public func removeCause(_ cause: UInt8) -> Bool {
        lock.lock()
        if closed { lock.unlock(); return false }
        guard let index = causes.firstIndex(of: cause) else { lock.unlock(); return false }
        causes.remove(at: index)
        if !causes.isEmpty { lock.unlock(); return false }
        state = CallHoldWire.stateResumed
        frameCause = cause
        let mySeq = nextSeqLocked()
        lock.unlock()
        onStateChange(false, cause, mySeq)
        if peerHasTag() {
            sendCurrent(mySeq, route: .first)
            start(mySeq, firstAlreadySent: true)
        } else {
            start(mySeq)
        }
        return true
    }

    /// A CALL_HOLD_ACK arrived. An ACK for a seq this side did not just send is ignored.
    @discardableResult
    public func onAck(_ ackSeq: UInt16) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if closed || !hasChange || ackSeq != seq || acked { return false }
        acked = true
        pendingTag = false
        cancelTimer?()
        cancelTimer = nil
        return true
    }

    /// An event after which an unacknowledged state is sent once more, on both legs (the leg changed, an ICE restart
    /// completed, a rekey completed, the signalling socket was re-authenticated, the outer layer left UNDECIDED), and the
    /// moment the peer tag may have become known.
    public func resendAfter(_ event: String) {
        lock.lock()
        if closed || acked || !hasChange { lock.unlock(); return }
        let mySeq = seq
        let restart = pendingTag
        lock.unlock()
        if restart {
            start(mySeq)
            return
        }
        guard peerHasTag() else {
            lock.lock()
            if seq == mySeq && !acked { pendingTag = true }
            lock.unlock()
            return
        }
        sendCurrent(mySeq, route: .both)
    }

    public func close() {
        lock.lock()
        closed = true
        cancelTimer?()
        cancelTimer = nil
        lock.unlock()
    }

    // MARK: Internals

    private func nextSeqLocked() -> UInt16 {
        seq = seq &+ 1
        hasChange = true
        acked = false
        pendingTag = false
        return seq
    }

    private func isCurrent(_ mySeq: UInt16) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed && seq == mySeq && !acked
    }

    private func start(_ mySeq: UInt16, firstAlreadySent: Bool = false) {
        lock.lock()
        cancelTimer?()
        cancelTimer = nil
        lock.unlock()
        if firstAlreadySent {
            // Send number 0 already went out (the RESUMED written before audio restarts): the next one is due after the
            // first gap.
            arm(after: Self.retryDelays[0]) { [weak self] in self?.step(mySeq, index: 1) }
        } else {
            step(mySeq, index: 0)
        }
    }

    /// Sends number `index` of the schedule now (when still due) and arms the next one.
    private func step(_ mySeq: UInt16, index: Int) {
        guard isCurrent(mySeq) else { return }
        guard peerHasTag() else {
            // Remembered, sent as soon as the tag is known; this class does not poll.
            lock.lock()
            if seq == mySeq && !acked { pendingTag = true }
            lock.unlock()
            return
        }
        sendCurrent(mySeq, route: index == 0 ? .first : .both)
        if index + 1 < Self.sendCount {
            arm(after: Self.retryDelays[index]) { [weak self] in self?.step(mySeq, index: index + 1) }
        } else {
            arm(after: Self.neverAckedGrace) { [weak self] in
                guard let self = self, self.isCurrent(mySeq) else { return }
                self.onNeverAcked(mySeq)
            }
        }
    }

    private func arm(after delay: TimeInterval, _ work: @escaping () -> Void) {
        let cancel = schedule(delay, work)
        lock.lock()
        cancelTimer = cancel
        lock.unlock()
    }

    private func sendCurrent(_ mySeq: UInt16, route: HoldRoute) {
        lock.lock()
        if closed || seq != mySeq || acked { lock.unlock(); return }
        let body = CallHoldWire.encodeHold(state: state, cause: frameCause, seq: seq)
        lock.unlock()
        _ = send(WireRelayFrameCodec.controlKindCallHold, body, route)
    }
}

// MARK: - Receiver

/// Receiver side of 16.4: seq de-duplication by serial arithmetic, the HELD state with its 30 minute expiry anchored to the
/// moment HELD was first applied, and the lost-RESUMED rule (3 consecutive seconds of real decoded audio, sealed-frame calls
/// only). The clock is passed in by the caller. Guarded by a lock.
public final class CallHoldReceiver: @unchecked Sendable {
    public static let expiryMs: Int64 = 30 * 60 * 1000
    public static let autoClearSeconds = 3
    /// A decode stamp older than this does not count as audio in the current second.
    public static let decodeFreshMs: Int64 = 1000

    /// `applied` false for an old or equal seq; `changed` true when `held` flipped.
    public struct Outcome: Equatable, Sendable {
        public let applied: Bool
        public let changed: Bool
    }

    private let lock = NSLock()
    private var haveLast = false
    private var lastSeq: UInt16 = 0
    private var _held = false
    private var _heldSinceMs: Int64 = 0
    private var _heldCause: UInt8 = CallHoldWire.causeUnspecified
    private var lastBucket: Int64 = -1
    private var streak = 0

    public init() {}

    public var held: Bool { lock.lock(); defer { lock.unlock() }; return _held }
    /// When the current HELD was first applied; meaningful while `held`.
    public var heldSinceMs: Int64 { lock.lock(); defer { lock.unlock() }; return _heldSinceMs }
    public var heldCause: UInt8 { lock.lock(); defer { lock.unlock() }; return _heldCause }

    /// Applies a valid CALL_HOLD. The caller always sends the ACK, whatever this returns.
    public func onFrame(_ hold: CallHoldWire.Hold, nowMs: Int64) -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        if haveLast && !CallHoldWire.isNewer(hold.seq, than: lastSeq) {
            return Outcome(applied: false, changed: false)
        }
        haveLast = true
        lastSeq = hold.seq
        if hold.held && !_held {
            _held = true
            _heldSinceMs = nowMs
            _heldCause = hold.cause
            lastBucket = -1
            streak = 0
            return Outcome(applied: true, changed: true)
        }
        if !hold.held && _held {
            _held = false
            return Outcome(applied: true, changed: true)
        }
        // Same state again (a repeated HELD, a RESUMED while not held): applied, nothing moves, the expiry is not extended.
        return Outcome(applied: true, changed: false)
    }

    /// A new call starts RESUMED with no seq seen.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        haveLast = false
        lastSeq = 0
        _held = false
        _heldSinceMs = 0
        _heldCause = CallHoldWire.causeUnspecified
        lastBucket = -1
        streak = 0
    }

    /// Drops HELD when the 30 minutes passed. Returns true when it did.
    public func expireIfDue(nowMs: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if !_held || nowMs - _heldSinceMs < Self.expiryMs { return false }
        _held = false
        return true
    }

    /// The lost-RESUMED rule: real decoded inbound audio (the decode stamp, never concealment, never transport bytes) seen
    /// in each of 3 consecutive seconds after HELD was applied clears HELD. `lastDecodeAtMs` is the stamp of the last real
    /// decode. Pass `sealedFrameCall` false on a native SRTP call: there only RESUMED or expiry ends HELD.
    public func observeDecode(nowMs: Int64, lastDecodeAtMs: Int64, sealedFrameCall: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if !_held || !sealedFrameCall { return false }
        if lastDecodeAtMs <= _heldSinceMs || nowMs - lastDecodeAtMs > Self.decodeFreshMs { return false }
        let bucket = (lastDecodeAtMs - _heldSinceMs) / 1000
        if bucket != lastBucket {
            streak = (lastBucket >= 0 && bucket == lastBucket + 1) ? streak + 1 : 1
            lastBucket = bucket
        }
        if streak < Self.autoClearSeconds { return false }
        _held = false
        return true
    }
}

// MARK: - Hint, silence gate

/// 16.6: more than `thresholdMs` without inbound audio evidence on a Connected call shows a neutral hint, removed on the
/// first real audio. Evidence is the real decode stamp (sealed-frame calls) or growth of the inbound RTP packet count
/// (native SRTP), never audio level. Not shown before the first inbound audio of the call, nor while suppressed (the peer
/// holds the call, the peer mute is known, media is held by the identity gate); a suppression restarts the count from
/// zero when it ends. Local only: it changes no timer and ends no call.
public final class PeerAudibleHint: @unchecked Sendable {
    public static let hintAfterMs: Int64 = 10_000

    private let lock = NSLock()
    private let thresholdMs: Int64
    private var everHeard = false
    private var lastEvidenceAtMs: Int64 = 0
    private var lastPackets: Int64 = -1
    private var _shown = false

    public init(thresholdMs: Int64 = PeerAudibleHint.hintAfterMs) {
        self.thresholdMs = thresholdMs
    }

    public var shown: Bool { lock.lock(); defer { lock.unlock() }; return _shown }

    public func onEvidence(nowMs: Int64) {
        lock.lock()
        defer { lock.unlock() }
        everHeard = true
        lastEvidenceAtMs = nowMs
        _shown = false
    }

    /// SRTP evidence: `packetsReceived` is the cumulative inbound-rtp audio count; growth is evidence.
    public func onPacketCount(nowMs: Int64, packetsReceived: Int64?) {
        guard let packets = packetsReceived, packets >= 0 else { return }
        lock.lock()
        let prev = lastPackets
        lastPackets = packets
        lock.unlock()
        if packets > 0 && (prev < 0 || packets > prev) { onEvidence(nowMs: nowMs) }
    }

    /// Returns whether the hint is shown now.
    @discardableResult
    public func evaluate(nowMs: Int64, suppressed: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if suppressed {
            if everHeard { lastEvidenceAtMs = nowMs }
            _shown = false
            return false
        }
        _shown = everHeard && nowMs - lastEvidenceAtMs > thresholdMs
        return _shown
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        everHeard = false
        lastEvidenceAtMs = 0
        lastPackets = -1
        _shown = false
    }
}

/// 16.4 item 3: a silence-based watchdog (no inbound audio for N seconds) does not count while the peer holds the call and
/// restarts from zero when the hold ends. `step` is asked once per poll: skip while held, restart once on the first poll
/// after a hold (build a fresh tracker), evaluate otherwise. Transport deadlines never ask this gate.
public final class HoldSilenceGate: @unchecked Sendable {
    public enum Step: Equatable, Sendable { case skip, restart, evaluate }

    private let lock = NSLock()
    private var restartPending = false

    public init() {}

    public func reset() {
        lock.lock()
        restartPending = false
        lock.unlock()
    }

    public func step(peerHeld: Bool) -> Step {
        lock.lock()
        defer { lock.unlock() }
        if peerHeld {
            restartPending = true
            return .skip
        }
        if restartPending {
            restartPending = false
            return .restart
        }
        return .evaluate
    }
}

// MARK: - Tone

/// The hold tone of 16.4 item 2: one beep of 350 ms at 425 Hz, about 24 dB below full scale, with 10 ms fades, at t=0 and
/// every 4 s while the peer holds the call. Local only: it is played through the call output and never goes over the
/// network or into the transmitted audio.
public enum HoldToneSynth {
    public static let frequencyHz: Double = 425.0
    public static let durationMs = 350
    public static let fadeMs = 10
    public static let levelDbfs: Double = -24.0
    public static let repeatMs: Int64 = 4000
    public static let never: Int64 = Int64.min

    /// 16-bit mono PCM of one beep.
    public static func samples(sampleRate: Int) -> [Int16] {
        let total = sampleRate * durationMs / 1000
        let fade = sampleRate * fadeMs / 1000
        let amp = pow(10.0, levelDbfs / 20.0) * Double(Int16.max)
        var out = [Int16](repeating: 0, count: total)
        for i in 0..<total {
            let env: Double
            if i < fade {
                env = Double(i) / Double(fade)
            } else if i >= total - fade {
                env = Double(total - 1 - i) / Double(fade)
            } else {
                env = 1.0
            }
            let v = amp * env * sin(2.0 * Double.pi * frequencyHz * Double(i) / Double(sampleRate))
            out[i] = Int16(v.rounded())
        }
        return out
    }

    /// One beep as a RIFF/WAVE file (PCM, 16 bit, mono), the form `AVAudioPlayer` takes from memory.
    public static func wavData(sampleRate: Int) -> Data {
        let pcm = samples(sampleRate: sampleRate)
        let dataBytes = pcm.count * 2
        var d = Data()
        func u32(_ v: UInt32) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]) }
        func u16(_ v: UInt16) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        for s in pcm { u16(UInt16(bitPattern: s)) }
        return d
    }

    /// When the next beep is due: the receiver beeps at t=0 of HELD and every `repeatMs` after, never while the local user
    /// also holds the call (16.5) and never when the peer does not hold it.
    public static func due(peerHeld: Bool, localHeld: Bool, nowMs: Int64, lastBeepAtMs: Int64) -> Bool {
        peerHeld && !localHeld && (lastBeepAtMs == never || nowMs - lastBeepAtMs >= repeatMs)
    }
}

// MARK: - iOS audio triggers

/// The audio-session triggers of cause `0x02` (WIRE_SPEC 16.3, iOS): an `AVAudioSession` interruption is pending between
/// `began` and `ended`; the system deactivating the session while this call owns it counts only once it stays deactivated
/// for a debounce interval (the owner re-activates within milliseconds in the transient cases: the release of the system
/// call UI after a push wake, a route change), and ends on the next activation with no interruption pending. A route change
/// by itself is never a trigger. The state says what to do with the cause set after each event; the call code runs the
/// debounce timer.
public struct AudioHoldTriggerState: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case none
        /// Add cause `0x02`.
        case add
        /// Remove cause `0x02`.
        case remove
        /// Start the debounce timer of a deactivation.
        case armTimer
        /// Stop the debounce timer (the session came back before it fired).
        case cancelTimer
    }

    /// How long a deactivation must last before it counts as a hold.
    public static let deactivationDebounceSeconds: TimeInterval = 1.5
    /// Cause `0x02` never outlives this: a lost `ended`, or a deactivation nobody undoes, cannot hold the call for ever.
    public static let maxHoldSeconds: TimeInterval = 30 * 60

    public private(set) var interruptionPending = false
    public private(set) var deactivationArmed = false
    public private(set) var deactivated = false
    private var applied = false

    public init() {}

    private var want: Bool { interruptionPending || deactivated }

    private mutating func sync() -> Action {
        if want && !applied { applied = true; return .add }
        if !want && applied { applied = false; return .remove }
        return .none
    }

    public mutating func interruptionBegan() -> Action {
        interruptionPending = true
        return sync()
    }

    public mutating func interruptionEnded() -> Action {
        interruptionPending = false
        return sync()
    }

    /// `didDeactivate` while this call is live and owns the session.
    public mutating func sessionDeactivated() -> Action {
        if deactivationArmed || deactivated { return .none }
        deactivationArmed = true
        return .armTimer
    }

    /// The debounce timer fired and the session is still deactivated.
    public mutating func deactivationTimerFired() -> Action {
        guard deactivationArmed else { return .none }
        deactivationArmed = false
        deactivated = true
        return sync()
    }

    /// `didActivate` (or the app's own activation): the session is back. An interruption that is still marked pending is
    /// over too (its `ended` was lost or never sent, e.g. after the app was suspended): the system activating the session
    /// again is the proof, so the flag is cleared and the cause ends.
    public mutating func sessionActivated() -> Action {
        let wasArmed = deactivationArmed
        deactivationArmed = false
        deactivated = false
        interruptionPending = false
        let result = sync()
        if result != .none { return result }
        return wasArmed ? .cancelTimer : .none
    }

    public mutating func reset() {
        self = AudioHoldTriggerState()
    }
}

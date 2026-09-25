import Foundation

/// W-DCWEDGE (2026-09-25) -- "the DataChannel is wedged": ICE is fine (or flaps
/// back to `connected` within a second), SCTP is not draining.
///
/// Evidence, both from the iPhone side:
///  - call 7727f262 (2026-09-23, iPhone on cellular): `DC backpressure: dropping
///    outbound audio frame` from 17:10:06.052 to 17:10:27.493 (`bufferedAmount`
///    1543-1818 B, threshold 1500). ICE went down at 17:10:11.239 (`dcmux txfall
///    why=icegate`, 16 frames on the WS relay) and was `connected` again at
///    17:10:12.153, but the send queue was still stuck: the per-frame ICE gate
///    (W-DCTXICEGATE) reopened the DataChannel at once ("no mode, no debounce")
///    and every frame until 17:10:27 was shed again. Final counter `dcmux tx
///    dc=5984 ws=16`: the 5984 includes every shed frame, see below.
///  - call 277cff7c (2026-09-24): backpressure 18:05:53.952-18:06:01.378 with the
///    queue fixed at 1802 B, and the iPhone never saw ICE change state (0 lines in
///    18 minutes), so nothing moved the audio to the relay (`ws=0` all call): 7.5 s
///    of silence iPhone -> Android.
/// `sendAudioFrameData` used to return `true` for a shed frame ("a transient,
/// self-recovering condition"), so `CallService` counted it as sent on the
/// DataChannel and never looked at the relay. ICE and SCTP are two different
/// failure domains; this type is the only place that watches the second one.
///
/// Rules, thresholds and sample semantics are those of the Android twin
/// (`DcWedgeDetector.kt`, W-DCWEDGE), which is the specification (CLAUDE.md,
/// audio-path rule 3); only the `why=` strings differ (see `Reason`) and
/// `shouldProbe` is iOS-only (a deliberate deviation from rule 3: Android has no
/// probe, and it has not been proven on a device yet; the kill switch turns it off,
/// as does `probeIntervalMs = 0`). Pure on purpose (no clock, no WebRTC types): the
/// caller feeds one sample per outbound frame with the time of its choice, so the
/// whole state machine runs on the CI simulator lane without the WebRTC binary
/// (`DcWedgeDetectorTests`).
///
/// ## Rules
///  - **Enter** (not wedged -> wedged), whichever comes first:
///    - `bufferedAmount` above `enterBufferedBytes` on EVERY sample for at least
///      `enterOverMs` (a single reading at or below the threshold restarts the
///      clock), or
///    - `enterConsecutiveDrops` consecutive frames shed by the back-pressure gate
///      (~0.9 s at the 60 ms frame cadence of both platforms: 83-88 frames per 5 s
///      heartbeat window in the 7727f262 / 277cff7c telemetry). A frame that got
///      through resets the count.
///  - **Exit** (wedged -> not wedged) only when BOTH hold at the same sample:
///    - `bufferedAmount` below `exitBufferedBytes` on every sample for at least
///      `exitLowMs` (measured from samples taken after the entry), and
///    - a frame was received on the DataChannel within the last `exitRxWindowMs`.
///    The thresholds are far apart on purpose (1500 in / 500 out, 1 s in / 3 s
///    out): that is the hysteresis. ICE flapping back to `connected` is NOT
///    evidence and is not an input at all -- that was the blind spot of 7727f262.
///  - **Unknown reading** (`bufferedAmountBytes < 0`) proves neither direction: it
///    restarts both clocks.
///  - **Continuity.** Both clocks and the drop count claim "every sample since
///    then", so a silence between two samples longer than `maxSampleGapMs` (mic
///    muted, no key while a re-key runs, ICE gate closed: no frame, no sample)
///    restarts them at the new sample.
///  - Time never goes backwards: a `nowMs` earlier than the previous one counts as
///    equal to it.
///
/// NOT thread-safe by itself (a value type): the owner (`QAudionPeerConnection`)
/// serialises access under one lock, because the send path samples it and the
/// receive path only leaves a flag.
public struct DcWedgeDetector: Equatable, Sendable {

    /// Why the state changed. The raw values are the `why=` token of the log line
    /// and stay under 12 characters: the live-log shipper's fail-closed redactor
    /// drops any unbroken run of 12+ `[A-Za-z0-9+/=_-]` characters from a line
    /// (Android's `buffered-over-1s` / `consecutive-drops` would not survive it).
    public enum Reason: String, Equatable, Sendable {
        /// Entry: the queue stayed over the threshold for `enterOverMs`.
        case buffered = "buf"
        /// Entry: `enterConsecutiveDrops` shed frames in a row.
        case drops = "drops"
        /// Exit: the queue drained and the peer's frames arrive on the channel.
        case drained = "drained"
    }

    /// One state change, for the caller's log. The numbers are the ones that
    /// decided it; none of them identifies a call, a peer or a key.
    ///  - `wedged`: the NEW state.
    ///  - `bufferedBytes`: the reading of the sample that caused it (-1 if unknown).
    ///  - `holdMs`: entry: how long the queue had been over the threshold; exit: how
    ///    long it had been under the exit threshold.
    ///  - `consecutiveDrops`: shed frames in a row at that sample (0 on exit).
    ///  - `rxAgoMs`: exit only, time since the last frame received on the
    ///    DataChannel (-1 on entry).
    ///  - `wedgedForMs`: exit only, how long the channel had been wedged.
    public struct Transition: Equatable, Sendable {
        public let wedged: Bool
        public let reason: Reason
        public let bufferedBytes: Int64
        public let holdMs: Int64
        public let consecutiveDrops: Int
        public let rxAgoMs: Int64
        public let wedgedForMs: Int64

        /// The line the app layer ships (`RTLog.info("call", ...)` via the
        /// controller's `log`). Terse on purpose: EVERY whitespace-separated token
        /// stays under 12 characters (`key=value` counts as one token), otherwise the
        /// shipper's redactor deletes the whole line -- pinned by
        /// `DcWedgeDetectorTests`. `wsec` is seconds, and each value is clamped to the
        /// digits its key leaves (11 characters per token) on BOTH sides, a minus sign
        /// included, so the limit holds for ANY input, not just for the values a real
        /// call produces.
        public var logLine: String {
            let cap5: Int64 = 99_999
            let cap6: Int64 = 999_999
            let cap7: Int64 = 9_999_999
            // Above `cap`, and below `-(cap / 10)`: the minus sign takes one of the digits.
            func clamp(_ v: Int64, _ cap: Int64) -> Int64 { max(min(v, cap), -(cap / 10)) }
            let buf: Int64 = clamp(bufferedBytes, cap7)
            let parts: [String]
            if wedged {
                let over: Int64 = clamp(holdMs, cap6)
                let drops: Int64 = clamp(Int64(consecutiveDrops), cap5)
                parts = ["dcmux", "wedge=1", "why=\(reason.rawValue)", "buf=\(buf)",
                         "over=\(over)", "drops=\(drops)"]
            } else {
                let low: Int64 = clamp(holdMs, cap7)
                let rxAgo: Int64 = clamp(rxAgoMs, cap5)
                let wsec: Int64 = clamp(wedgedForMs / 1_000, cap6)
                parts = ["dcmux", "wedge=0", "why=\(reason.rawValue)", "buf=\(buf)",
                         "low=\(low)", "rxago=\(rxAgo)", "wsec=\(wsec)"]
            }
            return parts.joined(separator: " ")
        }
    }

    /// Same value as `QAudionPeerConnection.audioDcBufferedAmountDropThreshold`
    /// (~12 sealed frames): "over" here is exactly "the shed gate is closing".
    /// Keep them equal (`AudioDcBackpressureGateTests` pins the gate's side).
    public static let enterBufferedBytes: Int64 = 1500
    /// How long the queue must stay over `enterBufferedBytes` before the channel is called wedged.
    public static let enterOverMs: Int64 = 1_000
    /// ~0.9 s of shed frames at 60 ms per frame.
    public static let enterConsecutiveDrops: Int = 15
    /// The queue must be well under the entry threshold to leave: hysteresis, not a mirror.
    public static let exitBufferedBytes: Int64 = 500
    /// ...and stay there this long.
    public static let exitLowMs: Int64 = 3_000
    /// ...while the peer's frames are still reaching us on the DataChannel.
    public static let exitRxWindowMs: Int64 = 500
    /// Frames leave every ~60 ms; a silence this long between two samples breaks "continuous".
    public static let maxSampleGapMs: Int64 = 1_000
    /// While wedged and the queue is drained (under `exitBufferedBytes`), one frame per
    /// this many ms still goes on the DataChannel instead of the relay -- see `shouldProbe`.
    /// 0 turns the probe off.
    public static let probeIntervalMs: Int64 = 400

    /// Read on every outbound frame (through the owner's lock).
    public private(set) var wedged: Bool = false

    private var lastNowMs: Int64?
    private var consecutiveDrops: Int = 0
    private var overSinceMs: Int64?
    private var lowSinceMs: Int64?
    private var lastRxAtMs: Int64?
    private var wedgedSinceMs: Int64?
    private var lastBufferedBytes: Int64 = -1
    private var lastProbeAtMs: Int64?

    public init() {}

    /// Feed one sample; returns the transition it caused, or `nil` when the state
    /// did not change.
    ///  - `nowMs`: a monotonic clock in milliseconds (only differences are used).
    ///  - `bufferedAmountBytes`: the DataChannel's send-queue size now, or a negative
    ///    value when it is not known.
    ///  - `dropped`: this frame was shed by the back-pressure gate.
    ///  - `rxOnDcSeen`: at least one frame arrived on the DataChannel since the
    ///    previous sample.
    public mutating func onSample(nowMs: Int64,
                                  bufferedAmountBytes: Int64,
                                  dropped: Bool,
                                  rxOnDcSeen: Bool) -> Transition? {
        var now: Int64 = nowMs
        if let last = lastNowMs, now < last { now = last }
        if let last = lastNowMs, now - last > DcWedgeDetector.maxSampleGapMs {
            overSinceMs = nil
            lowSinceMs = nil
            consecutiveDrops = 0
        }
        lastNowMs = now
        if rxOnDcSeen { lastRxAtMs = now }

        let known: Bool = bufferedAmountBytes >= 0
        lastBufferedBytes = bufferedAmountBytes
        consecutiveDrops = dropped ? min(consecutiveDrops + 1, Int.max - 1) : 0
        if known && bufferedAmountBytes > DcWedgeDetector.enterBufferedBytes {
            if overSinceMs == nil { overSinceMs = now }
        } else {
            overSinceMs = nil
        }
        if known && !dropped && bufferedAmountBytes < DcWedgeDetector.exitBufferedBytes {
            if lowSinceMs == nil { lowSinceMs = now }
        } else {
            lowSinceMs = nil
        }

        if !wedged {
            var overMs: Int64 = 0
            if let since = overSinceMs { overMs = now - since }
            let reason: Reason
            if consecutiveDrops >= DcWedgeDetector.enterConsecutiveDrops {
                reason = .drops
            } else if overMs >= DcWedgeDetector.enterOverMs {
                reason = .buffered
            } else {
                return nil
            }
            wedged = true
            wedgedSinceMs = now
            // The exit clock starts from samples taken AFTER this one, whatever the
            // reading said (a shed frame next to a low reading is a race, not a recovery).
            lowSinceMs = nil
            lastProbeAtMs = nil
            return Transition(wedged: true, reason: reason, bufferedBytes: bufferedAmountBytes,
                              holdMs: overMs, consecutiveDrops: consecutiveDrops,
                              rxAgoMs: -1, wedgedForMs: 0)
        }

        var lowMs: Int64 = 0
        if let since = lowSinceMs { lowMs = now - since }
        if lowMs >= DcWedgeDetector.exitLowMs, let rxAt = lastRxAtMs {
            let rxAgoMs: Int64 = now - rxAt
            if rxAgoMs <= DcWedgeDetector.exitRxWindowMs {
                var wedgedForMs: Int64 = 0
                if let since = wedgedSinceMs { wedgedForMs = now - since }
                wedged = false
                consecutiveDrops = 0
                overSinceMs = nil
                wedgedSinceMs = nil
                lastProbeAtMs = nil
                return Transition(wedged: false, reason: .drained, bufferedBytes: bufferedAmountBytes,
                                  holdMs: lowMs, consecutiveDrops: 0,
                                  rxAgoMs: rxAgoMs, wedgedForMs: wedgedForMs)
            }
        }
        return nil
    }

    /// Back to "healthy, nothing seen" (a new call must not inherit the last one's evidence).
    public mutating func reset() {
        wedged = false
        lastNowMs = nil
        consecutiveDrops = 0
        overSinceMs = nil
        lowSinceMs = nil
        lastRxAtMs = nil
        wedgedSinceMs = nil
        lastBufferedBytes = -1
        lastProbeAtMs = nil
    }

    /// While wedged, should THIS frame still go on the DataChannel (as a probe) instead
    /// of the relay? Ask right after `onSample` with the same `nowMs`.
    ///
    /// Why it exists. The exit rule needs a frame RECEIVED on the DataChannel, and the
    /// peer only sends on it while ITS side is not wedged. A physical hole hits both
    /// directions, so in the common case both phones wedge, both divert to the relay,
    /// and after the path is back nobody writes on the DataChannel: neither side can
    /// ever see the frame the other one needs, and the call stays on the relay to the
    /// end. One frame per `probeIntervalMs` on the channel is enough to break that
    /// (the peer's receive flag lights up, it releases, it writes back, we release).
    /// The frame is DIVERTED, never duplicated: it goes on the DataChannel INSTEAD of
    /// the relay, so the receiver's anti-replay window never sees a copy.
    ///
    /// True only while wedged, only when the queue is drained (last reading under
    /// `exitBufferedBytes`, i.e. SCTP is emptying it again), at most once per
    /// `probeIntervalMs`. Consumes the slot when it answers true.
    public mutating func shouldProbe(nowMs: Int64) -> Bool {
        guard wedged, DcWedgeDetector.probeIntervalMs > 0 else { return false }
        guard lastBufferedBytes >= 0, lastBufferedBytes < DcWedgeDetector.exitBufferedBytes else { return false }
        if let last = lastProbeAtMs, nowMs - last < DcWedgeDetector.probeIntervalMs { return false }
        lastProbeAtMs = nowMs
        return true
    }
}

/// W-DCWEDGE -- what became of ONE frame offered to the sealed-audio DataChannel.
///
/// Before this, `sendAudioFrameData` answered a `Bool` and `true` covered two very
/// different things (queued on SCTP, or dropped by the back-pressure gate), so the
/// caller counted shed frames as sent (`dcmux tx dc=5984` in 7727f262) and could not
/// tell a stuck channel from a healthy one. Sendable and payload-free: it crosses the
/// engine/app boundary once per frame.
public enum AudioDcSendOutcome: Equatable, Sendable {
    /// Handed to SCTP.
    case queued
    /// Dropped by the back-pressure gate (transient, the channel is still considered
    /// healthy): NOT sent anywhere, must not be counted as sent, must not go to the relay.
    case shed
    /// The DataChannel cannot carry this frame (not open, ICE not carrying, send
    /// refused, or wedged): the caller puts it on the WS relay.
    case useRelay

    /// `true` when the caller must send the AUDIO frame on the WS relay (a shed audio frame
    /// is dropped: it is not late audio worth a second leg).
    public var needsRelay: Bool { self == .useRelay }

    /// `true` when a CONTROL frame (hangup, NACK request / resend) must go on the WS relay.
    /// A control frame is not audio: one the back-pressure gate SHED was written on no leg
    /// at all (it used to be counted as sent, and lost -- 117 NACK requests in 7727f262), so
    /// with the switch on it goes on the relay like one the channel refused. With the switch
    /// OFF a shed control frame is dropped exactly as before the change.
    public func controlFrameNeedsRelay(divertEnabled: Bool) -> Bool {
        switch self {
        case .queued: return false
        case .useRelay: return true
        case .shed: return divertEnabled
        }
    }

    /// The decision that comes AFTER "the channel exists and is open" and BEFORE the
    /// actual `sendData`, as a pure function. `nil` = go ahead and send.
    ///  - wedged and the switch on: relay, except the one probe frame per interval;
    ///  - otherwise a frame over the back-pressure threshold is shed (the pre-W-DCWEDGE
    ///    behaviour, byte for byte, which is also what `divertEnabled == false` restores).
    public static func preSend(shedByBackpressure: Bool,
                               wedged: Bool,
                               probe: Bool,
                               divertEnabled: Bool) -> AudioDcSendOutcome? {
        if wedged && divertEnabled && !probe { return .useRelay }
        if shedByBackpressure { return .shed }
        return nil
    }
}

/// W-DCWEDGE -- process-wide kill switch for the wedge diversion. The compiled
/// default is ON. The app layer refreshes it from the remote flag
/// `ios_dc_wedge_fallback` (`FeatureFlags`, `CallService.refreshDcWedgeFlag`) once per
/// call; the engine cannot read `FeatureFlags` itself (app target, main actor) and
/// the send path runs off the main thread, hence a lock-guarded value here.
///
/// OFF restores the pre-W-DCWEDGE routing exactly (`AudioDcSendOutcome.preSend` for audio,
/// `controlFrameNeedsRelay` for hangup / NACK): the detector still runs and logs, but
/// no frame is diverted and a shed control frame is dropped as it always was. Only the
/// counters differ (a shed frame is no longer counted as sent). Rollback without a
/// build: set `ios_dc_wedge_fallback` to `false` in flags.json.
public final class DcWedgeKillSwitch: @unchecked Sendable {
    public static let shared = DcWedgeKillSwitch()

    private let lock = NSLock()
    private var enabled: Bool = true

    public init() {}

    public var divertEnabled: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return enabled
        }
        set {
            lock.lock(); defer { lock.unlock() }
            enabled = newValue
        }
    }
}

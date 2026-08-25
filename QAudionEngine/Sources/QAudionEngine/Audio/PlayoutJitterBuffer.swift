import Foundation

/// W-IOSJITTER (2026-07-25) — the playout jitter buffer iOS did not have.
///
/// ## What was there before
///
/// `AudioPlayback.playFrame` handed every received frame straight to
/// `AVAudioPlayerNode.scheduleBuffer`. That is not a buffer: frames arriving
/// faster than realtime pile onto the player node and the latency grows without
/// bound, frames arriving slower leave the node with nothing to play, and
/// because there is no concealment the resulting hole is silence rather than a
/// masked gap. The existing `JitterBuffer.swift` in this package is reachable
/// only from `QAudionAudioProcessor`, which the live 1:1 call path never
/// constructs — so the sealed-audio path ran with no buffering at all.
///
/// Android has had a real one for months, with the drift catch-up and PLC that
/// only get written after someone hears the artefact. Its telemetry is why we
/// know: on call 807ae1d5 the Android leg reported 489 underruns, 3908
/// synthesised PLC frames and a measured 47.6 Hz arrival against a 50 Hz
/// consumer. iOS reported nothing on the same call, not because it was healthy
/// but because nothing was counting.
///
/// ## Why the constants are a port
///
/// Every threshold below is Android's, verbatim, for the same reason the
/// make-up AGC constants were: each one exists because of a measured artefact.
/// The emergency drain is budgeted at 3 frames per tick because draining 13 at
/// once removes 260 ms — a disappeared word — while 60 ms is something the ear
/// integrates. The `draining` latch is not polish: without it a budgeted drain
/// gates on `depth >= watermark`, switches itself off the moment depth falls
/// under it, never reaches the target, and converts a transient spike into
/// permanent standing latency (measured on Android: settles at 14 frames, 280
/// ms, forever). Re-deriving these on iOS would mean re-earning them.
///
/// ## Thread safety
///
/// Producer (network decode) and consumer (audio render) are different threads,
/// so the queue is lock-protected. The counters are read at teardown from a
/// third thread; they are plain values behind the same lock.
///
/// ## W-JBADAPT + W-JBSTRETCH port (2026-08-25, parity plan Fase C3)
///
/// Two more pieces ported from Android's `JitterBuffer.kt`, both landing the
/// same day on the far side:
///
///  - **W-JBADAPT** — the steady-state target (`nominal`, and the tier-3
///    drain target derived from it) is no longer the fixed 80/40 ms Android
///    also used to ship. It now tracks the buffer's own observed
///    inter-arrival lateness (p95 over a rolling window, plus one frame of
///    headroom), clamped to the envelope the fixed constants already
///    defined. A clean link converges to less standing latency than the old
///    constant bought; a jittery one gets more depth than the constant
///    would have given it, instead of starving under it. See
///    `recordArrival`/`computeTargetMs`.
///  - **W-JBSTRETCH** — the correction this class had for excess depth used
///    to be binary: delivered unmodified, or excised whole (energy-gated
///    where possible, budgeted and latched in the emergency case). Every
///    excision is a discontinuity, audible as a pop/skip even when
///    energy-gated timing hid it most of the time. `TimeStretch.compress`
///    (a fixed-splice, linear-crossfade intra-frame time compression —
///    "SOLA-lite", see that file's own kdoc for why intra-frame rather than
///    a cross-frame WSOLA search) gives the moderate-excess band a cheaper
///    first option: shave a few ms off the head-of-queue frame instead of
///    discarding it. See `tryTimeStretch` and `timeStretchWatermark`.
///
/// Both are byte-for-byte ports of the Android twins in
/// `com.bcrypto.qaudion.audio.JitterBuffer` / `TimeStretch` — same
/// constants, same band boundaries, same splice math — adapted only for
/// this class's single-lock threading model (Android's queue is lock-free
/// with atomics; this class already serialises push and pop under one
/// `NSLock`, so there is no analogous "which fields are single-thread-only"
/// bookkeeping to carry over).
public final class PlayoutJitterBuffer: @unchecked Sendable {

    // MARK: - Tuning, ported from Android's JitterBuffer
    //
    // W-LONGAUDIO (2026-08-10) — every threshold here was chosen as a DURATION
    // and written down as a frame count, because there was only ever one frame
    // duration. Each is now stated in milliseconds and converted at runtime.
    //
    // The `static` members below keep their original names and values so that
    // nothing referring to them has to move; each is now DERIVED from its
    // millisecond intent at 20 ms, which is how the two are kept from drifting.
    // The instance members further down are the ones the tiers actually read,
    // and they follow the INBOUND frame duration.
    //
    // Conversion is round-to-nearest, and that matters: `trimWatermarkMs` (140)
    // and `highWatermarkMs` (160) both TRUNCATE to 2 frames at 60 ms, which
    // silently merges two tiers into one. Rounding keeps them 2 and 3.

    /// Hard cap: 600 ms. Above this, `push` drops the OLDEST frame (an overrun)
    /// so the queue cannot become an unbounded latency sink.
    public static let capacityMs = 600
    /// At or below this depth the buffer just delivers: no catch-up tier fires.
    /// 80 ms, enough to absorb a spike without underrunning.
    static let nominalWatermarkMs = 80
    /// The depth below which the catch-up tier does not arm at all: 140 ms.
    static let trimWatermarkMs = 140
    /// Tier 2 entry: 160 ms.
    static let highWatermarkMs = 160
    /// Tier 3 entry: 300 ms.
    static let emergencyWatermarkMs = 300
    /// Where tier 3 stops: 40 ms.
    static let emergencyDrainTargetMs = 40
    /// The bound that makes tier 3 acceptable: it may never delete more than
    /// 60 ms of contiguous audio in one tick.
    static let emergencyMaxDropsPerPopMs = 60
    /// Tier 1 scan window: 60 ms.
    static let silenceScanLimitMs = 60
    /// Tier 2 scan window: 160 ms.
    static let highTierScanLimitMs = 160
    /// Tier 2 drop budget: 60 ms.
    static let highTierDropBudgetMs = 60

    /// 30 frames at 20 ms — unchanged.
    public static let capacityFrames = AudioConstants.framesForMs(capacityMs, frameDurationMs: 20)

    /// 4 frames at 20 ms — unchanged.
    static let nominalWatermark = AudioConstants.framesForMs(nominalWatermarkMs, frameDurationMs: 20)

    /// W-TRIMFLOOR (2026-07-26) — the depth below which the catch-up tier does not
    /// arm AT ALL, distinct from `nominalWatermark`, which is the depth it must
    /// never leave the queue under.
    ///
    /// Those two were the same number, and that was the bug. A firing removes two
    /// frames — it discards the silent head, then polls again to deliver — so
    /// entering at nominal+1 handed back nominal-1. The buffer starved, concealed,
    /// refilled to nominal+1 and trimmed again: a treadmill it powered itself.
    /// Measured on Android, which is where this file was ported from and which
    /// therefore carried the identical defect: 515 and 96 silence drops against 38
    /// and 42 stalls, on links with 2.0% and 0% real loss.
    ///
    /// 7 is nominal + one firing + one frame of margin. Trimming a 5-frame queue
    /// buys 20 ms of latency and costs a concealment later; that is not a trade
    /// worth making.
    static let trimWatermark = AudioConstants.framesForMs(trimWatermarkMs, frameDurationMs: 20)

    /// Tier 2. Above this the buffer may discard SILENT frames to work down a
    /// backlog, scanning further and dropping more per tick than tier 1.
    static let highWatermark = AudioConstants.framesForMs(highWatermarkMs, frameDurationMs: 20)

    /// Tier 3. Above this the backlog is too large to walk down by skipping
    /// silence, so contiguous frames are discarded — budgeted, and latched.
    static let emergencyWatermark = AudioConstants.framesForMs(emergencyWatermarkMs, frameDurationMs: 20)

    /// Where tier 3 stops. Deliberately low: the tier must actually reach it,
    /// or the drain leaves standing latency behind (see the class notes).
    static let emergencyDrainTarget = AudioConstants.framesForMs(emergencyDrainTargetMs, frameDurationMs: 20)

    /// The bound that makes tier 3 acceptable. Three frames is 60 ms.
    static let emergencyMaxDropsPerPop = AudioConstants.framesForMs(emergencyMaxDropsPerPopMs, frameDurationMs: 20)

    /// Tier 1/2 scan limits and drop budgets.
    static let silenceScanLimit = AudioConstants.framesForMs(silenceScanLimitMs, frameDurationMs: 20)
    static let highTierScanLimit = AudioConstants.framesForMs(highTierScanLimitMs, frameDurationMs: 20)
    static let highTierDropBudget = AudioConstants.framesForMs(highTierDropBudgetMs, frameDurationMs: 20)

    /// A frame whose RMS is under this is inaudible, so discarding it to work
    /// down a backlog costs nothing. 16-bit scale.
    ///
    /// W-LONGAUDIO — this number is NOT retuned for longer frames. It is a
    /// calibrated audibility threshold at a 20 ms detection resolution, and
    /// re-deriving it would trade a measured value for an unmeasured one.
    /// Instead `isSilent` evaluates 20 ms SUB-BLOCKS and requires all of them to
    /// be silent (see there).
    static let silenceRmsThreshold: Double = 500

    /// The sub-block over which silence is judged, in ms. Frames longer than
    /// this are split; a frame is only excisable when EVERY sub-block is silent.
    static let silenceSubBlockMs = 20

    // MARK: - W-JBADAPT (2026-08-25) — adaptive steady-state target
    //
    // Ported from Android's `JitterBuffer.kt` companion object (`ADAPT_*`).
    // See `recordArrival`/`computeTargetMs` for where these are used.

    /// Target before enough arrivals have been observed — the shipped
    /// nominal watermark (80 ms), so a fresh buffer is behaviourally
    /// identical to the fixed-constant one it replaces.
    static let adaptDefaultTargetMs = 80
    /// Clamp floor = the shipped emergency-drain target (40 ms): the lowest
    /// depth this class has ever deliberately drained to.
    static let adaptTargetMinMs = 40
    /// Clamp ceiling = the shipped high watermark (160 ms). A link worse
    /// than this needs the emergency tier, not more standing depth.
    static let adaptTargetMaxMs = 160
    /// How far below the target the tier-3 drain stops, preserving the
    /// shipped 80→40 relationship at the default.
    static let adaptDrainUndershootMs = 40
    /// Lateness samples kept: ~5 s of audio at 20 ms cadence.
    static let adaptWindow = 256
    /// Arrivals required before the first adaptation — a p95 over a
    /// handful of samples is noise.
    static let adaptMinSamples = 64
    /// Republish cadence: the sort in `computeTargetMs` is trivial, but
    /// there is no reason to pay it on every push for a target that moves
    /// on the scale of seconds.
    static let adaptRecomputeEvery = 16

    // MARK: - W-JBSTRETCH (2026-08-25) — time-stretch correction band
    //
    // Ported from Android's `JitterBuffer.kt` (`TIME_STRETCH_*`) and
    // `TimeStretch.kt`. See `tryTimeStretch` and `TimeStretch.compress`.

    /// Samples removed per `TimeStretch.compress` pass. A FIXED ms amount —
    /// not scaled by frame duration — so the same absolute shave applies at
    /// 20 ms and at 60 ms alike. See `TimeStretch.kt`'s Android twin for why
    /// 3 ms specifically (inside the 2-5 ms band this correction must stay
    /// within).
    static let timeStretchShaveMs = 3
    /// `timeStretchShaveMs` resolved to samples at `AudioConstants.sampleRate`.
    static let timeStretchShaveSamples = AudioConstants.sampleRate / 1000 * timeStretchShaveMs
    /// Ceiling, in ms, of the band where time-stretch is tried BEFORE the
    /// existing whole-frame drop machinery. Deliberately its own constant
    /// rather than a reuse of `trimWatermarkMs`(140)/`highWatermarkMs`(160):
    /// those two round to ADJACENT frame counts at every cadence this class
    /// supports, so reusing either would leave the "try compression first"
    /// band empty. 200 ms sits at roughly the midpoint of the escalation
    /// ladder's non-emergency span (140 ms trim floor to 300 ms emergency
    /// watermark).
    static let timeStretchCeilingMs = 200

    // MARK: - State

    private let lock = NSLock()
    private var queue: [Data] = []
    private var emergencyDraining = false

    // MARK: - Runtime geometry (W-LONGAUDIO)
    //
    // The tiers read THESE, not the statics above. They follow the INBOUND
    // frame duration, which is observed from arriving frames rather than taken
    // from the negotiated profile — a receiver holds no negotiation state, and
    // receive is unconditional for every endpoint from R0 onward.

    /// Frame duration currently assumed for the queued frames, in ms.
    private var frameMs: Int = AudioConstants.frameDurationMs
    private var capFrames: Int = PlayoutJitterBuffer.capacityFrames
    private var nominal: Int = PlayoutJitterBuffer.nominalWatermark
    private var trim: Int = PlayoutJitterBuffer.trimWatermark
    private var high: Int = PlayoutJitterBuffer.highWatermark
    private var emergency: Int = PlayoutJitterBuffer.emergencyWatermark
    private var drainTarget: Int = PlayoutJitterBuffer.emergencyDrainTarget
    private var maxDropsPerPop: Int = PlayoutJitterBuffer.emergencyMaxDropsPerPop
    private var silenceScan: Int = PlayoutJitterBuffer.silenceScanLimit
    private var highScan: Int = PlayoutJitterBuffer.highTierScanLimit
    private var highDropBudget: Int = PlayoutJitterBuffer.highTierDropBudget

    /// W-JBSTRETCH — the ceiling of the "try time-compression first" band,
    /// in frames at the CURRENT cadence. See `timeStretchCeilingMs`'s kdoc.
    private var timeStretchWatermark: Int = PlayoutJitterBuffer.nominalWatermark

    // MARK: - W-JBADAPT (2026-08-25): inter-arrival tracker
    //
    // Honesty note ported from Android's own: before this, the buffer
    // collected NO arrival-timing statistics at all. The tracker below is
    // the collection AND the consumer, in one place, because the buffer's
    // own arrival cadence is the quantity that decides the right
    // steady-state depth and nothing upstream sees it earlier.
    //
    // Threading: unlike Android's lock-free queue (where this ring is
    // documented single-thread — pushing side only), every field here sits
    // behind this class's one `lock`, which already serialises push and
    // pop, so there is nothing further to reason about.

    /// Monotonic clock, injectable so the adaptive-target tests can drive
    /// time deterministically instead of sleeping. Production default is
    /// `ProcessInfo.processInfo.systemUptime` — never wall-clock, which
    /// jumps on NTP/timezone changes.
    private let nowSeconds: () -> Double

    /// Timestamp of the previous `push`, in `nowSeconds` units, or `nil`
    /// before the first arrival / since the last `reset()`.
    private var lastPushMonotonic: Double?

    /// Ring of recent per-arrival LATENESS values, in ms: how much later
    /// than the nominal cadence each frame arrived, floored at 0. Lateness
    /// rather than raw gap, because depth only has to cover frames that
    /// arrive LATE — an early (bunched) arrival costs no depth.
    private var latenessRing: [Int]

    /// Number of arrivals recorded since construction / the last `reset()`.
    /// Can exceed `latenessRing.count`; the ring wraps.
    private var latenessCount: Int = 0

    /// The adaptive steady-state target, in ms. Seeded at the shipped
    /// constant and republished every `adaptRecomputeEvery` arrivals once
    /// the window has `adaptMinSamples` observations.
    private var adaptTargetMs: Int = PlayoutJitterBuffer.adaptDefaultTargetMs

    // MARK: - W-JBSTRETCH (2026-08-25): time-stretch correction

    /// Reusable output buffer for `tryTimeStretch`. A compressed frame is a
    /// different LENGTH than the polled frame, so it cannot be produced in
    /// place; resized only when the needed size actually changes (i.e. on a
    /// cadence change), the same amortised cost every other duration-derived
    /// quantity in this class already pays.
    private var stretchScratch = Data()

    /// Re-derive every watermark for a new inbound frame duration.
    ///
    /// Idempotent and cheap; call it whenever the observed inbound duration
    /// changes. It does NOT flush the queue: a duration change mid-stream is a
    /// legitimate thing to receive (truth-table row 8 leaves the two directions
    /// independently latched), and throwing away buffered audio to react to it
    /// would be a worse artefact than the momentarily-mismatched watermark it
    /// avoids.
    public func setInboundFrameDurationMs(_ ms: Int) {
        guard ms > 0, ms <= AudioConstants.maxFrameDurationMs else { return }
        lock.lock(); defer { lock.unlock() }
        guard ms != frameMs else { return }
        frameMs = ms
        recomputeTierGeometry()
    }

    /// Re-derive every watermark from the current `frameMs` AND the current
    /// `adaptTargetMs`. Called whenever either changes: from
    /// `setInboundFrameDurationMs` (cadence change) and from `recordArrival`
    /// (the adaptive target moved). Callers must already hold `lock`.
    private func recomputeTierGeometry() {
        let ms = frameMs
        // 2026-08-11 — the conversion follows the constant's ROLE, because
        // rounding to nearest is right for a boundary and wrong for a ceiling.
        // A budget that says "never excise more than 60 ms" rounded UP to
        // 2 frames at 40 ms authorises excising 80 ms; truncation cannot, and
        // at 20 ms the two agree exactly, so nothing already in the field moves.
        // Capacity is a ceiling too — it is what `push` enforces by dropping the
        // oldest frame, and a queue that may hold MORE than its stated ms is a
        // latency sink by the same argument.
        capFrames = AudioConstants.boundedFramesForMs(Self.capacityMs, frameDurationMs: ms)
        // The ladder is forced monotonic AFTER conversion, because quantisation
        // can tie two boundaries that are distinct in milliseconds and a tied
        // boundary is a tier with an empty band — it can never fire, and nothing
        // fails to say so.
        //
        // 2026-08-11: at 40 ms `trimWatermarkMs` (140) and `highWatermarkMs`
        // (160) BOTH resolve to 4, which is verbatim the collision the rounding
        // rule was chosen to prevent — it prevents it at 60 ms and not at 40,
        // and 40 ms is reachable on this receiver without any new profile. No
        // millisecond value could fix that without moving the 20 ms numbers
        // that are already in the field, so the structural property is enforced
        // structurally instead: each rung is at least one frame above the one
        // below it. At 20 ms every `max` below picks the converted value
        // unchanged, so this is inert on the shipping cadence.
        //
        // W-JBADAPT (2026-08-25) — `nominal` is now the ADAPTIVE target
        // (`adaptTargetMs`), not the fixed `nominalWatermarkMs` constant.
        // The monotonic chain below is an iOS-specific safety net Android
        // does not carry (Android accepts the adaptive target transiently
        // outranking the fixed `trimWatermarkMs` at its 160 ms clamp
        // ceiling, and documents the consequence: the energy-gated tiers
        // simply stop firing on a link jittery enough to need it). This
        // class instead keeps trim/high/emergency forced strictly above
        // whatever nominal resolves to, for the same reason it already
        // forces them above each other: it was built to survive many more
        // reachable frame durations (5/10/20/40/60 ms, see
        // `FrameQuantisationInvariantsTests`) than Android's two, and a
        // silently-empty tier band is exactly the class of bug that net
        // already exists to catch.
        nominal = AudioConstants.framesForMs(adaptTargetMs, frameDurationMs: ms)
        trim = max(nominal + 1, AudioConstants.framesForMs(Self.trimWatermarkMs, frameDurationMs: ms))
        high = max(trim + 1, AudioConstants.framesForMs(Self.highWatermarkMs, frameDurationMs: ms))
        emergency = max(high + 1, AudioConstants.framesForMs(Self.emergencyWatermarkMs, frameDurationMs: ms))
        capFrames = max(emergency + 1, capFrames)
        // W-JBSTRETCH — the "try compression first" ceiling. Same monotonic
        // safety net as above: must sit strictly above `trim`, or the band
        // it defines is empty.
        timeStretchWatermark = max(trim + 1, AudioConstants.framesForMs(Self.timeStretchCeilingMs, frameDurationMs: ms))
        // W-JBADAPT — the tier-3 drain target tracks the adaptive target at
        // the same 40 ms undershoot the shipped constants had (80→40), floored
        // at the clamp floor so the drain never targets less than it ever did.
        let undershootTargetMs = max(adaptTargetMs - Self.adaptDrainUndershootMs, Self.adaptTargetMinMs)
        drainTarget = AudioConstants.framesForMs(undershootTargetMs, frameDurationMs: ms)
        maxDropsPerPop = AudioConstants.boundedFramesForMs(Self.emergencyMaxDropsPerPopMs, frameDurationMs: ms)
        silenceScan = AudioConstants.boundedFramesForMs(Self.silenceScanLimitMs, frameDurationMs: ms)
        highScan = AudioConstants.boundedFramesForMs(Self.highTierScanLimitMs, frameDurationMs: ms)
        highDropBudget = AudioConstants.boundedFramesForMs(Self.highTierDropBudgetMs, frameDurationMs: ms)
    }

    /// Record one arrival and, periodically, republish the adaptive target.
    /// Ported from Android's `JitterBuffer.recordArrival` (W-JBADAPT).
    /// Caller (`push`) already holds `lock`.
    ///
    /// Target rule: p95 of the recent lateness window, plus one frame of
    /// headroom (the frame being waited for is itself a frame long), clamped
    /// to `[adaptTargetMinMs, adaptTargetMaxMs]`. p95 rather than max so a
    /// single pathological gap (cell handover, a stall) does not park the
    /// whole call at the clamp ceiling for the length of the window; rather
    /// than mean/stddev because arrival lateness is heavy-tailed and the
    /// tail is precisely what underruns are made of.
    ///
    /// A gap while the pipeline was stopped is excluded structurally:
    /// `reset()` clears `lastPushMonotonic`, so the first frame of a
    /// (re)started stream records nothing.
    private func recordArrival() {
        let now = nowSeconds()
        guard let prev = lastPushMonotonic else {
            lastPushMonotonic = now
            return
        }
        lastPushMonotonic = now
        let gapMs = Int(((now - prev) * 1000.0).rounded())
        guard gapMs >= 0 else { return } // injected/broken clock went backwards: skip the sample
        let lateness = min(max(gapMs - frameMs, 0), Self.adaptTargetMaxMs)
        latenessRing[latenessCount % latenessRing.count] = lateness
        latenessCount += 1
        if latenessCount >= Self.adaptMinSamples, latenessCount % Self.adaptRecomputeEvery == 0 {
            adaptTargetMs = computeTargetMs()
            recomputeTierGeometry()
        }
    }

    /// p95 of the lateness ring + one frame, clamped. Caller (`recordArrival`)
    /// already holds `lock`.
    private func computeTargetMs() -> Int {
        let n = min(latenessCount, latenessRing.count)
        guard n > 0 else { return adaptTargetMs }
        var sorted = Array(latenessRing.prefix(n))
        sorted.sort()
        let p95 = sorted[((n - 1) * 95) / 100]
        return min(max(p95 + frameMs, Self.adaptTargetMinMs), Self.adaptTargetMaxMs)
    }

    /// The adaptive steady-state depth target currently in force, in
    /// milliseconds. `adaptDefaultTargetMs` until enough arrivals have been
    /// observed. Exposed for diagnostics and for parity with Android's
    /// `BufferStats.adaptiveTargetMs`.
    public var adaptiveTargetMs: Int { lock.lock(); defer { lock.unlock() }; return adaptTargetMs }

    /// The inbound frame duration the tiers are currently sized for, in ms.
    public var inboundFrameDurationMs: Int { lock.lock(); defer { lock.unlock() }; return frameMs }

    /// The resolved tier geometry, for asserting the invariants that hold
    /// BETWEEN these numbers rather than the numbers themselves.
    ///
    /// Internal rather than private, and read-only. It exists because the
    /// interesting properties here are relational — tiers must stay ordered and
    /// distinct, a full firing must not breach the floor it protects — and none
    /// of them can be checked from outside while every field is private. Two
    /// defects reached a user's device through exactly that gap: they were
    /// visible in these numbers at 60 ms and nothing could look at them.
    /// See `FrameQuantisationInvariantsTests`.
    struct TierGeometry {
        let frameMs: Int
        let capacity: Int
        let nominal: Int
        let trim: Int
        let high: Int
        let emergency: Int
        let drainTarget: Int
        let maxDropsPerPop: Int
        let silenceScan: Int
        let highScan: Int
        let highDropBudget: Int
        /// W-JBSTRETCH — the ceiling of the "try time-compression first"
        /// band. See `timeStretchCeilingMs`'s kdoc.
        let timeStretchWatermark: Int
        /// W-JBADAPT — the adaptive target `nominal` was resolved from, in
        /// ms, at the moment this snapshot was taken.
        let adaptiveTargetMs: Int
    }

    var tierGeometryForTesting: TierGeometry {
        lock.lock(); defer { lock.unlock() }
        return TierGeometry(frameMs: frameMs, capacity: capFrames, nominal: nominal,
                            trim: trim, high: high, emergency: emergency,
                            drainTarget: drainTarget, maxDropsPerPop: maxDropsPerPop,
                            silenceScan: silenceScan, highScan: highScan,
                            highDropBudget: highDropBudget,
                            timeStretchWatermark: timeStretchWatermark,
                            adaptiveTargetMs: adaptTargetMs)
    }

    // MARK: - Counters (the Android field names, so the two legs compare)

    private var _underruns: Int64 = 0
    private var _overruns: Int64 = 0
    private var _hardDrops: Int64 = 0
    private var _silenceDrops: Int64 = 0
    private var _pushed: Int64 = 0
    /// W-JBSTRETCH — pops satisfied by shaving `timeStretchShaveMs` ms off
    /// the head-of-queue frame instead of dropping it outright.
    private var _timeStretchFrames: Int64 = 0

    // W-ALL60 (2026-08-14) — deliberately NOT seeded from the send profile.
    //
    // Seeding the ladder at `AudioProfile.defaultProfile` was tried and reverted
    // the same day: it presumes the PEER sends 60 ms, and this class exists
    // precisely because that presumption is not ours to make. The receive path
    // holds no negotiation state and follows the OBSERVED inbound duration
    // (`setInboundFrameDurationMs`, driven from the decoded frame's own length),
    // so a peer still on 20 ms — a client mid-rollout, or the asymmetric-strip
    // row — would have been met with a 60 ms ladder instead. Deriving receive
    // geometry from what WE transmit is the exact bug the send/receive split in
    // `AudioCapture` was introduced to remove.
    ///
    /// - Parameter nowSeconds: monotonic clock for the W-JBADAPT
    ///   inter-arrival tracker (see that section's kdoc). Injectable so
    ///   tests can drive time deterministically; production callers should
    ///   not override the default.
    public init(nowSeconds: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.nowSeconds = nowSeconds
        self.latenessRing = [Int](repeating: 0, count: PlayoutJitterBuffer.adaptWindow)
    }

    /// Frames the consumer asked for and the queue could not supply.
    public var underruns: Int64 { lock.lock(); defer { lock.unlock() }; return _underruns }
    /// Frames discarded because the queue was at capacity when one arrived.
    public var overruns: Int64 { lock.lock(); defer { lock.unlock() }; return _overruns }
    /// Frames discarded by tier 3, REGARDLESS of content. The artefact counter.
    public var hardDrops: Int64 { lock.lock(); defer { lock.unlock() }; return _hardDrops }
    /// Frames discarded by tiers 1/2 because they were inaudible anyway.
    public var silenceDrops: Int64 { lock.lock(); defer { lock.unlock() }; return _silenceDrops }
    /// Denominator: without it the drop counts cannot be read as a rate.
    public var pushed: Int64 { lock.lock(); defer { lock.unlock() }; return _pushed }
    /// W-JBSTRETCH — pops satisfied by time-compression instead of a
    /// whole-frame drop. A call with a high value here and low `hardDrops`
    /// is recovering from jitter mostly without the audible skip the
    /// excision tiers cost.
    public var timeStretchFrames: Int64 { lock.lock(); defer { lock.unlock() }; return _timeStretchFrames }
    public var depth: Int { lock.lock(); defer { lock.unlock() }; return queue.count }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        queue.removeAll()
        emergencyDraining = false
        _underruns = 0; _overruns = 0; _hardDrops = 0; _silenceDrops = 0; _pushed = 0
        _timeStretchFrames = 0
        // W-JBADAPT — the NEXT push must not record the stopped interval as a
        // giant inter-arrival gap. The learned target itself is deliberately
        // kept (see `recordArrival`'s kdoc): it describes the link, and the
        // link did not change because the queue was cleared.
        lastPushMonotonic = nil
    }

    public func push(_ frame: Data) {
        lock.lock(); defer { lock.unlock() }
        // W-JBADAPT — feed the arrival tracker before any drop decision, so
        // the cadence statistics describe the LINK, not this buffer's own
        // overrun policy.
        recordArrival()
        if queue.count >= capFrames {
            queue.removeFirst()
            _overruns += 1
        }
        queue.append(frame)
        _pushed += 1
    }

    /// Deliver the next frame, applying the catch-up tiers. `nil` means the
    /// consumer must conceal (see `PlayoutConcealer`).
    public func popWithDriftCatchup() -> Data? {
        lock.lock(); defer { lock.unlock() }
        let d = queue.count

        // Tier 0 — nothing worth working down.
        //
        // W-TRIMFLOOR — the boundary is `trimWatermark`, not `nominalWatermark`.
        //
        // `&& !emergencyDraining` is load-bearing. Without it, raising the boundary
        // to 7 lets tier 0 preempt an ACTIVE latched drain: tier 3 engages at 15,
        // works down to 7, and then tier 0 claims every subsequent pop and the queue
        // parks at 5 forever with the latch still set. On Android this was caught by
        // the drain-budget test, not by reading the diff.
        if d <= trim && !emergencyDraining {
            return popLocked()
        }

        // Tier 3 — budgeted, latched contiguous drain.
        if d >= emergency || emergencyDraining {
            let budget = Self.emergencyDrainBudget(
                depth: d,
                emergencyWatermark: emergency,
                drainTarget: drainTarget,
                maxDropsPerPop: maxDropsPerPop,
                draining: emergencyDraining
            )
            var dropped = 0
            while dropped < budget, !queue.isEmpty {
                queue.removeFirst()
                dropped += 1
            }
            if dropped > 0 { _hardDrops += Int64(dropped) }
            // Latch OFF only once the target is genuinely reached — measured
            // AFTER the delivery below, not before it.
            //
            // 2026-08-11: this read `emergencyDraining = queue.count > drainTarget`
            // and then delivered a frame, so the depth the latch cleared on was
            // one frame more than what the queue was actually left holding. The
            // residual was `drainTarget - 1`: tolerable at 20 ms (2 - 1 = 1
            // frame), and ZERO at 40 and 60 ms, where drainTarget is 1. A tier
            // whose stated purpose is to stop at 40 ms of buffered audio was
            // finishing with an empty queue on the long profile, so the very
            // next pop underran and concealed — the drain fed the starvation it
            // was draining for.
            let delivered = popLocked()
            emergencyDraining = queue.count > drainTarget
            return delivered
        }

        // W-JBSTRETCH (2026-08-25) — NEW FIRST OPTION, not a replacement: at
        // this point depth is past `trim` (tier 0 already returned) and
        // short of `emergency` (tier 3 already returned) — somewhere on the
        // escalation ladder between "fine" and "emergency". Below
        // `timeStretchWatermark` a few-ms time-compression can plausibly buy
        // back depth as fast as it accumulates, without excising a frame at
        // all; at or above it, the backlog is deep enough that a small
        // nibble cannot keep up, so this deliberately falls straight through
        // to the unchanged energy-gated drop machinery below instead of
        // trying and failing on every call. Ported from Android's
        // `JitterBuffer.popWithDriftCatchup` (same constant, same ordering).
        if d <= timeStretchWatermark {
            if let stretched = tryTimeStretch() {
                return stretched
            }
            // Nothing was polled (queue raced to empty, or the cadence is
            // too short to shave) — fall through to the loop below, which
            // polls itself and already handles an empty queue correctly.
        }

        // Tiers 1/2 — walk the queue discarding only INAUDIBLE frames.
        let maxDrops = d >= high ? highDropBudget : 1
        let scanLimit = d >= high ? highScan : silenceScan
        var dropsRemaining = maxDrops
        var anyDropped = false
        for _ in 0..<scanLimit {
            guard !queue.isEmpty else {
                if !anyDropped { _underruns += 1 }
                return nil
            }
            let head = queue.removeFirst()
            // W-TRIMFLOOR — gate on the depth this firing will LEAVE, not the depth
            // it entered with. `queue.count` here is already post-removal, so it is
            // exactly what the queue is left holding if we discard this head and
            // deliver the next frame. The entry threshold alone cannot hold the floor
            // once a firing removes more than one frame, which is the whole defect.
            //
            // 2026-08-11 — strictly greater, not `>=`, and the difference is a
            // whole frame of floor. `queue.count` is post-removal but PRE-delivery:
            // the loop goes on to `return head` for the next frame, so what the
            // queue is actually left holding is `queue.count - 1`. With `>=` the
            // guaranteed residual was `nominal - 1`, which is 3 frames at 20 ms
            // and ZERO at 60 ms, where nominal is 1. The tier could therefore
            // empty the queue by itself and hand the next pop an underrun — the
            // self-powered trim/starve treadmill this floor exists to stop.
            // At 20 ms this is one frame more conservative than before, in the
            // direction the comment above always claimed.
            if dropsRemaining > 0, queue.count > nominal, Self.isSilent(head) {
                _silenceDrops += 1
                dropsRemaining -= 1
                anyDropped = true
                continue
            }
            return head
        }
        // Scan exhausted with everything silent: deliver whatever is next.
        return popLocked()
    }

    private func popLocked() -> Data? {
        if queue.isEmpty {
            _underruns += 1
            return nil
        }
        return queue.removeFirst()
    }

    // MARK: - W-JBSTRETCH (2026-08-25): time-stretch correction

    /// Resizes `stretchScratch` only when the needed length actually
    /// changes (i.e. a cadence change) — not reallocated per correction
    /// event.
    private func ensureStretchScratch(outSamples: Int) {
        let neededBytes = outSamples * 2
        if stretchScratch.count != neededBytes {
            stretchScratch = Data(count: neededBytes)
        }
    }

    /// Try to correct excess depth by shaving `timeStretchShaveMs` ms off
    /// the head-of-queue frame via `TimeStretch.compress`, instead of
    /// dropping a whole frame. Ported from Android's
    /// `JitterBuffer.tryTimeStretch` (W-JBSTRETCH).
    ///
    /// Callers must already hold `lock` and must only invoke this when
    /// depth is already known to be in the "moderately over target" band
    /// (above `trim`, at or below `timeStretchWatermark`). This function
    /// itself does not re-check depth: it is a pure "try to shrink the next
    /// frame" operation, not a tier-selection decision.
    ///
    /// - Returns: the compressed frame on success (also incrementing
    ///   `_timeStretchFrames`); the head-of-queue frame UNMODIFIED if it was
    ///   polled but could not be safely compressed (its actual length does
    ///   not match the currently-adopted cadence — a malformed/truncated
    ///   inbound frame, or a duration transition mid-burst — or
    ///   `TimeStretch.compress` otherwise declined); or `nil` only when
    ///   nothing was polled at all (frame duration too short to shave
    ///   safely, or the queue raced to empty). A `nil` return is never a
    ///   discard — nothing was removed from the queue — so the caller's
    ///   existing fallback path (which itself polls) is free to run exactly
    ///   as if this function had not been called.
    private func tryTimeStretch() -> Data? {
        let n = AudioConstants.sampleRate / 1000 * frameMs
        let shave = Self.timeStretchShaveSamples
        guard n >= shave * 2 else { return nil } // cadence too short to shave safely
        guard !queue.isEmpty else { return nil }

        let head = queue.removeFirst()
        let headSamples = head.count / 2
        guard headSamples == n else {
            // Does not match the CURRENTLY adopted cadence — hand it back
            // unmodified rather than compress it. `frameMs` is driven by
            // whichever frame was pushed MOST RECENTLY (see
            // `AudioCapture`'s inbound-duration observation), so with more
            // than one frame already queued across a duration transition (a
            // profile renegotiation mid-burst — see `AudioConstants`'
            // W-FRAMEAGNOSTIC kdoc), the frame actually at the head of the
            // queue can legitimately be a DIFFERENT duration than what
            // `frameMs` reads right now. A shorter head risks the splice
            // reading past the buffer; a LONGER head would have
            // `TimeStretch.compress` silently read only its first `n`
            // samples and discard the genuine remainder as if it never
            // arrived — worse than either declining or an audible skip.
            return head
        }

        let outSamples = n - shave
        ensureStretchScratch(outSamples: outSamples)
        let written = TimeStretch.compress(
            input: head,
            inputSamples: n,
            shaveSamples: shave,
            out: &stretchScratch
        )
        guard written == outSamples * 2 else {
            // Declined by the pure function. Should not happen given the
            // guards above, but the frame was already removed from the
            // queue, so deliver it whole rather than lose it — never trust
            // an external boundary silently.
            return head
        }

        _timeStretchFrames += 1
        return stretchScratch
    }

    // MARK: - Pure decision functions (tested directly)

    /// How many frames tier 3 may discard on THIS tick.
    ///
    /// The property that matters is not "the buffer reaches its target" — it is
    /// that no single playback tick deletes an unbounded run of contiguous
    /// audio. Ported from Android's `emergencyDrainBudget`.
    static func emergencyDrainBudget(
        depth: Int,
        emergencyWatermark: Int,
        drainTarget: Int,
        maxDropsPerPop: Int,
        draining: Bool
    ) -> Int {
        if !draining && depth < emergencyWatermark { return 0 }
        let excess = depth - drainTarget
        if excess <= 0 { return 0 }
        return min(excess, maxDropsPerPop)
    }

    /// Is this frame inaudible enough to discard while working down a backlog?
    ///
    /// W-LONGAUDIO (2026-08-10) — judged on 20 ms SUB-BLOCKS, ALL of which must
    /// be silent. The threshold keeps its calibrated value and its 20 ms
    /// detection resolution; what changes is that a longer frame no longer gets
    /// to average its speech away.
    ///
    /// Whole-frame RMS is a mean, and a mean over 60 ms hides a third of a
    /// frame of speech behind two thirds of silence: a syllable at RMS 800
    /// flanked by two silent sub-blocks averages to about 460 and lands under
    /// the 500 threshold, so the tier deletes the syllable and calls it
    /// silence. Requiring every sub-block to be quiet makes the decision
    /// independent of frame length.
    ///
    /// At 20 ms there is exactly one sub-block, so this is bit-identical to the
    /// previous whole-frame test — today's behaviour is unchanged.
    static func isSilent(_ frame: Data) -> Bool {
        let totalSamples = frame.count / 2
        guard totalSamples > 0 else { return true }
        let subBlockSamples = AudioConstants.sampleRate / 1000 * silenceSubBlockMs
        return frame.withUnsafeBytes { raw -> Bool in
            let p = raw.bindMemory(to: Int16.self)
            var start = 0
            while start < totalSamples {
                // A trailing partial sub-block is judged on what it actually
                // holds rather than skipped — skipping it would let a short
                // burst at the tail of a frame slip through unexamined.
                let end = min(start + subBlockSamples, totalSamples)
                var sumSq: Double = 0
                for i in start..<end {
                    let s = Double(Int16(littleEndian: p[i]))
                    sumSq += s * s
                }
                let count = end - start
                if (sumSq / Double(count)).squareRoot() >= silenceRmsThreshold { return false }
                start = end
            }
            return true
        }
    }
}

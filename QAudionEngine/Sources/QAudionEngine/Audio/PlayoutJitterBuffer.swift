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
        capFrames = AudioConstants.framesForMs(Self.capacityMs, frameDurationMs: ms)
        nominal = AudioConstants.framesForMs(Self.nominalWatermarkMs, frameDurationMs: ms)
        trim = AudioConstants.framesForMs(Self.trimWatermarkMs, frameDurationMs: ms)
        high = AudioConstants.framesForMs(Self.highWatermarkMs, frameDurationMs: ms)
        emergency = AudioConstants.framesForMs(Self.emergencyWatermarkMs, frameDurationMs: ms)
        drainTarget = AudioConstants.framesForMs(Self.emergencyDrainTargetMs, frameDurationMs: ms)
        maxDropsPerPop = AudioConstants.framesForMs(Self.emergencyMaxDropsPerPopMs, frameDurationMs: ms)
        silenceScan = AudioConstants.framesForMs(Self.silenceScanLimitMs, frameDurationMs: ms)
        highScan = AudioConstants.framesForMs(Self.highTierScanLimitMs, frameDurationMs: ms)
        highDropBudget = AudioConstants.framesForMs(Self.highTierDropBudgetMs, frameDurationMs: ms)
    }

    /// The inbound frame duration the tiers are currently sized for, in ms.
    public var inboundFrameDurationMs: Int { lock.lock(); defer { lock.unlock() }; return frameMs }

    // MARK: - Counters (the Android field names, so the two legs compare)

    private var _underruns: Int64 = 0
    private var _overruns: Int64 = 0
    private var _hardDrops: Int64 = 0
    private var _silenceDrops: Int64 = 0
    private var _pushed: Int64 = 0

    public init() {}

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
    public var depth: Int { lock.lock(); defer { lock.unlock() }; return queue.count }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        queue.removeAll()
        emergencyDraining = false
        _underruns = 0; _overruns = 0; _hardDrops = 0; _silenceDrops = 0; _pushed = 0
    }

    public func push(_ frame: Data) {
        lock.lock(); defer { lock.unlock() }
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
            // Latch OFF only once the target is genuinely reached.
            emergencyDraining = queue.count > drainTarget
            return popLocked()
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
            if dropsRemaining > 0, queue.count >= nominal, Self.isSilent(head) {
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

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

    /// Hard cap. Above this, `push` drops the OLDEST frame (an overrun) so the
    /// queue cannot become an unbounded latency sink. 30 frames = 600 ms.
    public static let capacityFrames = 30

    /// At or below this depth the buffer just delivers: no catch-up tier fires.
    /// 4 frames = 80 ms, enough to absorb a 20 ms spike without underrunning.
    static let nominalWatermark = 4

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
    static let trimWatermark = 7

    /// Tier 2. Above this the buffer may discard SILENT frames to work down a
    /// backlog, scanning further and dropping more per tick than tier 1.
    static let highWatermark = 8

    /// Tier 3. Above this the backlog is too large to walk down by skipping
    /// silence, so contiguous frames are discarded — budgeted, and latched.
    static let emergencyWatermark = 15

    /// Where tier 3 stops. Deliberately low: the tier must actually reach it,
    /// or the drain leaves standing latency behind (see the class notes).
    static let emergencyDrainTarget = 2

    /// The bound that makes tier 3 acceptable. Three frames is 60 ms.
    static let emergencyMaxDropsPerPop = 3

    /// Tier 1/2 scan limits and drop budgets.
    static let silenceScanLimit = 3
    static let highTierScanLimit = 8
    static let highTierDropBudget = 3

    /// A frame whose RMS is under this is inaudible, so discarding it to work
    /// down a backlog costs nothing. 16-bit scale.
    static let silenceRmsThreshold: Double = 500

    // MARK: - State

    private let lock = NSLock()
    private var queue: [Data] = []
    private var emergencyDraining = false

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
        if queue.count >= Self.capacityFrames {
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
        if d <= Self.trimWatermark && !emergencyDraining {
            return popLocked()
        }

        // Tier 3 — budgeted, latched contiguous drain.
        if d >= Self.emergencyWatermark || emergencyDraining {
            let budget = Self.emergencyDrainBudget(
                depth: d,
                emergencyWatermark: Self.emergencyWatermark,
                drainTarget: Self.emergencyDrainTarget,
                maxDropsPerPop: Self.emergencyMaxDropsPerPop,
                draining: emergencyDraining
            )
            var dropped = 0
            while dropped < budget, !queue.isEmpty {
                queue.removeFirst()
                dropped += 1
            }
            if dropped > 0 { _hardDrops += Int64(dropped) }
            // Latch OFF only once the target is genuinely reached.
            emergencyDraining = queue.count > Self.emergencyDrainTarget
            return popLocked()
        }

        // Tiers 1/2 — walk the queue discarding only INAUDIBLE frames.
        let maxDrops = d >= Self.highWatermark ? Self.highTierDropBudget : 1
        let scanLimit = d >= Self.highWatermark ? Self.highTierScanLimit : Self.silenceScanLimit
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
            if dropsRemaining > 0, queue.count >= Self.nominalWatermark, Self.isSilent(head) {
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

    /// RMS of a little-endian 16-bit PCM frame, against `silenceRmsThreshold`.
    static func isSilent(_ frame: Data) -> Bool {
        let n = frame.count / 2
        guard n > 0 else { return true }
        var sumSq: Double = 0
        frame.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<n {
                let s = Double(Int16(littleEndian: p[i]))
                sumSq += s * s
            }
        }
        return (sumSq / Double(n)).squareRoot() < silenceRmsThreshold
    }
}

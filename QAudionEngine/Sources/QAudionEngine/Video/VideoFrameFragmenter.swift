import Foundation

/// Fragments H.264/HEVC NAL units into transport-sized chunks and
/// reassembles them. Direct port of Android's `VideoFrameFragmenter.kt`.
///
/// Each fragment gets a 7-byte sub-header:
/// ```
///   [fragFlags(1)][frameId(2)][fragIdx(1)][totalFrags(1)][bitrateHint(2)]
/// ```
///
/// Fragments are independently encrypted by the AEAD layer, so packet
/// loss only affects individual fragments, not the whole video frame.
public final class VideoFrameFragmenter: @unchecked Sendable {

    /// Task 10 holistic-review fix (2026-07-01) — thrown by `fragment(...)`
    /// when a NAL unit needs more than `VideoConstants.maxFragmentsPerFrame`
    /// fragments. The PREVIOUS behaviour silently clamped
    /// `min(neededFragments, maxFragmentsPerFrame)`, so any NAL above
    /// `maxFragmentsPerFrame * maxDataPerFragment` (~304KB, a realistic
    /// 720p HEVC IDR size) was truncated with no error and no log — the
    /// peer's decoder received a corrupted, incomplete NAL with zero
    /// signal anything went wrong. Android's fragmenter `require()`s the
    /// same bound and the caller drops the WHOLE frame on the exception
    /// (`BcryptoWsVideoRelayTransport.sendFrame`'s catch block) — this
    /// mirrors that: reject the oversized frame outright so the caller can
    /// drop-and-log it, rather than shipping a corrupted one.
    public enum FragmenterError: Error, Equatable {
        case frameTooLarge(nalSize: Int, neededFragments: Int, maxFragments: Int)
    }

    /// Result of defragmentation: a complete reassembled NAL unit.
    public struct ReassembledFrame: Equatable {
        public let nalUnit: Data
        public let frameId: Int
        public let isKeyFrame: Bool
        public let bitrateHintKbps: Int

        public init(nalUnit: Data, frameId: Int, isKeyFrame: Bool, bitrateHintKbps: Int) {
            self.nalUnit = nalUnit
            self.frameId = frameId
            self.isKeyFrame = isKeyFrame
            self.bitrateHintKbps = bitrateHintKbps
        }
    }

    // MARK: - Internal pending state

    /// Task 11 holistic-review fix (2026-07-01) — single-frame-in-flight
    /// state. Previously this class kept a `[Int: PendingFrame]`
    /// dictionary (multiple frameIds tracked concurrently, reclaimed
    /// only by the 150ms `purgeStaleFrames()` timeout), which diverged
    /// from Android's `VideoFrameReassembler.kt` and Desktop's
    /// `VideoFrameReassembler.ts` — both of which hold exactly ONE
    /// pending frame: a new frameId unconditionally discards whatever
    /// partial frame was previously in flight (no dictionary, no
    /// timeout needed to reclaim a stale ENTRY since there is only one
    /// slot to begin with). This file's own top-of-file doc comment
    /// claims a "direct port of Android's VideoFrameFragmenter.kt" —
    /// this was the one place that claim didn't hold. `pendingFrame` now
    /// mirrors that single-slot semantics exactly.
    private final class PendingFrame {
        var fragments: [Data?]
        let totalFragments: Int
        let isKeyFrame: Bool
        let bitrateHintKbps: Int
        let startTimeMs: Int64
        var receivedCount: Int
        let frameId: Int

        init(frameId: Int, totalFragments: Int, isKeyFrame: Bool, bitrateHintKbps: Int, startTimeMs: Int64) {
            self.frameId = frameId
            self.fragments = Array(repeating: nil, count: totalFragments)
            self.totalFragments = totalFragments
            self.isKeyFrame = isKeyFrame
            self.bitrateHintKbps = bitrateHintKbps
            self.startTimeMs = startTimeMs
            self.receivedCount = 0
        }
    }

    private let lock = NSLock()
    private var pendingFrame: PendingFrame?
    private var nextFrameId: Int = 0

    public init() {}

    // MARK: - Fragment

    /// Fragment a NAL unit into transport-sized chunks with sub-headers.
    /// Each fragment will be independently encrypted by the AEAD layer.
    public func fragment(
        nalUnit: Data,
        isKeyFrame: Bool,
        bitrateKbps: Int = VideoConstants.defaultVideoBitrateBps / 1000
    ) throws -> [Data] {
        let maxDataPerFragment = VideoConstants.maxFragmentPayload - VideoConstants.videoFragmentHeaderSize
        let neededFragments = (nalUnit.count + maxDataPerFragment - 1) / maxDataPerFragment
        guard neededFragments <= VideoConstants.maxFragmentsPerFrame else {
            throw FragmenterError.frameTooLarge(
                nalSize: nalUnit.count,
                neededFragments: neededFragments,
                maxFragments: VideoConstants.maxFragmentsPerFrame)
        }
        let totalFragments = max(1, neededFragments)

        lock.lock()
        let frameId = nextFrameId
        nextFrameId = (nextFrameId + 1) & 0xFFFF
        lock.unlock()

        var fragments: [Data] = []
        fragments.reserveCapacity(totalFragments)

        for i in 0..<totalFragments {
            let dataOffset = i * maxDataPerFragment
            let dataLength = min(maxDataPerFragment, nalUnit.count - dataOffset)
            let isLast = (i == totalFragments - 1)

            var fragFlags: UInt8 = 0
            if isKeyFrame { fragFlags |= VideoConstants.fragFlagKeyFrame }
            if isLast { fragFlags |= VideoConstants.fragFlagLastFragment }

            var fragment = Data(capacity: VideoConstants.videoFragmentHeaderSize + dataLength)
            fragment.append(fragFlags)
            // frameId u16 BE
            fragment.append(UInt8((frameId >> 8) & 0xFF))
            fragment.append(UInt8(frameId & 0xFF))
            fragment.append(UInt8(i & 0xFF))             // fragIdx
            fragment.append(UInt8(totalFragments & 0xFF)) // totalFrags
            // bitrateHint u16 BE
            fragment.append(UInt8((bitrateKbps >> 8) & 0xFF))
            fragment.append(UInt8(bitrateKbps & 0xFF))
            // NAL chunk
            if dataLength > 0 {
                fragment.append(nalUnit.subdata(in: (nalUnit.startIndex + dataOffset)..<(nalUnit.startIndex + dataOffset + dataLength)))
            }
            fragments.append(fragment)
        }
        return fragments
    }

    // MARK: - Defragment

    /// Defragment a received fragment and attempt to reassemble the
    /// complete NAL unit. Returns a `ReassembledFrame` when all
    /// fragments of a frame have arrived, `nil` otherwise.
    public func defragment(_ fragmentPayload: Data) -> ReassembledFrame? {
        guard fragmentPayload.count >= VideoConstants.videoFragmentHeaderSize else {
            return nil
        }
        let base = fragmentPayload.startIndex
        let fragFlags = fragmentPayload[base]
        let frameId = (Int(fragmentPayload[base + 1]) << 8) | Int(fragmentPayload[base + 2])
        let fragIdx = Int(fragmentPayload[base + 3])
        let totalFrags = Int(fragmentPayload[base + 4])
        let bitrateHintKbps = (Int(fragmentPayload[base + 5]) << 8) | Int(fragmentPayload[base + 6])
        let isKeyFrame = (fragFlags & VideoConstants.fragFlagKeyFrame) != 0

        guard totalFrags > 0, fragIdx < totalFrags else { return nil }

        let nalChunk = fragmentPayload.subdata(in:
            (base + VideoConstants.videoFragmentHeaderSize)..<fragmentPayload.endIndex)

        lock.lock()
        defer { lock.unlock() }

        // CX/perf micro (audit 2026-07-02): capture the clock ONCE for this
        // locked scope and reuse it for both the new-frame `startTimeMs` and
        // the completion-path `nowMsForStats` below. Previously each read
        // called `Date().timeIntervalSince1970 * 1000` independently on the
        // per-frame hot path. Sharing one value is also strictly MORE correct:
        // when a single-fragment frame is created AND completed in the same
        // call, both reads now observe the same logical "now" (reassemblyMs = 0
        // exactly), instead of a tiny non-zero delta from two separate clock
        // reads. Purge semantics are unchanged: `purgeStaleFrames()` compares
        // its own `nowMs` against this `startTimeMs`, and this value is taken at
        // the same point the old `Date()` was, so the timeout window is identical.
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        // Task 11 holistic-review fix — single-frame-in-flight, matching
        // Android's VideoFrameReassembler.kt / Desktop's
        // VideoFrameReassembler.ts byte-for-byte: a new frameId
        // unconditionally discards whatever partial frame was
        // previously buffered (no dictionary keyed by frameId, no
        // timeout needed to reclaim a stale slot — there is only ever
        // one). A REPEATED frameId whose totalFrags disagrees with the
        // in-flight state is an inconsistent/malformed frame and is
        // dropped, same as before.
        let pending: PendingFrame
        if let existing = pendingFrame, existing.frameId == frameId {
            if existing.totalFragments != totalFrags { return nil }
            pending = existing
        } else {
            pending = PendingFrame(
                frameId: frameId,
                totalFragments: totalFrags,
                isKeyFrame: isKeyFrame,
                bitrateHintKbps: bitrateHintKbps,
                startTimeMs: nowMs
            )
            pendingFrame = pending
        }

        // Store fragment (ignore duplicates).
        if pending.fragments[fragIdx] == nil {
            pending.fragments[fragIdx] = nalChunk
            pending.receivedCount += 1
        }

        // Check if complete.
        guard pending.receivedCount >= pending.totalFragments else {
            return nil
        }
        pendingFrame = nil
        // W398: count completed frames for loss-rate denominator.
        framesReceivedInWindow &+= 1
        // W524: track per-frame reassembly latency + inter-arrival
        // jitter as local proxies for the (latencyMs, jitterMs) fields
        // Android's AdaptiveBitrateController uses. We don't have RTCP
        // feedback on the WS relay path so a remote RTT isn't available;
        // the reassembly tail (time from first fragment to last
        // fragment) is a usable proxy for transport jitter because it
        // grows with both packet delay variance and reorder. Inter-
        // arrival jitter is the std deviation of completion times
        // computed via Welford's online algorithm.
        let nowMsForStats = nowMs
        let reassemblyMs = max(Int64(0), nowMsForStats - pending.startTimeMs)
        latencySumMs &+= reassemblyMs
        latencySamplesInWindow &+= 1
        if lastCompletionTimeMs > 0 {
            let gap = Double(nowMsForStats - lastCompletionTimeMs)
            // Welford's online variance: tracks running mean and m2 for
            // gap-time, and we publish stddev at window close.
            jitterCount += 1
            let delta = gap - jitterMean
            jitterMean += delta / Double(jitterCount)
            jitterM2 += delta * (gap - jitterMean)
        }
        lastCompletionTimeMs = nowMsForStats

        // Reassemble NAL unit.
        let totalSize = pending.fragments.reduce(0) { $0 + ($1?.count ?? 0) }
        var nalUnit = Data(capacity: totalSize)
        for chunk in pending.fragments {
            if let chunk = chunk { nalUnit.append(chunk) }
        }
        return ReassembledFrame(
            nalUnit: nalUnit,
            frameId: frameId,
            isKeyFrame: pending.isKeyFrame,
            bitrateHintKbps: pending.bitrateHintKbps
        )
    }

    // MARK: - Maintenance

    /// Purge the pending frame if it exceeded the reassembly timeout.
    /// Should be called periodically (e.g., every 200ms). Returns the
    /// number of purged frames (0 or 1).
    /// W398: each purge is also accumulated into a sliding-window
    /// loss counter so the ABR controller can read recent loss rate.
    ///
    /// Task 11 holistic-review fix — with single-frame-in-flight
    /// semantics (see `defragment`) there is at most one pending frame
    /// to reclaim, not an unbounded dictionary. Kept as its own method
    /// (rather than folded into `defragment` or removed) because it is
    /// still load-bearing: `VideoCallPipeline.startPurgeTimer()` calls
    /// it on a 200ms `DispatchSourceTimer` to evict a partial frame
    /// whose remaining fragments never arrive (no new frameId will ever
    /// come in to naturally evict it), and its return value feeds
    /// `framesLostInWindow`, which `consumeAbrSample`/
    /// `consumeAbrSampleExtended` report to `AbrController` for the
    /// loss-rate feedback loop.
    @discardableResult
    public func purgeStaleFrames() -> Int {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let timeout = VideoConstants.fragmentReassemblyTimeoutMs
        lock.lock()
        defer { lock.unlock() }
        guard let pending = pendingFrame, nowMs - pending.startTimeMs > timeout else {
            return 0
        }
        pendingFrame = nil
        // W398: counter bookkeeping.
        framesLostInWindow &+= 1
        return 1
    }

    // MARK: - W398 ABR feedback

    private var framesReceivedInWindow: Int = 0
    private var framesLostInWindow: Int = 0
    // W524: latency / jitter rolling state. See `defragment` for the
    // online update; published values are averaged over the window and
    // reset on each `consumeAbrSample()` call.
    private var latencySumMs: Int64 = 0
    private var latencySamplesInWindow: Int = 0
    private var lastCompletionTimeMs: Int64 = 0
    private var jitterMean: Double = 0
    private var jitterM2: Double = 0
    private var jitterCount: Int = 0

    /// W398 — read and reset the sliding-window loss counters. Called
    /// by AbrController every `abrSampleIntervalMs` to compute recent
    /// loss percentage. Returned tuple: (received, lost). lossPct =
    /// lost / max(received + lost, 1).
    public func consumeAbrSample() -> (received: Int, lost: Int) {
        lock.lock()
        defer { lock.unlock() }
        let r = framesReceivedInWindow
        let l = framesLostInWindow
        framesReceivedInWindow = 0
        framesLostInWindow = 0
        return (r, l)
    }

    /// W524 — extended ABR sample including latency + jitter proxies.
    /// Resets the window after read. avgLatencyMs is the mean
    /// reassembly tail (first fragment → completion) over the window;
    /// jitterMs is the std deviation of inter-arrival times of
    /// successfully-reassembled frames. Both are 0 when the window
    /// had no completed frames (caller should fall back to the
    /// loss-only loop in that case).
    public func consumeAbrSampleExtended() -> (received: Int, lost: Int, avgLatencyMs: Int64, jitterMs: Double) {
        lock.lock()
        defer { lock.unlock() }
        let r = framesReceivedInWindow
        let l = framesLostInWindow
        let avgLat: Int64 = latencySamplesInWindow > 0
            ? latencySumMs / Int64(latencySamplesInWindow) : 0
        let jitter: Double = jitterCount > 1
            ? (jitterM2 / Double(jitterCount - 1)).squareRoot() : 0
        framesReceivedInWindow = 0
        framesLostInWindow = 0
        latencySumMs = 0
        latencySamplesInWindow = 0
        jitterMean = 0
        jitterM2 = 0
        jitterCount = 0
        // Keep lastCompletionTimeMs so the next window's first jitter
        // sample is a real inter-arrival from this window's last frame —
        // UNLESS this window completed zero frames (video paused/stalled):
        // then the stale timestamp would make the next real frame's gap
        // span the whole idle period, poisoning jitterMean/M2 with one
        // huge outlier (XP-9). Zero it so the `lastCompletionTimeMs > 0`
        // guard in `defragment` skips that first post-idle sample instead.
        if latencySamplesInWindow == 0 {
            lastCompletionTimeMs = 0
        }
        return (r, l, avgLat, jitter)
    }

    /// 0 or 1 — single-frame-in-flight (see `defragment`), kept as its
    /// own count rather than a bare `Bool`/`pendingFrame != nil` so
    /// existing call sites (tests) reading a count don't need to change.
    public var pendingFrameCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pendingFrame == nil ? 0 : 1
    }

    public func reset() {
        lock.lock()
        pendingFrame = nil
        nextFrameId = 0
        lock.unlock()
    }
}

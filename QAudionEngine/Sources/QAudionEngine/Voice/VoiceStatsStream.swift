import Foundation

/// The stats-derived flags of one chunk, final: released at the first input after which they cannot change any more, or
/// as the flags of an unknown chunk when no snapshot that could settle them arrived in time (`overdue`).
struct VoiceChunkFlags {
    var index: Int
    var excluded: Bool
    var txUnknown: Bool
    var concUnknown: Bool
    var touchConcealment: Bool
    var touchStretch: Bool
    /// Known intervals whose widened span overlaps the chunk (none for an overdue chunk).
    var overlaps: [VoiceIntervalRef]
    /// The clock of the input at which the flags were released.
    var releaseNs: Int64
    var overdue: Bool
}

/// The stats track of a call as a stream. It is fed three kinds of input, each with its tap-clock time, in non-decreasing
/// time: RX blocks (`addTapBlock`), mute changes (`addMute`) and deliveries (`addSnapshot`, at `arriveNs`), then the end of
/// the call (`finish`). At the same time the order is RX blocks, mute changes, deliveries. The clock is the time of the
/// latest input; a dropped delivery moves it too, and nothing else does. Chunks are registered with `addChunk` and their
/// flags come out of `pollFinal()` in chunk order.
///
/// A kept snapshot is SETTLED when `reqNs + late_ms` is below the clock (no delivery fed from now on can be ordered in front
/// of it) and RESOLVED when an RX block called at or after its arrival has been fed (the tap position at the arrival is the
/// latest block's when the delivery was fed, so no history of blocks is kept) or the call has ended. The CHECKED prefix of the
/// kept snapshots, in request order, is the longest prefix whose members are all settled and resolved; its members are
/// checked one at a time: the tap checks run, and the interval that ends at the snapshot before it is built, once. With `p`
/// snapshots checked the horizon is `H = lo(p - 2)`; the concealment flags of a chunk are final when `H >= t1 + widen_ms`,
/// its TX flags when `H > t1 + post_ms`, both when the call has ended. A chunk is released at the first input after which
/// both are final, and a chunk that is not final when the clock reaches `t1 + overdue_ms` is released at that input as an
/// unknown chunk: not excluded, TX unknown, concealment unknown, touching nothing, no interval.
///
/// A delivery is dropped when it repeats the previous kept one, carries stamps that cannot be right, is ordered in front of
/// a settled snapshot (a later request with `req + late_ms` below its arrival), or would make the kept brackets start
/// earlier than their predecessor's in request order. Dropping a delivery is always safe: the next interval spans it.
///
/// Late and lost inputs: an input whose time and kind are below those of the latest input fed (the order above) is LATE and
/// moves nothing, the clock included.
/// - A late delivery is dropped.
/// - A late RX block is dropped. Every kept snapshot that arrived at or after it has read, or will read until the next block,
///   a position that is too low (it is STALE): its interval, the one before and the one after are unknown. The dropped block
///   also covers the kept snapshots that arrived at or before it and that no block covers yet. From then on the offset check
///   compares with the largest offset ever seen (it never restarts) and the TX test reads the lowest floor any feed can have;
///   the built intervals from the one before the first that ends at or after the block on are marked unknown.
/// - A late mute change is kept at its own time and marks the built intervals it can reach unknown.
/// - A mute change that was lost (`addLostMute`) is a late unmute at the time of the change ahead of it in the queue.
/// None of them makes a flag more known than the feed in order gives, for the chunks released after the late input was fed;
/// a chunk released before is not revised.
///
/// Retained state is bounded: the chunks waiting for their flags, the kept snapshots that are not checked (at most 64 may
/// wait for an RX block: one more drops the oldest) and the last two that are, the intervals that a waiting chunk can still
/// reach, the mute changes from the horizon on, the previous kept delivery and the latest RX block. Nothing is rebuilt.
///
/// Not thread safe: the caller serialises the calls.
final class VoiceStatsStream {
    /// The most kept snapshots that wait for an RX block; one more drops the oldest of them.
    static let capUnresolved = 64

    private static let nsPerThreeTicks: UInt64 = 31_250
    private static let txPowerFloor = 1e-12

    // The order of inputs at the same time.
    private static let rxRank = 0
    private static let muteRank = 1
    private static let deliveryRank = 2
    private static let endRank = 3

    /// A kept snapshot with what the stream knows about it.
    private final class Node {
        let s: VoiceStatsSnapshot
        let lo: Int64
        /// The tap position of the latest block when the delivery was fed.
        let pos: Int64
        /// Its position may be low: it was read before a late RX block reached the stream.
        var stale: Bool
        /// Nil until an RX block called at or after the arrival has been fed (a late one included); false at the end of the call
        /// when none was.
        var cov: Bool?
        /// The interval that ends at this snapshot is unknown (tap checks, stale position, the cap).
        var bad = false

        init(s: VoiceStatsSnapshot, lo: Int64, pos: Int64, stale: Bool) {
            self.s = s
            self.lo = lo
            self.pos = pos
            self.stale = stale
        }
    }

    private struct PendingChunk {
        var index: Int
        var t0: Int64
        var t1: Int64
    }

    private struct TapPrevious {
        var total: Int64
        var position: Int64
        var wide: Int64
    }

    private let tx: VoiceConstants.Gates.Tx
    private let widenNs: Int64
    private let postNs: Int64
    private let preCapNs: Int64
    private let lateNs: Int64
    private let spanNs: Int64
    private let cacheNs: Int64
    private let overdueNs: Int64
    private let txSpanS: Double
    private let slackNs: Int64
    private let ticksPerSample: Int64

    private var mediaStartNs: Int64?
    private var clockNs: Int64 = 0
    private var hasClock = false
    /// The kind of the latest input fed.
    private var rank = -1

    /// The kept snapshots in request order: the anchor (the last one checked) first when there is one, then the unchecked ones.
    private var kept: [Node] = []
    /// The previous kept delivery in feed order (the repeat check).
    private var lastKept: VoiceStatsSnapshot?
    /// Checked before the anchor: its counters start the pending interval.
    private var prev2: Node?
    private var anchor: Node?
    private var checkedCount = 0
    private var tapLastNs: Int64?
    private var tapTicks: Int64 = 0
    /// An RX block was dropped as late and no later block has been fed: the position is stale.
    private var staleGap = false
    /// The cap dropped the newest snapshot: the next kept one has an unknown interval.
    private var hole = false
    private var pruneNs: Int64?
    private var ended = false

    // The tap checks: the largest offset since the last restart, the largest ever seen, the previous checked snapshot.
    private var offsetMax: Int64?
    private var offsetSup: Int64?
    private var tapPrevious: TapPrevious?
    private var offsetTainted = false

    // The interval maker: the TX floor after the latest known interval and the lowest floor any feed can have.
    private var floorDb: Double?
    private var floorLow: Double?
    private var floorTainted = false

    /// The built intervals that a waiting chunk can still reach, in build order, with the chunk queries.
    private var track: VoiceStatsTrack
    private var mutes: [VoiceMute] = []

    private var pending: [PendingChunk] = []
    private var lastChunkEndNs: Int64?
    private var ready: [VoiceChunkFlags] = []

    // Counters, for the engine and the tests.
    private(set) var lateRxCount = 0
    private(set) var lateMuteCount = 0
    private(set) var lateDeliveryCount = 0
    private(set) var lostMuteCount = 0
    private(set) var capDroppedCount = 0

    // The largest sizes of the retained state, for the tests of the bound.
    private(set) var peakKept = 0
    private(set) var peakIntervals = 0
    private(set) var peakMutes = 0
    private(set) var peakPending = 0
    private(set) var peakUnresolved = 0

    /// Called with every interval when it is built, in order (the guards included, the last guard at the end of the call).
    var intervalListener: ((VoiceStatsInterval) -> Void)?
    /// Called with every delivery that is dropped and the rule: repeat, stamps, D1, D2, late or cap.
    var dropListener: ((VoiceStatsSnapshot, String) -> Void)?

    init(gates: VoiceConstants.Gates) {
        let st = gates.stats
        tx = gates.tx
        widenNs = Int64(st.widenMs) * 1_000_000
        postNs = Int64(gates.tx.postMs) * 1_000_000
        preCapNs = Int64(gates.tx.preMsCap) * 1_000_000
        lateNs = Int64(st.lateMs) * 1_000_000
        spanNs = Int64(st.spanMs) * 1_000_000
        cacheNs = Int64(st.cacheMs) * 1_000_000
        overdueNs = Int64(st.overdueMs) * 1_000_000
        txSpanS = st.txSpanMs / 1000.0
        slackNs = Int64(st.tapLagMs + st.tapTolMs) * 1_000_000
        ticksPerSample = Int64(VoiceStatsTrack.tickRate / st.rxRateHz)
        track = VoiceStatsTrack(gates: gates)
    }

    /// The time of the latest input fed (nil before the first).
    var clockTime: Int64? { hasClock ? clockNs : nil }

    /// The mute changes that are retained, in time order.
    var retainedMutes: [VoiceMute] { mutes }

    // MARK: inputs

    /// The tap-clock time of the first sample of the call.
    func setMediaStart(_ tNs: Int64) {
        mediaStartNs = tNs
    }

    /// One RX block as the tap callback counted it: the tap clock of the callback and the cumulative tap position after the
    /// block, in ticks of 1/96,000 s (counted before any queue, so a block that a queue dropped still advances it). A block
    /// below the clock by the order of the feed is dropped as late.
    func addTapBlock(tNs: Int64, ticks: Int64) {
        if ended { return }
        if isLate(tNs, Self.rxRank) {
            lateRxCount += 1
            lateRx(tNs)
            return
        }
        tick(tNs, Self.rxRank)
        tapLastNs = tNs
        tapTicks = ticks
        staleGap = false
        for node in uncheckedNodes() where node.cov == nil && node.s.arriveNs <= tNs {
            node.cov = true
        }
        advance()
        release()
    }

    /// A change of the mute state at tap-clock time `tNs`. One below the clock is kept at its own time and moves nothing.
    func addMute(tNs: Int64, muted: Bool) {
        if ended { return }
        if isLate(tNs, Self.muteRank) {
            lateMuteCount += 1
            insertMute(tNs: tNs, muted: muted)
            return
        }
        tick(tNs, Self.muteRank)
        mutes.append(VoiceMute(tNs: tNs, muted: muted))
        advance()
        release()
    }

    /// A mute change was lost (a bounded queue overflowed and dropped it). Mute changes should reach the stream losslessly;
    /// a caller that cannot guarantee it and can tell that an overflow happened calls this with the time of the change that
    /// was ahead of the lost one in the queue (the media start when there is none), after every change ahead of it has
    /// reached the stream. It is a late unmute at that time: the intervals after it count as not muted until the next change,
    /// which only excludes more.
    func addLostMute(tNs: Int64) {
        if ended { return }
        lostMuteCount += 1
        insertMute(tNs: tNs, muted: false)
    }

    /// One delivered report. One below the clock by the order of the feed is late and dropped.
    func addSnapshot(_ snapshot: VoiceStatsSnapshot) {
        if ended { return }
        if isLate(snapshot.arriveNs, Self.deliveryRank) {
            lateDeliveryCount += 1
            dropListener?(snapshot, "late")
            return
        }
        tick(snapshot.arriveNs, Self.deliveryRank)
        if let rule = offer(snapshot) {
            dropListener?(snapshot, rule)
        } else {
            applyCap()
        }
        advance()
        release()
    }

    /// A completed chunk waiting for its flags (in index order).
    func addChunk(index: Int, t0Ns: Int64, t1Ns: Int64) {
        pending.append(PendingChunk(index: index, t0: t0Ns, t1: t1Ns))
        if let last = lastChunkEndNs {
            lastChunkEndNs = max(last, t1Ns)
        } else {
            lastChunkEndNs = t1Ns
        }
    }

    /// The end of the call at tap-clock time `endNs` (the time of the latest input when not given). Everything is final
    /// then: the chunks still waiting are released with the intervals over all the kept snapshots, and the guard of the last
    /// snapshot is built.
    func finish(endNs: Int64? = nil) {
        if ended { return }
        let requested = endNs ?? clockNs
        tick(hasClock ? max(requested, clockNs) : requested, Self.endRank)
        ended = true
        for node in uncheckedNodes() where node.cov == nil {
            node.cov = false
        }
        advance()
        if checkedCount >= 2, let a = anchor, let p = prev2 {
            build(p, a)
            addInterval(VoiceStatsInterval(
                key: a.s.reqNs, startNs: a.lo, endNs: a.s.arriveNs, known: false, isGuard: true))
        }
        release()
    }

    /// The end of the call forgets the chunks that end after `t1Max` (the end of the track): they are never released. Chunks end
    /// in order, so these are the newest ones.
    func discardPendingAfter(_ t1Max: Int64) {
        pending.removeAll { $0.t1 > t1Max }
    }

    /// The flags of the oldest registered chunk once they are released (final, or overdue), else nil.
    func pollFinal() -> VoiceChunkFlags? {
        ready.isEmpty ? nil : ready.removeFirst()
    }

    // MARK: the clock

    private func tick(_ t: Int64, _ kind: Int) {
        clockNs = t
        rank = kind
        hasClock = true
    }

    private func isLate(_ t: Int64, _ kind: Int) -> Bool {
        hasClock && (t < clockNs || (t == clockNs && kind < rank))
    }

    // MARK: deliveries

    /// Keeps the delivery, or returns the rule that drops it.
    private func offer(_ s: VoiceStatsSnapshot) -> String? {
        if let last = lastKept, last.isSameReport(as: s) {
            return "repeat"
        }
        if s.arriveNs < s.reqNs || s.oldestNs > s.reqNs {
            return "stamps"
        }
        // The position behind every kept snapshot with an earlier or equal request.
        var low = 0
        var high = kept.count
        while low < high {
            let mid = (low + high) / 2
            if kept[mid].s.reqNs <= s.reqNs {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let at = low
        // D1: the kept snapshot just after it in request order is settled behind it.
        if at < kept.count && kept[at].s.reqNs + lateNs < s.arriveNs {
            return "D1"
        }
        let lo = min(s.reqNs - cacheNs, s.oldestNs)
        // D2: the kept brackets never start earlier than their predecessor's in request order.
        if (at > 0 && lo < kept[at - 1].lo) || (at < kept.count && lo > kept[at].lo) {
            return "D2"
        }
        let node = Node(s: s, lo: lo, pos: tapTicks, stale: staleGap)
        if let last = tapLastNs, last >= s.arriveNs {
            node.cov = true
        }
        if hole {
            node.bad = true
            hole = false
        }
        kept.insert(node, at: at)
        lastKept = s
        return nil
    }

    private var firstUnchecked: Int { anchor != nil ? 1 : 0 }

    private func uncheckedNodes() -> ArraySlice<Node> {
        kept[min(firstUnchecked, kept.count)...]
    }

    /// More than `capUnresolved` kept snapshots that wait for an RX block drop the oldest of them like any dropped delivery
    /// (while the tap is silent and deliveries go on they pile up), and the interval that spans it is unknown.
    private func applyCap() {
        var unresolved = 0
        var first = -1
        for i in min(firstUnchecked, kept.count)..<kept.count where kept[i].cov == nil {
            if first < 0 {
                first = i
            }
            unresolved += 1
        }
        peakUnresolved = max(peakUnresolved, min(unresolved, Self.capUnresolved))
        if unresolved <= Self.capUnresolved {
            return
        }
        let dropped = kept.remove(at: first)
        capDroppedCount += 1
        dropListener?(dropped.s, "cap")
        if first < kept.count {
            kept[first].bad = true
        } else {
            hole = true
        }
    }

    // MARK: inputs that reach the stream late

    /// An RX block below the clock by the order of the feed. See the type comment; the clock does not move.
    private func lateRx(_ tNs: Int64) {
        staleGap = true
        offsetTainted = true
        floorTainted = true
        if let p = prev2, p.s.arriveNs >= tNs {
            p.stale = true
        }
        for node in kept where node.s.arriveNs >= tNs {
            node.stale = true
        }
        for node in uncheckedNodes() where node.cov == nil && node.s.arriveNs <= tNs {
            node.cov = true // its position is the one read when it was fed
        }
        var first = -1
        if let bound = pruneNs, tNs <= bound {
            first = 0 // an interval that the block can reach may be gone already: every interval that is left is marked
        } else {
            for i in 0..<track.intervals.count where track.intervals[i].endNs >= tNs {
                first = i
                break
            }
            if first < 0, let a = anchor, a.s.arriveNs >= tNs {
                first = track.intervals.count
            }
        }
        if first >= 0 {
            for i in max(first - 1, 0)..<max(track.intervals.count, max(first - 1, 0)) {
                markUnknown(i)
            }
            if let a = anchor, first <= track.intervals.count {
                a.bad = true
            }
        }
    }

    /// A mute change below the clock, or a lost one: kept at its OWN time (giving it the clock as its time would move an
    /// unmute later, and the speech after it would count as muted). The built intervals that it can reach were built without
    /// it and are marked unknown: every one whose span overlaps [t, u), u the time of the next change in the list (or no
    /// end), which includes one with the change strictly inside it.
    private func insertMute(tNs: Int64, muted: Bool) {
        var low = 0
        var high = mutes.count
        while low < high {
            let mid = (low + high) / 2
            if mutes[mid].tNs <= tNs {
                low = mid + 1
            } else {
                high = mid
            }
        }
        mutes.insert(VoiceMute(tNs: tNs, muted: muted), at: low)
        let next: Int64? = low + 1 < mutes.count ? mutes[low + 1].tNs : nil
        for i in 0..<track.intervals.count {
            let iv = track.intervals[i]
            if iv.endNs > tNs && (next == nil || iv.startNs < (next ?? 0)) {
                markUnknown(i)
            }
        }
    }

    /// Marks a retained interval unknown: every derived column becomes 0.
    private func markUnknown(_ i: Int) {
        if track.intervals[i].known {
            track.intervals[i] = track.intervals[i].asUnknown()
        }
    }

    // MARK: the checked prefix

    private func isSettled(_ node: Node) -> Bool {
        ended || clockNs > node.s.reqNs + lateNs
    }

    private func isResolved(_ node: Node) -> Bool {
        ended || node.cov != nil
    }

    /// Checks the snapshots of the checked prefix that are not checked yet, one at a time.
    private func advance() {
        while kept.count > firstUnchecked {
            let node = kept[firstUnchecked]
            if !(isSettled(node) && isResolved(node)) {
                return
            }
            check(node)
        }
    }

    /// Checks the next snapshot: the tap checks, then the interval that ends at the snapshot before it is built.
    private func check(_ node: Node) {
        let s = node.s
        let previous = anchor
        let k = checkedCount
        let marks = tapStep(s, lo: node.lo, position: node.pos, covered: node.cov == true)
        if marks.own {
            node.bad = true
        }
        if let p = previous, marks.previous {
            p.bad = true
        }
        if node.stale {
            node.bad = true
            previous?.bad = true
        }
        if let p = previous, p.stale {
            node.bad = true
        }
        if k == 0 {
            addInterval(VoiceStatsInterval(
                key: s.reqNs, startNs: node.lo, endNs: s.arriveNs, known: false, isGuard: true))
        } else if let p2 = prev2, let p = previous {
            build(p2, p)
        }
        if previous != nil {
            kept.removeFirst() // the old anchor goes: it is prev2 now, and the new anchor is at index 0
        }
        prev2 = previous
        anchor = node
        checkedCount = k + 1
    }

    /// Builds the interval between the checked snapshots `a` and `b` (the anchor); its checks are done.
    private func build(_ a: Node, _ b: Node) {
        addInterval(make(a.s, b.s, loPrevious: a.lo, tapBad: b.bad))
    }

    private func addInterval(_ interval: VoiceStatsInterval) {
        track.intervals.append(interval)
        intervalListener?(interval)
    }

    // MARK: the tap checks

    /// Whether `ticks` ticks are more than `ns` nanoseconds (3 ticks are exactly 31,250 ns). Exact on integers.
    private static func ticksExceed(_ ticks: Int64, _ ns: Int64) -> Bool {
        if ns < 0 {
            return true
        }
        let product = ticks.magnitude.multipliedReportingOverflow(by: nsPerThreeTicks)
        if product.overflow {
            return true
        }
        let limit = UInt64(ns).multipliedReportingOverflow(by: 3)
        return limit.overflow ? false : product.partialValue > limit.partialValue
    }

    /// The three tap checks for the next kept snapshot, in request order: the offset check (its running maximum, or after a
    /// late RX block the largest offset ever seen, which never restarts), the delta check and the one-ahead comparison, the
    /// last two only against the checked snapshot right before it. `own` marks the interval that ends at this snapshot
    /// unknown, `previous` the one before it. A snapshot without a sample counter, or whose arrival the tap does not cover,
    /// is skipped by all three.
    private func tapStep(
        _ s: VoiceStatsSnapshot, lo: Int64, position: Int64, covered: Bool
    ) -> (own: Bool, previous: Bool) {
        var own = false
        var previous = false
        guard let total = s.totalSamples, covered else {
            tapPrevious = nil
            return (own: false, previous: false)
        }
        let scaled = total.multipliedReportingOverflow(by: ticksPerSample)
        if scaled.overflow {
            tapPrevious = nil
            return (own: false, previous: false)
        }
        let wide = s.arriveNs - lo
        let b = scaled.partialValue &- position
        var maximum = offsetMax
        if offsetTainted, let sup = offsetSup {
            if Self.ticksExceed(max(sup &- b, 0), wide + slackNs) {
                own = true
            }
        } else if let m = maximum {
            if Self.ticksExceed(max(m &- b, 0), wide + slackNs) {
                own = true
                maximum = b
            } else {
                maximum = max(m, b)
            }
        } else {
            maximum = b
        }
        offsetSup = offsetSup.map { max($0, b) } ?? b
        if let p = tapPrevious {
            let x = (total &- p.total) &* ticksPerSample &- (position &- p.position) // B(k) - B(k-1)
            if Self.ticksExceed(x, wide + p.wide + slackNs) {
                own = true
            }
            if x > 0 && Self.ticksExceed(x, p.wide + slackNs) {
                previous = true
            }
        }
        offsetMax = maximum
        tapPrevious = TapPrevious(total: total, position: position, wide: wide)
        return (own: own, previous: previous)
    }

    // MARK: the intervals

    /// Interval `[lo(k-1), arrive(k))` between the kept snapshots `a` (k - 1) and `b` (k), with the TX floor carried from
    /// the interval before it. `tapBad`: the tap checks (or the stale rule, or the cap) mark it unknown.
    private func make(
        _ a: VoiceStatsSnapshot, _ b: VoiceStatsSnapshot, loPrevious: Int64, tapBad: Bool
    ) -> VoiceStatsInterval {
        let deltas = VoiceCounterDeltas.between(a, b)
        var known = false
        if let d = deltas {
            known = b.arriveNs - b.reqNs <= lateNs
                && b.reqNs > a.reqNs
                && b.rxSsrc == a.rxSsrc
                && b.arriveNs - loPrevious <= spanNs
                && d.txDurationS <= txSpanS
                && !tapBad
            lowerFloor(a, b, d)
        }
        let start = loPrevious
        let end = b.arriveNs
        guard known, let d = deltas else {
            return VoiceStatsInterval(key: b.reqNs, startNs: start, endNs: end, known: false, isGuard: false)
        }
        var iv = VoiceStatsInterval(key: b.reqNs, startNs: start, endNs: end, known: true, isGuard: false)
        iv.audible = d.concealed - d.silentConcealed
        iv.silent = d.silentConcealed
        iv.events = d.events
        iv.conc = iv.audible > 0 || iv.events > 0
        iv.total = d.totalSamples
        iv.stretch = d.stretch
        iv.jbS = d.jbEmitted > 0 ? d.jbDelayS / Double(d.jbEmitted) : 0.0
        let rtt = b.rttRemoteS ?? b.rttPairS ?? 0.0
        iv.rttS = rtt
        let preMs = min(max(1000.0 * (rtt + iv.jbS) + tx.remoteMarginMs, tx.preMsFloor), tx.preMsCap)
        iv.preNs = Int64((preMs * 1_000_000.0 + 0.5).rounded(.down))
        iv.pTx = d.txDurationS > 0 ? d.txEnergy / d.txDurationS : 0.0
        let pdb = 10.0 * log10(max(iv.pTx, Self.txPowerFloor))
        let dt = Double(b.arriveNs - a.arriveNs) / 1e9
        var level: Double
        if let current = floorDb {
            level = pdb < current ? pdb : current + tx.riseDbPerS * dt
        } else {
            level = pdb
        }
        floorDb = level
        if floorTainted {
            level = floorLow ?? level // a late RX block was seen: the lowest floor any feed can have
        }
        iv.muted = mutedWhole(start: start, end: end)
        iv.txActive = !iv.muted && pdb >= level + tx.marginDb && pdb >= tx.floorDbfs
        return iv
    }

    /// The lowest floor that any feed can have: the TX floor chain over EVERY interval with counters, known or not, in which
    /// the floor only falls (a rise by the elapsed time is dropped, a fall by a negative elapsed time is kept). It is never
    /// above the floor of the feed in order.
    private func lowerFloor(_ a: VoiceStatsSnapshot, _ b: VoiceStatsSnapshot, _ d: VoiceCounterDeltas) {
        let power = d.txDurationS > 0 ? d.txEnergy / d.txDurationS : 0.0
        let pdb = 10.0 * log10(max(power, Self.txPowerFloor))
        if let current = floorLow, pdb >= current {
            floorLow = current + min(tx.riseDbPerS * (Double(b.arriveNs - a.arriveNs) / 1e9), 0.0)
        } else {
            floorLow = pdb
        }
    }

    /// Whether `[start, end)` is muted whole: muted at its start (the last change at or before it) and no unmute strictly
    /// inside.
    private func mutedWhole(start: Int64, end: Int64) -> Bool {
        var state = false
        for m in mutes where m.tNs <= start {
            state = m.muted
        }
        if !state {
            return false
        }
        for m in mutes where m.tNs > start && m.tNs < end && !m.muted {
            return false
        }
        return true
    }

    // MARK: release

    /// H = lo(p - 2), or nil when fewer than two snapshots are checked.
    private func horizon() -> Int64? {
        checkedCount >= 2 ? prev2?.lo : nil
    }

    /// Releases every chunk that is final after the latest input, or overdue, at the clock of that input, then forgets what no
    /// waiting chunk can reach.
    private func release() {
        if let head = pending.first {
            var h: Int64?
            if !ended && clockNs > head.t1 + max(widenNs, postNs) {
                h = horizon()
            }
            while let c = pending.first {
                let overdue: Bool
                if ended || (h != nil && (h ?? 0) >= c.t1 + widenNs && (h ?? 0) > c.t1 + postNs) {
                    overdue = false
                } else if clockNs >= c.t1 + overdueNs {
                    overdue = true
                } else {
                    break
                }
                pending.removeFirst()
                if overdue {
                    ready.append(VoiceChunkFlags(
                        index: c.index, excluded: false, txUnknown: true, concUnknown: true, touchConcealment: false,
                        touchStretch: false, overlaps: [], releaseNs: clockNs, overdue: true))
                    continue
                }
                let media = mediaStartNs ?? Int64.min
                let txFlags = track.txFlags(t0: c.t0, t1: c.t1, mediaStart: media)
                let concFlags = track.concFlags(t0: c.t0, t1: c.t1, mediaStart: media)
                ready.append(VoiceChunkFlags(
                    index: c.index, excluded: txFlags.excluded, txUnknown: txFlags.unknown,
                    concUnknown: concFlags.unknown, touchConcealment: concFlags.concealment,
                    touchStretch: concFlags.stretch, overlaps: track.overlappingKnown(t0: c.t0, t1: c.t1),
                    releaseNs: clockNs, overdue: false))
            }
        }
        prune()
    }

    /// Forgets what no chunk that is waiting or still to come can reach: the built intervals that end at or before the start
    /// of the oldest waiting chunk (the end of the last chunk when none waits) minus the longest look-back, and the mute
    /// changes before the horizon but the last of them.
    private func prune() {
        let reference: Int64? = pending.first?.t0 ?? lastChunkEndNs ?? mediaStartNs
        if let r = reference {
            let theta = r - max(preCapNs, widenNs)
            pruneNs = pruneNs.map { max($0, theta) } ?? theta
            track.intervals.removeAll { $0.endNs <= theta }
        }
        if let h = horizon() {
            var j = -1
            for i in 0..<mutes.count {
                if mutes[i].tNs <= h {
                    j = i
                } else {
                    break
                }
            }
            if j > 0 {
                mutes.removeSubrange(0..<j)
            }
        }
        peakKept = max(peakKept, kept.count)
        peakIntervals = max(peakIntervals, track.intervals.count)
        peakMutes = max(peakMutes, mutes.count)
        peakPending = max(peakPending, pending.count)
    }
}

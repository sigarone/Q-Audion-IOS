import Foundation

/// One delivered report of the 1 s stats poll. All times are tap-clock nanoseconds except `reportNs`, which is only
/// used to recognise an exact duplicate. A counter that the report did not carry is nil.
struct VoiceStatsSnapshot: Equatable {
    /// The clock just before the call was issued, at the start of its callback, and the oldest request still
    /// outstanding when the call was issued (never later than `reqNs`).
    var reqNs: Int64
    var arriveNs: Int64
    var oldestNs: Int64
    var reportNs: Int64
    var rxSsrc: Int64?
    var concealed: Int64?
    var silentConcealed: Int64?
    var concealmentEvents: Int64?
    var totalSamples: Int64?
    var insertedDecel: Int64?
    var removedAccel: Int64?
    var jbDelayS: Double?
    var jbEmitted: Int64?
    var txEnergy: Double?
    var txDurationS: Double?
    var rttRemoteS: Double?
    var rttPairS: Double?

    /// The same report delivered again: same report timestamp and the same ten counters.
    func isSameReport(as other: VoiceStatsSnapshot) -> Bool {
        reportNs == other.reportNs
            && concealed == other.concealed
            && silentConcealed == other.silentConcealed
            && concealmentEvents == other.concealmentEvents
            && totalSamples == other.totalSamples
            && insertedDecel == other.insertedDecel
            && removedAccel == other.removedAccel
            && jbDelayS == other.jbDelayS
            && jbEmitted == other.jbEmitted
            && txEnergy == other.txEnergy
            && txDurationS == other.txDurationS
    }
}

/// A mute change at a tap-clock time.
struct VoiceMute: Equatable {
    var tNs: Int64
    var muted: Bool
}

/// Counter differences between two snapshots.
struct VoiceCounterDeltas {
    var concealed: Int64
    var silentConcealed: Int64
    var events: Int64
    var totalSamples: Int64
    var stretch: Int64
    var jbDelayS: Double
    var jbEmitted: Int64
    var txEnergy: Double
    var txDurationS: Double

    /// Nil when a counter is missing in either snapshot, one went backwards, or silent concealment exceeds concealment.
    static func between(_ a: VoiceStatsSnapshot, _ b: VoiceStatsSnapshot) -> VoiceCounterDeltas? {
        guard let c0 = a.concealed, let c1 = b.concealed,
              let s0 = a.silentConcealed, let s1 = b.silentConcealed,
              let e0 = a.concealmentEvents, let e1 = b.concealmentEvents,
              let t0 = a.totalSamples, let t1 = b.totalSamples,
              let d0 = a.insertedDecel, let d1 = b.insertedDecel,
              let r0 = a.removedAccel, let r1 = b.removedAccel,
              let jd0 = a.jbDelayS, let jd1 = b.jbDelayS,
              let je0 = a.jbEmitted, let je1 = b.jbEmitted,
              let x0 = a.txEnergy, let x1 = b.txEnergy,
              let u0 = a.txDurationS, let u1 = b.txDurationS else {
            return nil
        }
        let concealed = c1 - c0
        let silent = s1 - s0
        let events = e1 - e0
        let total = t1 - t0
        let decel = d1 - d0
        let accel = r1 - r0
        let jbDelay = jd1 - jd0
        let jbEmitted = je1 - je0
        let energy = x1 - x0
        let duration = u1 - u0
        if concealed < 0 || silent < 0 || events < 0 || total < 0 || decel < 0 || accel < 0 || jbDelay < 0
            || jbEmitted < 0 || energy < 0 || duration < 0 {
            return nil
        }
        if silent > concealed {
            return nil
        }
        return VoiceCounterDeltas(
            concealed: concealed,
            silentConcealed: silent,
            events: events,
            totalSamples: total,
            stretch: decel + accel,
            jbDelayS: jbDelay,
            jbEmitted: jbEmitted,
            txEnergy: energy,
            txDurationS: duration
        )
    }
}

/// The span between two samples of the counters, with what the window assembler needs from it.
struct VoiceStatsInterval {
    /// Identifies the interval (the request stamp of the snapshot that closes it); unique among known intervals.
    var key: Int64
    var startNs: Int64
    var endNs: Int64
    var known: Bool
    var isGuard: Bool
    var audible: Int64 = 0
    var silent: Int64 = 0
    var events: Int64 = 0
    var conc: Bool = false
    var total: Int64 = 0
    var stretch: Int64 = 0
    var jbS: Double = 0
    var rttS: Double = 0
    var preNs: Int64 = 0
    var pTx: Double = 0
    var muted: Bool = false
    var txActive: Bool = false
}

/// What a window needs to remember of a known interval that overlaps one of its chunks.
struct VoiceIntervalRef: Equatable {
    var key: Int64
    var audible: Int64
    var total: Int64
    var conc: Bool
    var stretch: Int64
}

/// The tap position as a step function of the tap clock: cumulative ticks of the last block called at or before a time.
struct VoiceTapTrack {
    private(set) var times: [Int64] = []
    private(set) var ticks: [Int64] = []

    var lastTimeNs: Int64? { times.last }

    mutating func append(tNs: Int64, ticks position: Int64) {
        if let last = times.last, tNs < last {
            let at = VoiceSearch.upperBound(times, tNs)
            times.insert(tNs, at: at)
            ticks.insert(position, at: at)
        } else {
            times.append(tNs)
            ticks.append(position)
        }
    }

    /// Position after the last block called at or before `t` (0 before the first block).
    func position(at t: Int64) -> Int64 {
        let i = VoiceSearch.upperBound(times, t)
        return i == 0 ? 0 : ticks[i - 1]
    }

    /// False after the last block: the tap ended and there is nothing to compare with.
    func covers(_ t: Int64) -> Bool {
        guard let last = times.last else { return false }
        return t <= last
    }
}

/// Binary searches over sorted values: first index whose value is not below / above the key.
enum VoiceSearch {
    static func lowerBound(_ values: [Int64], _ key: Int64) -> Int {
        var low = 0
        var high = values.count
        while low < high {
            let mid = (low + high) / 2
            if values[mid] < key {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    static func upperBound(_ values: [Int64], _ key: Int64) -> Int {
        var low = 0
        var high = values.count
        while low < high {
            let mid = (low + high) / 2
            if values[mid] <= key {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}

/// The intervals of one call, the tap cross-checks that can invalidate them, and the per-chunk flags read from them.
struct VoiceStatsTrack {
    /// Tap position unit: ticks of 1/96,000 s, exact for every supported tap rate.
    static let tickRate = 96_000
    private static let nsPerThreeTicks: Int64 = 31_250
    private static let txPowerFloor = 1e-12

    private(set) var intervals: [VoiceStatsInterval]
    private let widenNs: Int64
    private let postNs: Int64
    private let preFloorNs: Int64
    private var order: [Int] = []
    private var starts: [Int64] = []
    private var maxEnds: [Int64] = []

    /// Request-stamp bound of the interval a snapshot opens: the earliest the counters of the snapshot can have been
    /// sampled.
    static func lowerBoundNs(_ snapshot: VoiceStatsSnapshot, gates: VoiceConstants.Gates) -> Int64 {
        let cache = Int64(gates.stats.cacheMs) * 1_000_000
        return min(snapshot.reqNs - cache, snapshot.oldestNs)
    }

    /// Whether `ticks` ticks are more than `ns` nanoseconds (3 ticks are exactly 31,250 ns).
    private static func ticksExceed(_ ticks: Int64, _ ns: Int64) -> Bool {
        abs(ticks) * nsPerThreeTicks > ns * 3
    }

    /// Indices (into `snapshots`) whose interval the tap cross-checks mark unknown. A snapshot without a sample counter,
    /// or one that arrives after the last tap block, is skipped, and the neighbour checks do not look across it.
    static func tapDiscontinuities(
        snapshots: [VoiceStatsSnapshot],
        lower: [Int64],
        tap: VoiceTapTrack,
        stats: VoiceConstants.Gates.Stats
    ) -> Set<Int> {
        var bad = Set<Int>()
        let ticksPerSample = Int64(tickRate / stats.rxRateHz)
        let slack = Int64(stats.tapLagMs + stats.tapTolMs) * 1_000_000
        var maximum: Int64?
        var previous: (total: Int64, position: Int64, wide: Int64, index: Int)?
        for k in 0..<snapshots.count {
            let s = snapshots[k]
            guard let total = s.totalSamples, tap.covers(s.arriveNs) else {
                previous = nil
                continue
            }
            let position = tap.position(at: s.arriveNs)
            let wide = s.arriveNs - lower[k]
            let b = total * ticksPerSample - position
            if let m = maximum {
                if ticksExceed(max(m - b, 0), wide + slack) {
                    bad.insert(k)
                    maximum = b
                } else {
                    maximum = max(m, b)
                }
            } else {
                maximum = b
            }
            if let p = previous {
                let x = (total - p.total) * ticksPerSample - (position - p.position)
                if ticksExceed(x, wide + p.wide + slack) {
                    bad.insert(k)
                }
                if x > 0 && ticksExceed(x, p.wide + slack) {
                    bad.insert(p.index)
                }
            }
            previous = (total: total, position: position, wide: wide, index: k)
        }
        return bad
    }

    /// The echo look-back in ms from the round trip and the jitter-buffer delay (both in seconds).
    private static func echoLookBackMs(rttS: Double, jbS: Double, tx: VoiceConstants.Gates.Tx) -> Double {
        min(max(1000.0 * (rttS + jbS) + tx.remoteMarginMs, tx.preMsFloor), tx.preMsCap)
    }

    private static func roundHalfUp(_ x: Double) -> Int64 {
        Int64((x + 0.5).rounded(.down))
    }

    /// Builds the track from snapshots in request order, their lower bounds and the set of intervals the tap
    /// cross-checks invalidated.
    init(
        snapshots: [VoiceStatsSnapshot],
        lower: [Int64],
        tapBad: Set<Int>,
        mutes: [VoiceMute],
        gates: VoiceConstants.Gates
    ) {
        let st = gates.stats
        let tx = gates.tx
        widenNs = Int64(st.widenMs) * 1_000_000
        postNs = Int64(tx.postMs) * 1_000_000
        preFloorNs = Int64(tx.preMsFloor) * 1_000_000
        let lateNs = Int64(st.lateMs) * 1_000_000
        let spanNs = Int64(st.spanMs) * 1_000_000
        let txSpanS = st.txSpanMs / 1000.0
        let sortedMutes = mutes.enumerated().sorted { a, b in
            a.element.tNs != b.element.tNs ? a.element.tNs < b.element.tNs : a.offset < b.offset
        }.map { $0.element }

        var list: [VoiceStatsInterval] = []
        if let first = snapshots.first {
            list.append(VoiceStatsInterval(
                key: first.reqNs, startNs: lower[0], endNs: first.arriveNs, known: false, isGuard: true))
        }
        var floorDb: Double?
        if snapshots.count > 1 {
            for k in 1..<snapshots.count {
                let a = snapshots[k - 1]
                let b = snapshots[k]
                let deltas = VoiceCounterDeltas.between(a, b)
                var known = false
                if let d = deltas {
                    known = b.arriveNs - b.reqNs <= lateNs
                        && b.reqNs > a.reqNs
                        && b.rxSsrc == a.rxSsrc
                        && b.arriveNs - lower[k - 1] <= spanNs
                        && d.txDurationS <= txSpanS
                        && !tapBad.contains(k)
                }
                let start = lower[k - 1]
                let end = b.arriveNs
                var iv = VoiceStatsInterval(key: b.reqNs, startNs: start, endNs: end, known: known, isGuard: false)
                if known, let d = deltas {
                    iv.audible = d.concealed - d.silentConcealed
                    iv.silent = d.silentConcealed
                    iv.events = d.events
                    iv.conc = iv.audible > 0 || iv.events > 0
                    iv.total = d.totalSamples
                    iv.stretch = d.stretch
                    iv.jbS = d.jbEmitted > 0 ? d.jbDelayS / Double(d.jbEmitted) : 0.0
                    var rtt = 0.0
                    if let remote = b.rttRemoteS {
                        rtt = remote
                    } else if let pair = b.rttPairS {
                        rtt = pair
                    }
                    iv.rttS = rtt
                    let preMs = Self.echoLookBackMs(rttS: rtt, jbS: iv.jbS, tx: tx)
                    iv.preNs = Self.roundHalfUp(preMs * 1_000_000.0)
                    iv.pTx = d.txDurationS > 0 ? d.txEnergy / d.txDurationS : 0.0
                    let pdb = 10.0 * log10(max(iv.pTx, Self.txPowerFloor))
                    let dt = Double(b.arriveNs - a.arriveNs) / 1e9
                    if let current = floorDb {
                        floorDb = pdb < current ? pdb : current + tx.riseDbPerS * dt
                    } else {
                        floorDb = pdb
                    }
                    let level = floorDb ?? pdb
                    iv.muted = Self.mutedWhole(sortedMutes, start: start, end: end)
                    iv.txActive = !iv.muted && pdb >= level + tx.marginDb && pdb >= tx.floorDbfs
                }
                list.append(iv)
            }
            let n = snapshots.count - 1
            list.append(VoiceStatsInterval(
                key: snapshots[n].reqNs, startNs: lower[n], endNs: snapshots[n].arriveNs, known: false, isGuard: true))
        }
        intervals = list
        buildIndex()
    }

    /// A track from given intervals (the window vector): only the concealment side is used.
    init(intervals given: [VoiceStatsInterval], gates: VoiceConstants.Gates) {
        widenNs = Int64(gates.stats.widenMs) * 1_000_000
        postNs = Int64(gates.tx.postMs) * 1_000_000
        preFloorNs = Int64(gates.tx.preMsFloor) * 1_000_000
        var list = given
        for i in 0..<list.count {
            list[i].key = Int64(i + 1)
            if list[i].known {
                list[i].conc = list[i].audible > 0 || list[i].events > 0
            }
        }
        intervals = list
        buildIndex()
    }

    private static func mutedWhole(_ mutes: [VoiceMute], start: Int64, end: Int64) -> Bool {
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

    // MARK: spans

    /// Spans may overlap and their ends need not grow with their starts, so the intervals are kept ordered by start with
    /// a running maximum of the ends.
    private mutating func buildIndex() {
        let ivs = intervals
        order = (0..<ivs.count).sorted { a, b in
            ivs[a].startNs != ivs[b].startNs ? ivs[a].startNs < ivs[b].startNs : a < b
        }
        starts = order.map { ivs[$0].startNs }
        var running: Int64?
        var maxima: [Int64] = []
        for i in order {
            let e = ivs[i].endNs
            if let r = running, r >= e {
                maxima.append(r)
            } else {
                running = e
                maxima.append(e)
            }
        }
        maxEnds = maxima
    }

    /// Indices of the intervals whose span, widened by `widen` on both sides, overlaps [q0, q1), ordered by start.
    private func overlapping(_ q0: Int64, _ q1: Int64, widen: Int64) -> [Int] {
        let high = VoiceSearch.lowerBound(starts, q1 + widen)
        let low = VoiceSearch.upperBound(maxEnds, q0 - widen)
        if low >= high {
            return []
        }
        var out: [Int] = []
        for position in low..<high {
            let i = order[position]
            if intervals[i].endNs + widen > q0 {
                out.append(i)
            }
        }
        return out
    }

    /// Whether [q0, q1) lies inside the union of the intervals (all of them known when `requireKnown`).
    private func covered(_ q0: Int64, _ q1: Int64, requireKnown: Bool) -> Bool {
        if q1 <= q0 {
            return true
        }
        let hits = overlapping(q0, q1, widen: 0)
        var cursor = q0
        for i in hits {
            if intervals[i].startNs > cursor {
                return false
            }
            cursor = max(cursor, intervals[i].endNs)
        }
        if cursor < q1 {
            return false
        }
        if requireKnown {
            return hits.allSatisfy { intervals[$0].known }
        }
        return true
    }

    // MARK: per-chunk flags

    /// (excluded as double talk, TX unknown) for a chunk spanning [t0, t1).
    func txFlags(t0: Int64, t1: Int64, mediaStart: Int64) -> (excluded: Bool, unknown: Bool) {
        let e = t1 + postNs
        let atE = overlapping(e, e + 1, widen: 0)
        var pre = preFloorNs
        var unknown = true
        if !atE.isEmpty && atE.allSatisfy({ intervals[$0].known }) {
            pre = atE.map { intervals[$0].preNs }.max() ?? preFloorNs
            unknown = false
        }
        let q0 = t0 - pre
        var excluded = false
        for i in overlapping(q0, e, widen: 0) where intervals[i].known && intervals[i].txActive {
            excluded = true
            break
        }
        if !covered(max(q0, mediaStart), e, requireKnown: true) {
            unknown = true
        }
        return (excluded: excluded, unknown: unknown)
    }

    /// (concealment unknown, touches concealment, touches time-stretch) for a chunk spanning [t0, t1).
    func concFlags(t0: Int64, t1: Int64, mediaStart: Int64) -> (unknown: Bool, concealment: Bool, stretch: Bool) {
        var unknown = false
        var concealment = false
        var stretch = false
        for i in overlapping(t0, t1, widen: widenNs) {
            let iv = intervals[i]
            if !iv.known {
                unknown = true
            } else {
                if iv.conc {
                    concealment = true
                }
                if iv.stretch > 0 {
                    stretch = true
                }
            }
        }
        if !covered(max(t0, mediaStart), t1, requireKnown: false) {
            unknown = true
        }
        return (unknown: unknown, concealment: concealment, stretch: stretch)
    }

    /// The known intervals whose widened span overlaps [t0, t1).
    func overlappingKnown(t0: Int64, t1: Int64) -> [VoiceIntervalRef] {
        var out: [VoiceIntervalRef] = []
        for i in overlapping(t0, t1, widen: widenNs) where intervals[i].known {
            let iv = intervals[i]
            out.append(VoiceIntervalRef(
                key: iv.key, audible: iv.audible, total: iv.total, conc: iv.conc, stretch: iv.stretch))
        }
        return out
    }
}

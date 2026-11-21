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

extension VoiceStatsInterval {
    /// The same span as an unknown interval: every derived column is 0.
    func asUnknown() -> VoiceStatsInterval {
        VoiceStatsInterval(key: key, startNs: startNs, endNs: endNs, known: false, isGuard: isGuard)
    }
}

/// A list of intervals and the per-chunk flags read from it. The stream keeps the few intervals that a waiting chunk can
/// still reach (nine or so at one report per second), so the queries scan the list.
struct VoiceStatsTrack {
    /// Tap position unit: ticks of 1/96,000 s, exact for every supported tap rate.
    static let tickRate = 96_000

    var intervals: [VoiceStatsInterval] = []
    private let widenNs: Int64
    private let postNs: Int64
    private let preFloorNs: Int64

    init(gates: VoiceConstants.Gates) {
        widenNs = Int64(gates.stats.widenMs) * 1_000_000
        postNs = Int64(gates.tx.postMs) * 1_000_000
        preFloorNs = Int64(gates.tx.preMsFloor) * 1_000_000
    }

    /// A track from given intervals (the window vector): only the concealment side is used.
    init(intervals given: [VoiceStatsInterval], gates: VoiceConstants.Gates) {
        self.init(gates: gates)
        var list = given
        for i in 0..<list.count {
            list[i].key = Int64(i + 1)
            if list[i].known {
                list[i].conc = list[i].audible > 0 || list[i].events > 0
            }
        }
        intervals = list
    }

    // MARK: spans

    /// Indices of the intervals whose span, widened by `widen` on both sides, overlaps [q0, q1), ordered by start (a tie
    /// keeps the order of the list).
    private func overlapping(_ q0: Int64, _ q1: Int64, widen: Int64) -> [Int] {
        var out: [Int] = []
        for i in 0..<intervals.count where intervals[i].startNs - widen < q1 && intervals[i].endNs + widen > q0 {
            out.append(i)
        }
        if out.count > 1 {
            out.sort { a, b in
                intervals[a].startNs != intervals[b].startNs ? intervals[a].startNs < intervals[b].startNs : a < b
            }
        }
        return out
    }

    /// Whether [q0, q1) lies inside the union of the intervals as they are stored (all of them known when `requireKnown`).
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

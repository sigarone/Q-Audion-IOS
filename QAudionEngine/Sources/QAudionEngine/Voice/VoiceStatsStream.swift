import Foundation

/// The stats track of a call as it grows: snapshots, tap blocks and mute changes arrive one at a time, and a chunk's
/// flags are read once the inputs that can still change them have been seen.
///
/// A chunk's flags are final when every interval that can reach it is settled: its own counters were sampled at
/// instants fixed by the snapshots that bound it, the tap checks of the snapshot after it have run, and no delivery that
/// has not arrived yet can still be slotted in before that snapshot. The last holds because a delivery that would be
/// ordered in front of a settled snapshot (one whose request is more than `late_ms` behind the clock) is dropped on
/// arrival: a delivery that late is unusable in any case, and dropping a snapshot is always safe, the next interval
/// just spans it. A delivery that is later than `late_ms` is otherwise kept, and its own interval is unknown.
final class VoiceStatsStream {
    private let gates: VoiceConstants.Gates
    private let lateNs: Int64
    private var tap = VoiceTapTrack()
    private var mutes: [VoiceMute] = []
    private var lastKept: VoiceStatsSnapshot?
    private var ordered: [VoiceStatsSnapshot] = []
    private var lowerBounds: [Int64] = []
    private var ended = false
    private var evaluated = 0
    private var clockNs: Int64?

    /// The track as of the inputs seen so far. Its tap checks have run only for the first snapshots whose arrival the
    /// tap has passed.
    private(set) var track: VoiceStatsTrack

    init(gates: VoiceConstants.Gates) {
        self.gates = gates
        self.lateNs = Int64(gates.stats.lateMs) * 1_000_000
        self.track = VoiceStatsTrack(snapshots: [], lower: [], tapBad: [], mutes: [], gates: gates)
    }

    /// Number of snapshots kept after dropping duplicates, malformed deliveries and deliveries that arrive too late
    /// to be slotted in.
    var keptCount: Int { ordered.count }

    /// One delivered report. An exact repeat of the previous kept delivery, or one whose stamps cannot be right
    /// (arrival before the request, oldest request after the request), is dropped; so is one whose request orders it in
    /// front of a snapshot that is already settled. The rest are ordered by request.
    func addSnapshot(_ snapshot: VoiceStatsSnapshot) {
        advance(to: snapshot.arriveNs)
        if let previous = lastKept, previous.isSameReport(as: snapshot) {
            return
        }
        if snapshot.arriveNs < snapshot.reqNs || snapshot.oldestNs > snapshot.reqNs {
            return
        }
        let at = ordered.firstIndex { $0.reqNs > snapshot.reqNs } ?? ordered.count
        if at < ordered.count, isSettled(ordered[at]) {
            return
        }
        lastKept = snapshot
        ordered.insert(snapshot, at: at)
        rebuild()
    }

    /// One RX block as the tap callback counted it: the tap clock of the callback and the cumulative tap position
    /// after the block, in ticks of 1/96,000 s.
    func addTapBlock(tNs: Int64, ticks: Int64) {
        advance(to: tNs)
        tap.append(tNs: tNs, ticks: ticks)
        if evaluated < ordered.count, let last = tap.lastTimeNs, ordered[evaluated].arriveNs < last {
            rebuild()
        }
    }

    func addMute(tNs: Int64, muted: Bool) {
        advance(to: tNs)
        mutes.append(VoiceMute(tNs: tNs, muted: muted))
        rebuild()
    }

    /// The call ended: the tap has no more blocks, so every remaining check runs and every chunk is final.
    func finish() {
        ended = true
        rebuild()
    }

    /// Concealment flags of a chunk ending at `t1` are final.
    func isConcealmentFinal(t1: Int64) -> Bool {
        if ended {
            return true
        }
        guard let horizon = settledHorizon() else { return false }
        return t1 + Int64(gates.stats.widenMs) * 1_000_000 <= horizon
    }

    /// TX flags of a chunk ending at `t1` are final.
    func isTxFinal(t1: Int64) -> Bool {
        if ended {
            return true
        }
        guard let horizon = settledHorizon() else { return false }
        return t1 + Int64(gates.tx.postMs) * 1_000_000 < horizon
    }

    private func advance(to t: Int64) {
        if let current = clockNs, current >= t {
            return
        }
        clockNs = t
    }

    /// A snapshot is settled when its request is more than `late_ms` behind the clock: a delivery that would be ordered
    /// in front of it is dropped, so it never gets a new predecessor.
    private func isSettled(_ snapshot: VoiceStatsSnapshot) -> Bool {
        guard let clock = clockNs else { return false }
        return snapshot.reqNs + lateNs < clock
    }

    /// Every interval that can still change starts at or after this instant. Snapshot m is the last one whose tap checks
    /// have run, and snapshot s the last settled one (no unseen delivery is slotted in front of it); intervals before
    /// the one that snapshot min(m, s) closes are settled.
    private func settledHorizon() -> Int64? {
        guard clockNs != nil else { return nil }
        var low = 0
        var high = ordered.count
        while low < high {
            let mid = (low + high) / 2
            if isSettled(ordered[mid]) {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let settled = low - 1
        let j = min(evaluated - 1, settled)
        return j >= 1 ? lowerBounds[j - 1] : nil
    }

    private func rebuild() {
        let lower = ordered.map { VoiceStatsTrack.lowerBoundNs($0, gates: gates) }
        var count = 0
        if ended {
            count = ordered.count
        } else if let last = tap.lastTimeNs {
            while count < ordered.count && ordered[count].arriveNs < last {
                count += 1
            }
        }
        let bad = VoiceStatsTrack.tapDiscontinuities(
            snapshots: Array(ordered[0..<count]),
            lower: Array(lower[0..<count]),
            tap: tap,
            stats: gates.stats
        )
        track = VoiceStatsTrack(snapshots: ordered, lower: lower, tapBad: bad, mutes: mutes, gates: gates)
        lowerBounds = lower
        evaluated = count
    }
}

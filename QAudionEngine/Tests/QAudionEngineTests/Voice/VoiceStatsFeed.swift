import XCTest
import Foundation
@testable import QAudionEngine

/// The feed of a stats vector case: the inputs of a case in the order in which the stats stream is fed. RX blocks, mute
/// changes and deliveries go in by tap-clock time (at the same time in that order, each kind in the order of its list); the
/// inputs that the `late` entries of a case say reach the engine late or never are put after the inputs that the worker has
/// fed by then (the inputs with a time below `reach - hold`).
enum VoiceStatsFeed {
    // The kinds of input, in the order of inputs at the same time.
    static let rx = 0
    static let mute = 1
    static let delivery = 2
    /// The marker of a mute change that was lost (a late unmute at the time of the change ahead of it).
    static let lost = 4

    /// One input to feed. `late` is true when it is offered after the clock may have passed it.
    struct Step {
        var late: Bool
        var kind: Int
        var tNs: Int64
        var ticks: Int64 = 0
        var muted = false
        var snapshot: VoiceStatsSnapshot?
    }

    private struct Event {
        var t: Int64
        var kind: Int
        var order: Double
        var step: Step
    }

    private struct Pend {
        var cut: Int64
        var rank: Int
        var order: Double
        var step: Step
    }

    private struct Key: Hashable {
        var kind: Int
        var index: Int
    }

    private struct LateEntry {
        var reachNs: Int64
        var lost: Bool
    }

    private static func precedes(_ a: Event, _ b: Event) -> Bool {
        if a.t != b.t { return a.t < b.t }
        if a.kind != b.kind { return a.kind < b.kind }
        return a.order < b.order
    }

    /// The tap blocks of a case: block j of a run is called at `t_ns + j period_ns` and ends at position `ticks + j step`.
    static func tapBlocks(_ testCase: KatJSON) -> [(t: Int64, ticks: Int64)] {
        var out: [(t: Int64, ticks: Int64)] = []
        for run in testCase["tap"].array {
            for j in 0..<run["n"].int {
                out.append((
                    t: run["t_ns"].int64 + Int64(j) * run["period_ns"].int64,
                    ticks: run["ticks"].int64 + Int64(j) * run["step"].int64))
            }
        }
        return out
    }

    /// The inputs of a case, `late` entries applied; the end of the call is not in the list.
    static func sequence(
        _ testCase: KatJSON, snapshots: [VoiceStatsSnapshot], mediaStartNs: Int64, holdNs: Int64
    ) -> [Step] {
        let blocks = tapBlocks(testCase)
        let mutes = testCase["mutes"].array.map { (t: $0["t_ns"].int64, muted: $0["muted"].flag) }
        var events: [Event] = []
        for (i, b) in blocks.enumerated() {
            events.append(Event(t: b.t, kind: rx, order: Double(i), step: Step(late: false, kind: rx, tNs: b.t, ticks: b.ticks)))
        }
        for (i, m) in mutes.enumerated() {
            events.append(Event(t: m.t, kind: mute, order: Double(i), step: Step(late: false, kind: mute, tNs: m.t, muted: m.muted)))
        }
        for (i, s) in snapshots.enumerated() {
            events.append(Event(
                t: s.arriveNs, kind: delivery, order: Double(i),
                step: Step(late: false, kind: delivery, tNs: s.arriveNs, snapshot: s)))
        }
        events.sort(by: precedes)

        var entries: [Key: LateEntry] = [:]
        for e in testCase["late"].array {
            let kind: Int
            switch e["kind"].string {
            case "rx": kind = rx
            case "mute": kind = mute
            case "delivery": kind = delivery
            default:
                XCTFail("late kind \(e["kind"].string)")
                continue
            }
            let lostFlag = e["lost"].isNull ? false : e["lost"].flag
            entries[Key(kind: kind, index: e["index"].int)] = LateEntry(reachNs: e["reach_ns"].int64, lost: lostFlag)
        }

        var seq: [Event] = []
        var pend: [Pend] = []
        var queueReach: Int64? // the instant at which the latest mute change that was held up reaches the engine
        for e in events {
            let index = Int(e.order)
            let hit = entries[Key(kind: e.kind, index: index)]
            var reach: Int64?
            if let h = hit, !h.lost {
                reach = h.reachNs
                XCTAssertGreaterThanOrEqual(h.reachNs, e.t, "an input cannot reach the engine before its time")
            }
            if e.kind == mute, let q = queueReach {
                reach = reach.map { max($0, q) } ?? q
            }
            if let h = hit, h.lost {
                XCTAssertEqual(e.kind, mute, "only a mute change can be lost")
                let tm = index > 0 ? mutes[index - 1].t : mediaStartNs
                var rLoss = h.reachNs
                if let q = queueReach {
                    rLoss = max(rLoss, q) // the marker is in the queue too
                }
                if tm >= rLoss - holdNs {
                    // in the place of the time of the change ahead of it
                    seq.append(Event(t: tm, kind: mute, order: e.order - 0.5, step: Step(late: false, kind: lost, tNs: tm)))
                } else {
                    pend.append(Pend(cut: rLoss - holdNs, rank: 0, order: e.order - 0.5, step: Step(late: true, kind: lost, tNs: tm)))
                }
                continue
            }
            guard let r = reach else {
                seq.append(e)
                continue
            }
            if e.kind == mute {
                queueReach = r
            }
            if e.t >= r - holdNs {
                seq.append(e) // reaches the worker within the hold: merged in its place
            } else {
                var step = e.step
                step.late = true
                pend.append(Pend(cut: r - holdNs, rank: e.kind == mute ? 0 : 1, order: e.order, step: step))
            }
        }
        seq.sort(by: precedes)
        pend.sort { a, b in
            if a.cut != b.cut { return a.cut < b.cut }
            if a.rank != b.rank { return a.rank < b.rank }
            return a.order < b.order
        }
        var out: [Step] = []
        var j = 0
        for e in seq {
            while j < pend.count && pend[j].cut <= e.t {
                out.append(pend[j].step)
                j += 1
            }
            out.append(e.step)
        }
        while j < pend.count {
            out.append(pend[j].step)
            j += 1
        }
        return out
    }

    /// Offers one step to the stream, as the engine would.
    static func feed(_ stream: VoiceStatsStream, _ step: Step) {
        switch step.kind {
        case rx:
            stream.addTapBlock(tNs: step.tNs, ticks: step.ticks)
        case mute:
            stream.addMute(tNs: step.tNs, muted: step.muted)
        case delivery:
            if let s = step.snapshot {
                stream.addSnapshot(s)
            }
        case lost:
            stream.addLostMute(tNs: step.tNs)
        default:
            XCTFail("kind \(step.kind)")
        }
    }
}

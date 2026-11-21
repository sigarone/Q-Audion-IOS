import XCTest
import Foundation
@testable import QAudionEngine

/// Behaviour of the stats stream that the stats vector does not pin: late inputs move nothing, and the retained state stays
/// bounded while the tap is silent.
final class VoiceStatsStreamTests: XCTestCase {

    private let second: Int64 = 1_000_000_000

    private func snapshot(
        req: Int64, arrive: Int64, report: Int64, total: Int64, ssrc: Int64 = 1
    ) -> VoiceStatsSnapshot {
        VoiceStatsSnapshot(
            reqNs: req, arriveNs: arrive, oldestNs: req, reportNs: report, rxSsrc: ssrc, concealed: 0, silentConcealed: 0,
            concealmentEvents: 0, totalSamples: total, insertedDecel: 0, removedAccel: 0, jbDelayS: 0, jbEmitted: total,
            txEnergy: 0, txDurationS: 0)
    }

    /// An input whose time and kind are below those of the latest input fed is late and moves nothing, the clock included.
    /// A late mute change is kept at its own time, a late delivery is dropped, a lost mute change is a late unmute.
    func testALateInputMovesNothing() throws {
        let gates = try VoiceKat.bundle().constants.gates
        let stream = VoiceStatsStream(gates: gates)
        stream.setMediaStart(0)
        stream.addTapBlock(tNs: 10 * second, ticks: 960_000)
        stream.addChunk(index: 0, t0Ns: 9_900_000_000, t1Ns: 9_932_000_000) // waiting: neither final nor overdue at this clock
        XCTAssertNil(stream.pollFinal())
        XCTAssertEqual(stream.clockTime, 10 * second)

        // A mute change below the clock is kept at its own time, and the clock stays.
        stream.addMute(tNs: 3 * second, muted: true)
        stream.addMute(tNs: 10 * second, muted: false) // the same time as the block, after it in the feed order: not late
        stream.addMute(tNs: 3_500_000_000, muted: false)
        XCTAssertEqual(stream.lateMuteCount, 2)
        XCTAssertEqual(stream.clockTime, 10 * second)
        XCTAssertEqual(stream.retainedMutes, [
            VoiceMute(tNs: 3 * second, muted: true),
            VoiceMute(tNs: 3_500_000_000, muted: false),
            VoiceMute(tNs: 10 * second, muted: false)
        ])

        // A block below the clock is late.
        stream.addTapBlock(tNs: 9_990_000_000, ticks: 959_000)
        XCTAssertEqual(stream.lateRxCount, 1)

        // So is a delivery below it: dropped.
        var dropped: [String] = []
        stream.dropListener = { _, rule in dropped.append(rule) }
        stream.addSnapshot(snapshot(req: 5 * second, arrive: 5_020_000_000, report: 1, total: 1))
        XCTAssertEqual(dropped, ["late"])
        XCTAssertEqual(stream.lateDeliveryCount, 1)
        XCTAssertEqual(stream.clockTime, 10 * second)
        XCTAssertNil(stream.pollFinal(), "nothing was released by a late input")

        // A block at the same time as a delivery that was fed first is late: its kind is below the delivery's.
        stream.addSnapshot(snapshot(req: 10 * second, arrive: 10_100_000_000, report: 2, total: 2))
        XCTAssertEqual(stream.clockTime, 10_100_000_000)
        stream.addTapBlock(tNs: 10_100_000_000, ticks: 970_000)
        XCTAssertEqual(stream.lateRxCount, 2)

        // A lost mute change is a late unmute at the time given.
        stream.addLostMute(tNs: 2 * second)
        XCTAssertEqual(stream.lostMuteCount, 1)
        XCTAssertEqual(stream.retainedMutes.first, VoiceMute(tNs: 2 * second, muted: false))
        XCTAssertEqual(stream.clockTime, 10_100_000_000)
    }

    /// A call whose tap ends at 10 s while the deliveries go on for 100 s: the snapshots that wait for an RX block pile up,
    /// one per poll. At most 64 wait, the oldest of a 65th is dropped (the interval that spans it is unknown), and the chunks
    /// that wait for them are released as overdue 5.5 s after their end, so everything stays bounded.
    func testASilentTapKeepsTheRetainedStateBounded() throws {
        let gates = try VoiceKat.bundle().constants.gates
        let chunkNs: Int64 = 32_000_000
        let stream = VoiceStatsStream(gates: gates)
        stream.setMediaStart(0)

        struct Item {
            var t: Int64
            var rank: Int
            var run: () -> Void
        }
        var items: [Item] = []
        for j in 1...1000 { // the tap ends at 10 s
            let t = Int64(j) * 10_000_000
            items.append(Item(t: t, rank: 0) { stream.addTapBlock(tNs: t, ticks: Int64(j) * 960) })
        }
        var after = 0
        var lastArrival: Int64 = 0
        for k in 0..<100 {
            let req = second / 2 + Int64(k) * second
            let s = VoiceStatsSnapshot(
                reqNs: req, arriveNs: req + 20_000_000, oldestNs: req, reportNs: Int64(k), rxSsrc: 7, concealed: 0,
                silentConcealed: 0, concealmentEvents: 0, totalSamples: 48_000 * Int64(k), insertedDecel: 0,
                removedAccel: 0, jbDelayS: 0.01 * Double(k), jbEmitted: 48_000 * Int64(k), txEnergy: 1e-6 * Double(k),
                txDurationS: Double(k), rttPairS: 0.08)
            if s.arriveNs > 10 * second {
                after += 1
            }
            lastArrival = max(lastArrival, s.arriveNs)
            items.append(Item(t: s.arriveNs, rank: 2) { stream.addSnapshot(s) })
        }
        let chunkCount = 3125 // 100 s
        for i in 0..<chunkCount {
            let t0 = Int64(i) * chunkNs
            items.append(Item(t: t0 + chunkNs, rank: 3) { stream.addChunk(index: i, t0Ns: t0, t1Ns: t0 + chunkNs) })
        }
        items.sort { a, b in a.t != b.t ? a.t < b.t : a.rank < b.rank }

        var released: [Int: VoiceChunkFlags] = [:]
        func poll() {
            while let f = stream.pollFinal() {
                released[f.index] = f
            }
        }
        for item in items {
            item.run()
            poll()
        }
        stream.finish(endNs: lastArrival)
        poll()

        XCTAssertEqual(after, 90)
        XCTAssertEqual(stream.capDroppedCount, after - 64, "the 65th waiting snapshot drops the oldest")
        XCTAssertEqual(stream.peakUnresolved, 64)
        XCTAssertLessThanOrEqual(stream.peakKept, 64 + 4)
        XCTAssertLessThanOrEqual(stream.peakIntervals, 20)
        XCTAssertLessThanOrEqual(stream.peakPending, (5500 + 1100) / 32 + 6)
        XCTAssertEqual(released.count, chunkCount)

        // A chunk behind the silent tap is released as overdue, within one input of 5.5 s after its end.
        guard let f = released[1000] else {
            XCTFail("chunk 1000 was not released")
            return
        }
        XCTAssertTrue(f.overdue)
        XCTAssertTrue(f.txUnknown && f.concUnknown && !f.excluded && f.overlaps.isEmpty)
        let t1 = 1001 * chunkNs
        XCTAssertGreaterThanOrEqual(f.releaseNs, t1 + 5_500_000_000)
        XCTAssertLessThan(f.releaseNs, t1 + 5_500_000_000 + 1_100_000_000)
    }
}

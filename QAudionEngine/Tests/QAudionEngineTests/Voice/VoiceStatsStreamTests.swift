import XCTest
import Foundation
@testable import QAudionEngine

/// Deliveries the stats vector does not contain: a report that arrives out of order and later than `late_ms` behind its
/// request, after newer ones have settled.
final class VoiceStatsStreamTests: XCTestCase {

    private struct Flags: Equatable {
        var excluded: Bool
        var txUnknown: Bool
        var concUnknown: Bool
        var touchConcealment: Bool
        var touchStretch: Bool
    }

    private func flags(_ track: VoiceStatsTrack, t0: Int64, t1: Int64, mediaStart: Int64) -> Flags {
        let tx = track.txFlags(t0: t0, t1: t1, mediaStart: mediaStart)
        let conc = track.concFlags(t0: t0, t1: t1, mediaStart: mediaStart)
        return Flags(
            excluded: tx.excluded,
            txUnknown: tx.unknown,
            concUnknown: conc.unknown,
            touchConcealment: conc.concealment,
            touchStretch: conc.stretch)
    }

    /// The steady case with one report delayed by 3 s, 3.6 s and 6 s, fed in arrival order. Every probe chunk is read
    /// the moment its flags are final; those flags must be the ones of the track once the call has ended.
    func testLateReportBehindSettledOnes() throws {
        let gates = try VoiceKat.bundle().constants.gates
        let doc = try VoiceKat.json("stage3_measure/stats_cases.json")
        let mediaStart = doc["t_media_ns"].int64
        let chunkNs = doc["chunk_ns"].int64
        let probes = doc["n_chunks"].int
        let steady = try XCTUnwrap(doc["cases"].array.first { $0["name"].string == "steady" })

        var blocks: [(t: Int64, ticks: Int64)] = []
        for run in steady["tap"].array {
            for j in 0..<run["n"].int {
                blocks.append((
                    t: run["t_ns"].int64 + Int64(j) * run["period_ns"].int64,
                    ticks: run["ticks"].int64 + Int64(j) * run["step"].int64))
            }
        }
        let reports = steady["snapshots"].array.map { VoiceStatsSnapshot(json: $0) }
        let late = 10

        for delayMs in [3000, 3600, 6000] {
            var delivered = reports
            delivered[late].arriveNs = delivered[late].reqNs + Int64(delayMs) * 1_000_000
            delivered = delivered.enumerated().sorted { a, b in
                a.element.arriveNs != b.element.arriveNs ? a.element.arriveNs < b.element.arriveNs : a.offset < b.offset
            }.map { $0.element }

            let stream = VoiceStatsStream(gates: gates)
            var early: [Flags] = []
            func drain() {
                while early.count < probes {
                    let t0 = mediaStart + Int64(early.count) * chunkNs
                    let t1 = t0 + chunkNs
                    if !stream.isConcealmentFinal(t1: t1) || !stream.isTxFinal(t1: t1) {
                        return
                    }
                    early.append(flags(stream.track, t0: t0, t1: t1, mediaStart: mediaStart))
                }
            }
            var b = 0
            for report in delivered {
                while b < blocks.count && blocks[b].t <= report.arriveNs {
                    stream.addTapBlock(tNs: blocks[b].t, ticks: blocks[b].ticks)
                    b += 1
                    drain()
                }
                stream.addSnapshot(report)
                drain()
            }
            while b < blocks.count {
                stream.addTapBlock(tNs: blocks[b].t, ticks: blocks[b].ticks)
                b += 1
                drain()
            }
            XCTAssertEqual(early.count, probes, "delay \(delayMs) ms: every probe is released before the call ends")
            XCTAssertEqual(stream.keptCount, reports.count - 1, "delay \(delayMs) ms: the late report is dropped")
            stream.finish()
            for i in 0..<early.count {
                let t0 = mediaStart + Int64(i) * chunkNs
                let end = flags(stream.track, t0: t0, t1: t0 + chunkNs, mediaStart: mediaStart)
                XCTAssertEqual(early[i], end, "delay \(delayMs) ms: probe \(i)")
            }
        }
    }
}

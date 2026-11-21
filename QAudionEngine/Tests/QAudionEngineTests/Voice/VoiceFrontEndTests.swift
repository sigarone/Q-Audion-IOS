import XCTest
import Foundation
@testable import QAudionEngine

/// Behaviour that the vectors do not pin: the inactive front-end, events before the first RX block, and the lossless path of
/// the mute changes.
final class VoiceFrontEndTests: XCTestCase {

    private struct VadFailure: Error {}

    /// A VAD that gives 0.1 for `failAt` calls and then `bad` (a throw when nil).
    private final class FailingVad: VoiceVadModel {
        private let failAt: Int
        private let bad: Float?
        private(set) var calls = 0

        init(failAt: Int, bad: Float?) {
            self.failAt = failAt
            self.bad = bad
        }

        func reset() {}

        func step(_ chunk: [Float]) throws -> Float {
            calls += 1
            if calls > failAt {
                if let value = bad {
                    return value
                }
                throw VadFailure()
            }
            return 0.1
        }
    }

    private final class Collected {
        var chunks: [VoiceChunkRecord] = []
        var windows: [VoiceWindowResult] = []
    }

    private func makeFrontEnd(_ vad: VoiceVadModel, _ out: Collected) throws -> VoiceFrontEnd {
        let engine = VoiceFrontEnd(bundle: try VoiceKat.bundle(), vad: vad)
        engine.onChunk = { out.chunks.append($0) }
        engine.onWindow = { out.windows.append($0) }
        return engine
    }

    private let pcm: [Int16] = (0..<1536).map { Int16(($0 * 37) % 400 - 200) }

    private func steadyVad() -> StoredProbabilityVad {
        StoredProbabilityVad([Float](repeating: 0.1, count: 8))
    }

    /// Three 16 kHz chunks in one block at tap clock `startMs`, then the rest of a call: a snapshot, a mute change, two events,
    /// another block, a lost mute change and the end of the call.
    private func feedAfter(_ engine: VoiceFrontEnd, startMs: Int64) {
        let t = startMs * 1_000_000
        engine.onRx(pcm, rateHz: 16_000, tNs: t, tapTicks: 9_216)
        engine.onStats(VoiceStatsSnapshot(
            reqNs: t, arriveNs: t + 20_000_000, oldestNs: t, reportNs: 1, rxSsrc: 1, concealed: 0, silentConcealed: 0,
            concealmentEvents: 0, totalSamples: 100, insertedDecel: 0, removedAccel: 0, jbDelayS: 0, jbEmitted: 100,
            txEnergy: 0, txDurationS: 0))
        engine.onMute(tNs: t + 40_000_000, muted: true)
        engine.onEvent(.hold)
        engine.onEvent(.reset)
        engine.registerTapBlock(count: 512, rateHz: 16_000, tNs: t + 100_000_000, tapTicks: 9_216 + 3_072)
        engine.push(pcm[0..<512])
        engine.onMuteLost(tNs: t)
        engine.finish(endNs: t + 5_000_000_000)
    }

    /// A failed VAD call, or an output that is not a finite number, makes the front-end inactive: nothing more comes out,
    /// nothing is thrown at the caller, and it stays inactive to the end of the call.
    func testAFailedVadCallMakesTheFrontEndInactive() throws {
        // Control: the same inputs with a working VAD hand out chunks at the end of the call.
        let ok = Collected()
        let engineOk = try makeFrontEnd(FailingVad(failAt: Int.max, bad: nil), ok)
        feedAfter(engineOk, startMs: 1000)
        XCTAssertFalse(engineOk.isInactive)
        XCTAssertFalse(ok.chunks.isEmpty, "the control run hands out chunks")

        for bad in [nil, Float.nan, Float.infinity] as [Float?] {
            let out = Collected()
            let engine = try makeFrontEnd(FailingVad(failAt: 2, bad: bad), out) // the third chunk of the first block fails
            XCTAssertFalse(engine.isInactive)
            feedAfter(engine, startMs: 1000)
            XCTAssertTrue(engine.isInactive, "inactive after a failed VAD call (\(String(describing: bad)))")
            XCTAssertTrue(out.chunks.isEmpty, "no chunk is handed out (\(String(describing: bad)))")
            XCTAssertTrue(out.windows.isEmpty, "no window is handed out (\(String(describing: bad)))")
            engine.onRx(pcm, rateHz: 16_000, tNs: 9_000_000_000, tapTicks: 20_000)
            engine.onEvent(.resume)
            engine.finish()
            XCTAssertTrue(engine.isInactive)
            XCTAssertTrue(out.chunks.isEmpty)
        }
    }

    /// A tap rate that the resampler does not support leaves the front-end inactive for the rest of the call, even when a
    /// supported rate comes back; what is waiting is discarded.
    func testAnUnsupportedRateStaysInactive() throws {
        // From the first block.
        let out = Collected()
        let engine = try makeFrontEnd(steadyVad(), out)
        engine.onRx([Int16](repeating: 5, count: 441), rateHz: 44_100, tNs: 1_000_000_000, tapTicks: 2_646)
        XCTAssertTrue(engine.isInactive)
        XCTAssertEqual(engine.nextChunkIndex, 0)
        XCTAssertNil(engine.mediaStartNs, "media start was not taken from the refused block")
        let supported = [Int16](repeating: 100, count: 480)
        for i in 0..<400 {
            engine.onRx(supported, rateHz: 48_000, tNs: 1_010_000_000 + Int64(i) * 10_000_000, tapTicks: Int64(i + 1) * 960)
        }
        feedAfter(engine, startMs: 2000)
        engine.finish()
        XCTAssertTrue(engine.isInactive)
        XCTAssertTrue(out.chunks.isEmpty && out.windows.isEmpty)
        XCTAssertNil(engine.mediaStartNs)

        // In the middle of a call.
        let out2 = Collected()
        let engine2 = try makeFrontEnd(steadyVad(), out2)
        engine2.onRx(pcm, rateHz: 16_000, tNs: 1_000_000_000, tapTicks: 9_216)
        XCTAssertEqual(engine2.nextChunkIndex, 3)
        XCTAssertFalse(engine2.isInactive)
        engine2.onRx([Int16](repeating: 5, count: 441), rateHz: 44_100, tNs: 1_032_000_000, tapTicks: 9_216 + 2_646)
        XCTAssertTrue(engine2.isInactive)
        engine2.onRx(Array(pcm[0..<512]), rateHz: 16_000, tNs: 1_064_000_000, tapTicks: 15_000)
        XCTAssertEqual(engine2.nextChunkIndex, 3, "nothing is fed to the chunker any more")
        engine2.finish()
        XCTAssertTrue(engine2.isInactive)
        XCTAssertTrue(out2.chunks.isEmpty)
    }

    /// RESET, HOLD, RESUME and ROUTE before the first RX block are accepted and do nothing (no epoch starts, the first chunk
    /// is in epoch 0); one after it starts an epoch for the chunks from its position on, also at chunk 0.
    func testAnEventBeforeTheFirstBlockStartsNoEpoch() throws {
        let out = Collected()
        let engine = try makeFrontEnd(steadyVad(), out)
        for kind in [VoiceFrontEndEvent.hold, .resume, .route, .reset] {
            engine.onEvent(kind)
        }
        XCTAssertNil(engine.mediaStartNs)
        XCTAssertEqual(engine.nextChunkIndex, 0)
        engine.onRx(pcm, rateHz: 16_000, tNs: 1_000_000_000, tapTicks: 9_216)
        engine.finish(endNs: 6_000_000_000)
        XCTAssertEqual(out.chunks.map { $0.index }, [0, 1, 2])
        XCTAssertEqual(out.chunks.map { $0.epoch }, [0, 0, 0], "the first chunk is in epoch 0")
        XCTAssertFalse(engine.isInactive)

        // After the first block, before chunk 0 completes: the chunks from 0 on carry the epoch after the event.
        let out2 = Collected()
        let engine2 = try makeFrontEnd(steadyVad(), out2)
        engine2.registerTapBlock(count: 1_536, rateHz: 16_000, tNs: 1_000_000_000, tapTicks: 9_216)
        engine2.onEvent(.route)
        engine2.push(pcm[...])
        engine2.finish(endNs: 6_000_000_000)
        XCTAssertEqual(out2.chunks.map { $0.epoch }, [1, 1, 1])
    }

    /// Mute changes reach the stats stream complete and in order, however many there are: the front-end has no queue, a
    /// burst far larger than any bounded queue on the way (8 is the size of the one that drops its oldest element) loses none.
    func testAMuteBurstLargerThanAnyBoundedQueueIsComplete() throws {
        let engine = try makeFrontEnd(steadyVad(), Collected())
        let n = 500
        for i in 0..<n {
            engine.onMute(tNs: 10_000_000 + Int64(i) * 1_000_000, muted: i % 2 == 0)
        }
        let got = engine.statsStream.retainedMutes
        XCTAssertEqual(got.count, n)
        for i in 0..<min(n, got.count) {
            XCTAssertEqual(got[i], VoiceMute(tNs: 10_000_000 + Int64(i) * 1_000_000, muted: i % 2 == 0))
        }
        XCTAssertEqual(engine.statsStream.clockTime, 10_000_000 + Int64(n - 1) * 1_000_000, "every mute change moved the clock")
    }
}

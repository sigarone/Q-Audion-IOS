import XCTest
@testable import QAudionEngine

/// W-JBREORDER (2026-09-10) — the reorder-aware component of the adaptive
/// target, pinned. Direct port of Android's `JitterBufferReorderTest.kt`.
/// See `PlayoutJitterBufferAdaptiveTargetTests` for the plain-lateness half
/// this extends, and `reference_jitterbuffer_reorder_audit_2026_09_10.md`
/// (external memory, competitor names quarantined there) for the
/// best-practices research this closes a gap against.
final class PlayoutJitterBufferReorderTests: XCTestCase {

    private final class Clock {
        var seconds: Double = 1.0
        func advanceMs(_ ms: Double) { seconds += ms / 1000.0 }
    }

    private func buffer(_ clock: Clock) -> PlayoutJitterBuffer {
        PlayoutJitterBuffer(nowSeconds: { clock.seconds })
    }

    private func voiceFrame() -> Data {
        var d = Data(count: 960 * 2)
        d.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<960 { p[i] = i % 2 == 0 ? 8000 : -8000 }
        }
        return d
    }

    /// Push `count` frames on a perfect 20ms cadence with strictly
    /// increasing seq starting at `startSeq`.
    private func pushInOrder(_ jb: PlayoutJitterBuffer, _ clock: Clock, count: Int, startSeq: Int64 = 0) {
        for i in 0..<count {
            clock.advanceMs(20)
            jb.push(voiceFrame(), seq: startSeq + Int64(i))
            if jb.depth > 4 { _ = jb.popWithDriftCatchup() }
        }
    }

    func test_cleanInOrderStreamWithSeqSupplied_convergesToFloor_sameAsWithoutSeq() {
        let clock = Clock()
        let jb = buffer(clock)
        pushInOrder(jb, clock, count: 200)
        XCTAssertEqual(
            PlayoutJitterBuffer.adaptTargetMinMs, jb.adaptiveTargetMs,
            "supplying a strictly-increasing seq must not by itself change behavior")
    }

    func test_unknownSeq_neverTriggersReorderDetection() {
        let clock = Clock()
        let jb = buffer(clock)
        for _ in 0..<200 {
            clock.advanceMs(20)
            jb.push(voiceFrame(), seq: nil)
            if jb.depth > 4 { _ = jb.popWithDriftCatchup() }
        }
        XCTAssertEqual(PlayoutJitterBuffer.adaptTargetMinMs, jb.adaptiveTargetMs)
    }

    func test_singleReorderedArrival_inflatesTargetBeyondPureLateness() {
        let clock = Clock()
        let jb = buffer(clock)
        pushInOrder(jb, clock, count: 100, startSeq: 0)
        XCTAssertEqual(PlayoutJitterBuffer.adaptTargetMinMs, jb.adaptiveTargetMs)

        // One frame arrives ON TIME but 5 frames BEHIND the highest sequence
        // already seen (seq=99) — a retransmit/second-leg delivery of an old
        // frame, not a late one.
        for i in 0..<60 {
            clock.advanceMs(20)
            jb.push(voiceFrame(), seq: 95) // 5 frames behind seq=99
            if jb.depth > 4 { _ = jb.popWithDriftCatchup() }
            clock.advanceMs(20)
            jb.push(voiceFrame(), seq: 100 + Int64(i))
            if jb.depth > 4 { _ = jb.popWithDriftCatchup() }
        }
        XCTAssertGreaterThan(
            jb.adaptiveTargetMs, PlayoutJitterBuffer.adaptTargetMinMs,
            "a reordered arrival 5 frames behind (5*20=100ms) must push the target " +
            "above the floor even though every arrival was ON TIME by pure lateness")
    }

    func test_reorderPenalty_isCappedAtTheSameCeilingPlainLatenessAlreadyRespects() {
        let clock = Clock()
        let jb = buffer(clock)
        pushInOrder(jb, clock, count: 100, startSeq: 10_000)
        for i in 0..<60 {
            clock.advanceMs(20)
            jb.push(voiceFrame(), seq: 0) // ~10000 frames behind
            if jb.depth > 4 { _ = jb.popWithDriftCatchup() }
            clock.advanceMs(20)
            jb.push(voiceFrame(), seq: 10_100 + Int64(i))
            if jb.depth > 4 { _ = jb.popWithDriftCatchup() }
        }
        XCTAssertEqual(PlayoutJitterBuffer.adaptTargetMaxMs, jb.adaptiveTargetMs)
    }

    func test_lateButInOrderArrival_isUnaffectedByTheReorderPath() {
        let clock = Clock()
        let jb = buffer(clock)
        var seq: Int64 = 0
        for _ in 0..<40 {
            for _ in 0..<8 {
                clock.advanceMs(20)
                jb.push(voiceFrame(), seq: seq); seq += 1
                if jb.depth > 4 { _ = jb.popWithDriftCatchup() }
            }
            clock.advanceMs(120)
            jb.push(voiceFrame(), seq: seq); seq += 1
            if jb.depth > 4 { _ = jb.popWithDriftCatchup() }
            clock.advanceMs(0)
            jb.push(voiceFrame(), seq: seq); seq += 1
            if jb.depth > 4 { _ = jb.popWithDriftCatchup() }
        }
        XCTAssertEqual(
            120, jb.adaptiveTargetMs,
            "in-order lateness must produce the identical p95 result with or without seq")
    }
}

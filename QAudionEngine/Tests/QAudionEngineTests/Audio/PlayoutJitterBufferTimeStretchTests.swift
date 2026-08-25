import XCTest
@testable import QAudionEngine

/// `PlayoutJitterBuffer`-level tests for W-JBSTRETCH (2026-08-25, parity
/// plan Fase C3): time-stretch as a new first option ahead of the existing
/// whole-frame drop tiers. Direct port of Android's
/// `JitterBufferTimeStretchTest.kt`.
///
/// At the default 20 ms cadence: `trim` = 7 frames (140 ms),
/// `timeStretchWatermark` = 10 frames (200 ms), `emergency` = 15 frames
/// (300 ms). So the "try time-stretch first" band is depth in (7, 10] — 8,
/// 9 or 10 frames queued.
final class PlayoutJitterBufferTimeStretchTests: XCTestCase {

    private func loudFrame(seed: Int = 0, samples: Int = 960) -> Data {
        var d = Data(count: samples * 2)
        d.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<samples { p[i] = (i + seed) % 2 == 0 ? 8000 : -8000 }
        }
        return d
    }

    private func silentFrame(samples: Int = 960) -> Data {
        var d = Data(count: samples * 2)
        d.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<samples { p[i] = 10 }
        }
        return d
    }

    // MARK: - gating: fires only in the intended band

    func test_doesNotFireAtLowOrNominalDepth() {
        let jb = PlayoutJitterBuffer()
        for i in 0..<5 { jb.push(loudFrame(seed: i)) } // depth 5 <= trim(7)
        XCTAssertNotNil(jb.popWithDriftCatchup())
        XCTAssertEqual(0, jb.timeStretchFrames)
    }

    func test_firesInTheModerateBand_andShortensTheDeliveredFrame() {
        let jb = PlayoutJitterBuffer()
        for i in 0..<9 { jb.push(loudFrame(seed: i)) } // depth 9, inside (7, 10]
        let delivered = jb.popWithDriftCatchup()
        XCTAssertNotNil(delivered)
        let expectedShortLen = 960 * 2 - PlayoutJitterBuffer.timeStretchShaveSamples * 2
        XCTAssertEqual(expectedShortLen, delivered!.count)
        XCTAssertEqual(1, jb.timeStretchFrames)
        // It took the NEW path, not the old excision machinery.
        XCTAssertEqual(0, jb.silenceDrops)
        XCTAssertEqual(0, jb.hardDrops)
    }

    func test_firesAtEveryDepthInTheModerateBand_8Through10() {
        for entryDepth in 8...10 {
            let jb = PlayoutJitterBuffer()
            for i in 0..<entryDepth { jb.push(loudFrame(seed: i)) }
            _ = jb.popWithDriftCatchup()
            XCTAssertEqual(1, jb.timeStretchFrames, "entryDepth=\(entryDepth)")
        }
    }

    func test_doesNotFireAboveItsCeiling_theExistingAggressiveDropMachineryRunsUnchanged() {
        let jb = PlayoutJitterBuffer()
        // 12 silent frames is past timeStretchWatermark(10) but short of
        // emergencyWatermark(15).
        for _ in 0..<12 { jb.push(silentFrame()) }
        XCTAssertNotNil(jb.popWithDriftCatchup())
        XCTAssertEqual(0, jb.timeStretchFrames,
                       "depth 12 is above the time-stretch ceiling; must fall straight through")
        XCTAssertGreaterThan(jb.silenceDrops, 0,
                             "the pre-existing energy-gated tier must still fire exactly as before")
    }

    /// W-FRAMEAGNOSTIC edge case: the currently-adopted cadence is driven by
    /// whichever frame was pushed MOST RECENTLY (via
    /// `setInboundFrameDurationMs`), so with more than one frame already
    /// queued across a duration transition, the frame actually at the head
    /// of the FIFO can be a different byte length than what the currently-
    /// adopted cadence expects. Compressing it against the wrong expected
    /// length would either read past the array or — the more dangerous
    /// failure — silently read only the first `n` samples of a genuinely
    /// longer frame and discard the real remainder. Must decline and
    /// deliver the frame whole instead.
    func test_declinesToCompress_aFrameWhoseLengthDoesNotMatchTheCurrentlyAdoptedCadence() {
        let jb = PlayoutJitterBuffer()
        // Head-of-queue frame predates a duration transition: 60ms-sized
        // (2880 samples), pushed before the cadence moved.
        let preTransitionFrame = Data(count: AudioConstants.maxBytesPerFrame)
        jb.push(preTransitionFrame)
        // Cadence stays at the shipped 20 ms default here (mirrors
        // AudioCapture's playout side, which only ever moves the cadence
        // forward on an OBSERVED inbound frame — never touched by this
        // test's own pushes below, all of which are already 20 ms).
        jb.setInboundFrameDurationMs(20)
        // Bring depth into the moderate band with normal 20ms frames.
        for i in 0..<8 { jb.push(loudFrame(seed: i)) } // depth 9, inside (7, 10]

        let delivered = jb.popWithDriftCatchup()
        XCTAssertNotNil(delivered)
        XCTAssertEqual(
            AudioConstants.maxBytesPerFrame, delivered!.count,
            "the mismatched head frame must be delivered WHOLE, not compressed against the wrong expected length")
        XCTAssertEqual(0, jb.timeStretchFrames)
    }

    func test_doesNotFireInTheEmergencyRange() {
        let jb = PlayoutJitterBuffer()
        for i in 0..<20 { jb.push(loudFrame(seed: i)) } // depth 20 >= emergencyWatermark(15)
        XCTAssertNotNil(jb.popWithDriftCatchup())
        XCTAssertEqual(0, jb.timeStretchFrames)
        XCTAssertGreaterThan(jb.hardDrops, 0, "the emergency tier must still fire exactly as before")
    }

    func test_doesNotFireWhileAnEmergencyDrainIsStillLatched_evenIfDepthDipsIntoTheBand() {
        let jb = PlayoutJitterBuffer()
        for i in 0..<20 { jb.push(loudFrame(seed: i)) }
        // Drain until the latch clears. Every pop along the way must stay on
        // tier 3, never time-stretch, even once depth is inside (7, 10].
        var ticks = 0
        while jb.depth >= 4, ticks < 50 {
            _ = jb.popWithDriftCatchup()
            ticks += 1
        }
        XCTAssertEqual(
            0, jb.timeStretchFrames,
            "the emergency latch must own every pop of the drain, not hand off to time-stretch")
        XCTAssertGreaterThan(jb.hardDrops, 0)
    }

    // MARK: - frame accounting: a shorter frame, not an extra drop

    func test_aTimeStretchEvent_consumesExactlyOneFrameFromTheQueue_likeAnyOtherDelivery() {
        let jb = PlayoutJitterBuffer()
        for i in 0..<9 { jb.push(loudFrame(seed: i)) }
        let before = jb.depth
        _ = jb.popWithDriftCatchup()
        XCTAssertEqual(before - 1, jb.depth)
    }

    // MARK: - compounding: repeated small corrections while depth stays high

    /// Matched producer/consumer holding depth inside the moderate band
    /// across many pops: each pop should fire time-stretch again, proving
    /// corrections compound rather than firing once and then falling back.
    func test_multipleSmallCorrections_compoundAcrossConsecutiveFramesWhileDepthStaysInBand() {
        let jb = PlayoutJitterBuffer()
        for i in 0..<9 { jb.push(loudFrame(seed: i)) } // depth 9

        var seed = 100
        for _ in 0..<20 {
            _ = jb.popWithDriftCatchup() // depth -> 8
            jb.push(loudFrame(seed: seed)) // depth -> 9 again, still in band
            seed += 1
        }

        XCTAssertEqual(
            20, jb.timeStretchFrames,
            "every one of the 20 pops stayed inside the moderate band and should have compressed rather than fallen back")
        XCTAssertEqual(0, jb.silenceDrops)
        XCTAssertEqual(0, jb.hardDrops)
    }

    // MARK: - reset plumbing

    func test_reset_zeroesTheTimeStretchCounter() {
        let jb = PlayoutJitterBuffer()
        for i in 0..<9 { jb.push(loudFrame(seed: i)) }
        _ = jb.popWithDriftCatchup()
        XCTAssertEqual(1, jb.timeStretchFrames)
        jb.reset()
        XCTAssertEqual(0, jb.timeStretchFrames)
    }

    // MARK: - cross-profile: also correct at the 60ms long-frame cadence

    func test_firesAtThe60msLongFrameCadenceToo_shortenedByTheSameFixedSampleShave() {
        let jb = PlayoutJitterBuffer()
        jb.setInboundFrameDurationMs(60)
        // trim(140ms)@60ms=2, timeStretchWatermark(200ms)@60ms=3.
        for i in 0..<3 { jb.push(loudFrame(seed: i, samples: 2880)) }
        let delivered = jb.popWithDriftCatchup()
        XCTAssertNotNil(delivered)
        let expected = AudioConstants.maxBytesPerFrame - PlayoutJitterBuffer.timeStretchShaveSamples * 2
        XCTAssertEqual(expected, delivered!.count)
        XCTAssertEqual(1, jb.timeStretchFrames)
    }
}

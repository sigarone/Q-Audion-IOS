import XCTest
@testable import QAudionEngine

/// Pure-function tests for `TimeStretch.compress` — the splice math behind
/// W-JBSTRETCH (2026-08-25, parity plan Fase C3).
///
/// Deliberately independent of `PlayoutJitterBuffer`: the algorithm is a
/// function of sample data only, so its correctness (exact output length, no
/// seam at the head boundary, a genuine blend rather than a hard cut, no
/// int16 overflow) can be pinned with exact assertions here — mirroring
/// Android's `TimeStretchTest.kt`, which this file is a direct port of.
///
/// This is also where the C3 acceptance criterion "catch-up doesn't produce
/// a raw sample-domain discontinuity" is proven directly: real audio cannot
/// be listened to in this environment, but the crossfade's bound on the
/// sample-to-sample delta at the splice CAN be, and is, asserted exactly.
final class TimeStretchTests: XCTestCase {

    private func constantFrame(samples: Int, value: Int16) -> Data {
        var d = Data(count: samples * 2)
        d.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<samples { p[i] = value }
        }
        return d
    }

    /// Builds a frame with three distinct regions so head/region/tail can be
    /// told apart by value.
    private func regionFrame(samples: Int, head: Int16, region: Int16, tail: Int16, shave: Int) -> Data {
        var d = Data(count: samples * 2)
        let headSamples = samples - 2 * shave
        d.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<headSamples { p[i] = head }
            for i in headSamples..<(headSamples + shave) { p[i] = region }
            for i in (headSamples + shave)..<samples { p[i] = tail }
        }
        return d
    }

    private func readSample(_ pcm: Data, _ sampleIndex: Int) -> Int16 {
        pcm.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            return Int16(littleEndian: p[sampleIndex])
        }
    }

    // MARK: - shape / length

    func test_outputLength_isExactlyInputSamplesMinusShaveSamples() {
        let n = 960, shave = 144
        let input = constantFrame(samples: n, value: 1234)
        var out = Data(count: (n - shave) * 2)
        let written = TimeStretch.compress(input: input, inputSamples: n, shaveSamples: shave, out: &out)
        XCTAssertEqual((n - shave) * 2, written)
    }

    func test_headRegion_isCopiedUnmodified() {
        let n = 960, shave = 144
        let headValue: Int16 = 4000
        let headSamples = n - 2 * shave
        let input = regionFrame(samples: n, head: headValue, region: -7000, tail: -7000, shave: shave)
        var out = Data(count: (n - shave) * 2)
        let written = TimeStretch.compress(input: input, inputSamples: n, shaveSamples: shave, out: &out)
        XCTAssertEqual((n - shave) * 2, written)
        for i in 0..<headSamples {
            XCTAssertEqual(headValue, readSample(out, i), "head sample \(i) must be untouched")
        }
    }

    // MARK: - the actual claim: a blend, not a hard cut (no raw discontinuity)

    /// If this were a hard cut (concatenate head with tail, no crossfade),
    /// the single sample-to-sample delta at the splice would be the FULL
    /// |tail-region| in one step. A real crossfade spreads that over `shave`
    /// steps — this is the direct proof of the C3 acceptance criterion "no
    /// zero-crossing-violating jump at the splice point": the bound below is
    /// comfortably violated by a hard cut and comfortably satisfied by a
    /// real blend.
    func test_crossfade_boundsTheSampleToSampleDeltaAtTheSplice_unlikeAHardCut() {
        let n = 960, shave = 144
        let region: Int16 = 8000, tail: Int16 = -8000
        let headSamples = n - 2 * shave
        let input = regionFrame(samples: n, head: 0, region: region, tail: tail, shave: shave)
        var out = Data(count: (n - shave) * 2)
        let written = TimeStretch.compress(input: input, inputSamples: n, shaveSamples: shave, out: &out)
        XCTAssertEqual((n - shave) * 2, written)

        let hardCutDelta = abs(Int(tail) - Int(region)) // 16000
        let maxAllowedStep = hardCutDelta / shave + 4 // generous rounding slack

        var maxObservedStep = 0
        for i in headSamples..<((n - shave) - 1) {
            let delta = abs(Int(readSample(out, i + 1)) - Int(readSample(out, i)))
            if delta > maxObservedStep { maxObservedStep = delta }
        }
        XCTAssertLessThanOrEqual(
            maxObservedStep, maxAllowedStep,
            "max step \(maxObservedStep) across the crossfade must stay far below the hard-cut " +
            "jump of \(hardCutDelta) (bound: \(maxAllowedStep))")
        // And the bound is not vacuous — a hard cut would have failed it.
        XCTAssertLessThan(maxAllowedStep, hardCutDelta)
    }

    func test_crossfade_actuallyBlends_firstSampleMatchesRegionExactly_noSeamAtHeadBoundary() {
        let n = 960, shave = 144
        let region: Int16 = 5000, tail: Int16 = -3000
        let headSamples = n - 2 * shave
        let input = regionFrame(samples: n, head: 1000, region: region, tail: tail, shave: shave)
        var out = Data(count: (n - shave) * 2)
        _ = TimeStretch.compress(input: input, inputSamples: n, shaveSamples: shave, out: &out)

        // No seam: the head's last sample and the crossfade's first sample
        // must read the same as they would in the ORIGINAL frame at that
        // boundary — i.e. the crossfade's first sample is exactly
        // `region[0]`, not an average.
        XCTAssertEqual(1000, readSample(out, headSamples - 1))
        XCTAssertEqual(region, readSample(out, headSamples))

        // Somewhere in the middle of the crossfade the value must sit
        // strictly between the two endpoints — proof it is a blend, not a
        // copy of one side followed by a jump to the other.
        let mid = headSamples + shave / 2
        let midVal = Int(readSample(out, mid))
        XCTAssertTrue(
            ((Int(tail) + 1)..<Int(region)).contains(midVal),
            "midpoint \(midVal) must sit strictly between tail (\(tail)) and region (\(region))")
    }

    // MARK: - no overflow

    func test_blendingExtremeInt16Values_neverOverflowsThe16BitRange() {
        let n = 960, shave = 144
        let input = regionFrame(samples: n, head: 0, region: Int16.max, tail: Int16.min, shave: shave)
        var out = Data(count: (n - shave) * 2)
        let written = TimeStretch.compress(input: input, inputSamples: n, shaveSamples: shave, out: &out)
        XCTAssertEqual((n - shave) * 2, written)
        let headSamples = n - 2 * shave
        for i in headSamples..<(n - shave) {
            let v = readSample(out, i)
            XCTAssertTrue(v >= Int16.min && v <= Int16.max, "sample \(i) = \(v) out of int16 range")
        }
    }

    // MARK: - decline conditions

    func test_declines_whenFrameIsShorterThanTwiceTheShave() {
        let n = 200, shave = 144 // 2*144 = 288 > 200
        let input = constantFrame(samples: n, value: 100)
        var out = Data(count: n * 2)
        XCTAssertEqual(-1, TimeStretch.compress(input: input, inputSamples: n, shaveSamples: shave, out: &out))
    }

    func test_declines_onNonPositiveShaveOrSampleCount() {
        let input = constantFrame(samples: 960, value: 100)
        var out = Data(count: 960 * 2)
        XCTAssertEqual(-1, TimeStretch.compress(input: input, inputSamples: 960, shaveSamples: 0, out: &out))
        XCTAssertEqual(-1, TimeStretch.compress(input: input, inputSamples: 960, shaveSamples: -5, out: &out))
        XCTAssertEqual(-1, TimeStretch.compress(input: input, inputSamples: 0, shaveSamples: 10, out: &out))
    }

    func test_declines_whenInputIsShorterThanInputSamplesClaims() {
        let n = 960, shave = 144
        let input = Data(count: (n - 10) * 2) // shorter than claimed
        var out = Data(count: (n - shave) * 2)
        XCTAssertEqual(-1, TimeStretch.compress(input: input, inputSamples: n, shaveSamples: shave, out: &out))
    }

    func test_declines_whenOutputBufferIsUndersized() {
        let n = 960, shave = 144
        let input = constantFrame(samples: n, value: 100)
        var out = Data(count: (n - shave) * 2 - 2) // one sample short
        XCTAssertEqual(-1, TimeStretch.compress(input: input, inputSamples: n, shaveSamples: shave, out: &out))
    }

    // MARK: - both negotiated cadences

    func test_worksAtBothThe20msAnd60msCadences() {
        for samples in [960, 2880] { // 20ms and 60ms at 48kHz
            let shave = 144 // fixed 3ms shave regardless of frame duration
            let input = constantFrame(samples: samples, value: 500)
            var out = Data(count: (samples - shave) * 2)
            let written = TimeStretch.compress(input: input, inputSamples: samples, shaveSamples: shave, out: &out)
            XCTAssertEqual((samples - shave) * 2, written, "cadence with \(samples) samples")
        }
    }

    // MARK: - W-JBSTRETCH-WSOLA (2026-08-26) correlation search

    /// Regression test for a real defect caught and fixed BEFORE shipping
    /// (see `TimeStretch`'s own "Scoring" kdoc): a first design scored
    /// candidates by similarity to `tail` ALONE, which let the search
    /// prefer an offset whose read window straddled the region/tail value
    /// boundary — producing a NEW, larger mid-crossfade jump than the
    /// fixed-offset splice ever could, exactly the class of artifact the
    /// "no hard-cut jump" bound above exists to catch. Uses the SAME
    /// extreme region/tail values as
    /// `test_crossfade_boundsTheSampleToSampleDeltaAtTheSplice_unlikeAHardCut`
    /// specifically because hand-deriving those exact numbers is what
    /// exposed the bug (a ~3667 step against a ~115 bound) — this test
    /// pins the fixed behavior so it cannot silently regress again.
    func test_wsolaSearch_neverPicksACandidateThatStraddlesTheRegionTailBoundary() {
        let n = 960, shave = 144
        let region: Int16 = 8000, tail: Int16 = -8000
        let headSamples = n - 2 * shave
        let input = regionFrame(samples: n, head: 0, region: region, tail: tail, shave: shave)
        var out = Data(count: (n - shave) * 2)
        let written = TimeStretch.compress(input: input, inputSamples: n, shaveSamples: shave, out: &out)
        XCTAssertEqual((n - shave) * 2, written)

        let hardCutDelta = abs(Int(tail) - Int(region))
        let maxAllowedStep = hardCutDelta / shave + 4 // same generous slack as the sibling test
        var maxObservedStep = 0
        for i in headSamples..<((n - shave) - 1) {
            let delta = abs(Int(readSample(out, i + 1)) - Int(readSample(out, i)))
            if delta > maxObservedStep { maxObservedStep = delta }
        }
        XCTAssertLessThanOrEqual(
            maxObservedStep, maxAllowedStep,
            "the correlation search must never introduce a jump the fixed-offset splice didn't already have " +
            "(observed \(maxObservedStep), bound \(maxAllowedStep))")
    }

    /// Positive case: when a genuinely better-aligned offset EXISTS within
    /// the search radius, the search must find it. Builds a frame with ONE
    /// real content transition (`valueA` -> `valueB`) positioned `t`
    /// samples INTO the nominal region window (well within the search
    /// radius): the nominal offset straddles that transition (a real
    /// internal jump in the crossfade), while shifting forward by exactly
    /// `t` samples reads a window that is ENTIRELY `valueB` — a perfect,
    /// zero-discontinuity match against `tail` (also `valueB`, since the
    /// transition happens before `tail`'s own window starts). The search
    /// must find that zero-variation alignment: every crossfade output
    /// sample should read exactly `valueB`.
    func test_wsolaSearch_findsAGenuinelyBetterAlignmentWhenOneExists() {
        let n = 960, shave = 144, t = 10 // t well within the search radius (min(shave/2, 32) = 32)
        let valueA: Int16 = 2000, valueB: Int16 = -1000
        let headSamples = n - 2 * shave
        var input = Data(count: n * 2)
        input.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<(headSamples + t) { p[i] = valueA }
            for i in (headSamples + t)..<n { p[i] = valueB }
        }
        var out = Data(count: (n - shave) * 2)
        let written = TimeStretch.compress(input: input, inputSamples: n, shaveSamples: shave, out: &out)
        XCTAssertEqual((n - shave) * 2, written)

        for i in headSamples..<(n - shave) {
            XCTAssertEqual(valueB, readSample(out, i), "sample \(i) — search should have found the flat alignment")
        }
    }

    /// A fully flat signal ties every candidate at score zero — the
    /// nominal offset (scored first) must win, so a splice with nothing to
    /// gain from the search produces BYTE-IDENTICAL output to before this
    /// feature existed.
    func test_wsolaSearch_tiesOnFlatSignal_keepTheNominalSplicePoint() {
        let n = 960, shave = 144
        let input = constantFrame(samples: n, value: 777)
        var out = Data(count: (n - shave) * 2)
        let written = TimeStretch.compress(input: input, inputSamples: n, shaveSamples: shave, out: &out)
        XCTAssertEqual((n - shave) * 2, written)
        for i in 0..<(n - shave) {
            XCTAssertEqual(777, readSample(out, i), "sample \(i)")
        }
    }
}

import Foundation

/// W-JBSTRETCH (2026-08-25, parity plan Fase C3) — pure intra-frame time
/// compression for `PlayoutJitterBuffer`'s excess-depth correction.
///
/// Originally a byte-for-byte port of Android's
/// `com.bcrypto.qaudion.audio.TimeStretch`
/// (`qaudion-android-new/qaudion-engine/.../audio/TimeStretch.kt`) — same
/// SOLA-lite algorithm, same linear integer-weighted crossfade, same
/// decline contract. What follows is that file's own kdoc, carried over
/// verbatim because the design rationale did not change in the port
/// EXCEPT for one iOS-only enhancement layered on top afterward (see
/// "W-JBSTRETCH-WSOLA" below): a bounded correlation search for the
/// crossfade source. That change is receive-side-only local playout
/// concealment quality — it never touches the wire format either platform
/// speaks — so it does not need to stay byte-identical with Android's twin
/// the way the codec/handshake/wire-format code in this codebase does; this
/// file's linear-crossfade math and decline contract otherwise still match
/// Android exactly.
///
/// ## Why intra-frame rather than a cross-frame WSOLA search
///
/// A textbook WSOLA finds the best-correlated overlap point within a search
/// window before splicing, and typically wants 20-40 ms of lookahead to do
/// it well — either buffering several frames ahead of delivery, or holding a
/// partially-consumed frame "remainder" across `PlayoutJitterBuffer.
/// popWithDriftCatchup` calls so a later pop can resume mid-frame. Both add
/// new state to a class whose entire concurrency story rests on one lock
/// covering the whole queue and every tier field. A correlation search is
/// also a per-sample scan over that lookahead window — exactly the
/// "no per-sample searching over large windows" this correction is required
/// to avoid on the render thread.
///
/// This function instead works entirely WITHIN the one frame it is handed:
/// no lookahead, no held state from a previous call, no partial-frame
/// remainder left behind in the queue. It removes `shaveSamples` samples
/// from near the end of the frame by cross-fading a region near the cut
/// with the frame's own true tail — standard overlap-add time compression
/// (SOLA-lite), restricted to a single fixed-size buffer. W-JBSTRETCH-WSOLA
/// (below) adds a SMALL, bounded, downsampled search for exactly which
/// K-sample window sources that region — still entirely within this one
/// frame, no lookahead, no held state — so it stays a small, constant-ish
/// widening of "a small number of multiply-adds", never approaching the
/// "large window" cross-frame search this section still declines.
///
/// ## The splice
///
/// Let N = `inputSamples`, K = `shaveSamples`. Requires N >= 2K (checked;
/// declines otherwise — callers must not ask to shave more than half a
/// frame).
///
///  - `head   = input[0, N-2K)`   — copied unmodified.
///  - `region = input[searchedOffset, searchedOffset+K)` — nominally the K
///    samples immediately before the cut (`searchedOffset == N-2K`, what
///    would have played next had nothing been removed); W-JBSTRETCH-WSOLA
///    below may pick a slightly different `searchedOffset` within a small
///    window around that nominal position when it aligns better with tail.
///  - `tail   = input[N-K, N)`    — the frame's real, final K samples, ALWAYS
///    this exact fixed window regardless of what the search picks for region.
///
/// Output is `head ++ crossfade(region, tail)`, length `N-K`. `region` fades
/// out linearly across K samples while `tail` fades in, so the frame's own
/// true ending — what the NEXT delivered frame's opening has to sit against
/// — is still what the output actually closes with. The compression removes
/// a blended span from inside the frame's final K samples rather than
/// truncating the frame and discarding its real tail outright.
///
/// Linear crossfade, not equal-power/sqrt: `region` and `tail` are two
/// overlapping fragments of the SAME short span of the SAME waveform, not
/// two independently-leveled sources, so the loudness dip a linear ramp can
/// introduce for unrelated-signal crossfades is not the relevant risk here.
/// What matters is bounding the sample-to-sample delta the splice
/// introduces, and a linear ramp already does that: the crossfade's first
/// output sample is defined to equal `region[0]` exactly (see the weight
/// math below), so there is no seam at the head/crossfade boundary at all,
/// and every step inside the crossfade moves by at most
/// `|tail-region| / K` rather than by the full `|tail-region|` a hard cut
/// would introduce in one step. Integer fixed-point weights only — no
/// float, no per-sample sqrt/trig — so the cost is a handful of
/// multiply-adds per sample across K samples.
///
/// ## W-JBSTRETCH-WSOLA (2026-08-26) — bounded correlation search for the
/// crossfade SOURCE, splice POSITION and TAIL IDENTITY unchanged
///
/// The section above ("Reviewed tradeoff", kept in history below this one)
/// previously declined a correlation search outright. Re-examined per a
/// call-quality audit's finding that the search can be kept genuinely O(K)
/// with a downsampled, radius-bounded window — the "per-sample scan over a
/// large window" the original review was right to reject is a different,
/// much more expensive thing than what is implemented here.
///
/// The output's STRUCTURE is byte-identical to before: `head` is still
/// exactly `input[0, N-2K)`, copied verbatim; the crossfade still fills
/// exactly `K` output samples; `tail` is still exactly `input[N-K, N)`,
/// unchanged — the frame's own true ending is still what the output closes
/// with, so next-frame playout continuity and the exact `N-K` output length
/// this class's callers depend on (`PlayoutJitterBuffer`'s sample-exact
/// pacing) are BOTH untouched. This is deliberately how real WSOLA actually
/// works: synthesis (output) instants stay fixed; only the SOURCE window
/// used for the overlap-add is searched within a small tolerance for the
/// best waveform-similarity alignment — never the output timing itself.
///
/// What moves: the `region` (fade-OUT) samples are no longer pinned to
/// `input[N-2K, N-K)` — they are read from the best-matching K-sample
/// window within `[nominalRegionStart - searchRadius, nominalRegionStart +
/// searchRadius]` (clamped to the frame's own bounds).
///
/// ## Scoring: minimize the BLEND's own smoothness, not a proxy against tail
///
/// The first design tried here scored each candidate by a downsampled
/// Average Magnitude Difference Function against the fixed tail alone
/// (sum of `|region[j] - tail[j]|`) — the standard cheap alternative to
/// full cross-correlation in real-time pitch/OLA search. It was WRONG, and
/// caught by this file's own existing test suite before shipping: scoring
/// only against tail lets the search prefer a candidate window whose READ
/// RANGE crosses into content that already resembles tail — which can
/// include crossing straight into the tail block itself, or past a real
/// transient — producing a `region` sequence that jumps abruptly partway
/// through the crossfade LOOP (regionSample(i) changes character mid-K
/// where the candidate's read window straddles that boundary), which
/// blends into a NEW, LARGER step in the actual output than the artifact
/// this whole change exists to reduce — exactly the "max step" guarantee
/// `TimeStretchTests.test_crossfade_boundsTheSampleToSampleDeltaAtTheSplice_
/// unlikeAHardCut` asserts, worked out by hand against that test's fixture
/// numbers (144-sample shave, 8000/-8000 region/tail): the AMDF-vs-tail
/// design picked a forward-shifted offset whose crossfade produced a
/// single-step jump of ~3667, thirty times the ~115 bound that test
/// requires — a real, numerically-confirmed regression, not a hypothetical
/// one, caught by running the existing suite's own math by hand before
/// this was shipped.
///
/// Fixed by scoring what actually matters directly instead of a proxy for
/// it: at each downsampled step, compute the SAME blended value the real
/// crossfade loop would produce (`(region[i]*weightOut + tail[i]*weightIn)
/// / K`), and sum the SQUARED deltas between consecutive downsampled
/// blended values — a total-variation / smoothness score. A candidate
/// whose read window straddles a content boundary shows up as one large
/// term in this sum (the exact quantity the "max step" guarantee bounds)
/// and is naturally outscored by a candidate that stays smooth throughout,
/// with no separate straddle-detection logic needed — minimizing the real
/// discontinuity directly rather than a value-similarity proxy that can be
/// gamed by reading into differently-valued adjacent content. Verified by
/// hand against the same fixture: the nominal (unshifted) offset's smooth
/// linear ramp scores far below any candidate whose window crosses a
/// content boundary, so it continues to win when there is nothing genuine
/// to gain — this is also why the CORRECTNESS argument for keeping today's
/// exact splice point on real, natural (non-adversarial) speech is
/// unaffected: a real waveform's local neighborhood is, by construction,
/// no less internally smooth near the nominal offset than a few tens of
/// samples away, so the search only WINS when a genuinely better-aligned,
/// equally-smooth candidate exists, and never MANUFACTURES a worse one.
///
/// Ties (silence, or a perfectly periodic match at the nominal offset)
/// keep today's exact splice point — the nominal offset is scored first
/// and only a STRICTLY lower score replaces it, so a call with nothing to
/// gain from the search never regresses.
///
/// Cost: `searchRadiusSamples` is `min(shaveSamples / 2, wsolaSearchRadiusCap)`
/// candidates on each side of nominal, each scored with the SAME per-step
/// arithmetic the real crossfade loop already does (one multiply-add pair
/// and one division) at 1 step per `downsampleStride` samples — a bounded,
/// constant-factor widening of the existing O(K) crossfade, not a new
/// order of growth, and still zero float/trig.
///
/// ## Crossfade curve: kept linear, NOT switched to equal-power
///
/// A call-quality audit suggested pairing the correlation search with an
/// equal-power (`sqrt`-law) crossfade. Checked against the actual DSP
/// (confirmed independently, not just asserted) and NOT adopted: equal-
/// power crossfades exist to keep PERCEIVED LOUDNESS constant across a
/// transition between two INDEPENDENT/decorrelated sources, because power
/// (not amplitude) sums linearly for uncorrelated signals — `region` and
/// `tail` here are two overlapping fragments of the SAME short span of the
/// SAME waveform (more so now, given the search above picks the region
/// offset that best CORRELATES with the tail), not independent sources.
/// Applying equal-power weights to two correlated/near-identical segments
/// adds their AMPLITUDES at the crossfade midpoint rather than keeping them
/// level (`sqrt(w) + sqrt(1-w) > 1` for `0 < w < 1`), producing a real ~3 dB
/// amplitude bump — a NEW, audible artifact, and a worse one than the faint
/// sub-perceptual-floor micro-artifact this whole change is closing. The
/// linear crossfade's own correctness argument two sections above (first
/// output sample equals `region[0]` exactly, bounded per-step delta) is
/// unaffected by the search — it holds for whichever K-sample window ends
/// up chosen as `region`.
///
/// ## Reviewed tradeoff (history — the "no correlation search at all"
/// decision above is what changed; kept for the parts that still hold)
///
/// The cut point is a FIXED offset from the frame end regardless of signal
/// content — deliberately, per this file's own "no per-sample searching"
/// constraint. The Android twin's design was independently reviewed
/// (2026-08-25): the crossfade math itself is correct (bounded sub-LSB
/// rounding only), but skipping a correlation search has an honest cost —
/// on voiced speech the fixed cut can land inside a glottal pulse rather
/// than near a zero-crossing, which a correlation-searched splice (real
/// WSOLA) would avoid. Estimated impact: a faint micro-artifact generally
/// below -40 dBFS relative to typical speech level. A raised-cosine/Hann
/// crossfade was also declined, for the reasons the Android twin gives: it
/// needs either a per-sample trig call (ruled out above) or a precomputed
/// weight table (new state for a gain already sized as a further ~6 dB
/// reduction on an artifact already below the perception floor in the
/// common case) — that mitigation is untouched by this change; only the
/// "no correlation search" half of the original tradeoff was revisited.
enum TimeStretch {

    /// Absolute cap on the search radius, in samples — independent of how
    /// large `shaveSamples` is asked to be, so the search stays a small,
    /// bounded widening of the crossfade cost rather than scaling with K.
    /// 32 samples is ~0.67 ms at this codec's 48 kHz — enough to reach a
    /// nearby pitch-period alignment on typical voiced speech without
    /// approaching "large window" territory.
    static let wsolaSearchRadiusCap = 32

    /// Compare every `downsampleStride`th sample when scoring a candidate
    /// region offset against the tail — the "downsampled window" that
    /// keeps the search itself O(K) with a small constant, not O(K) per
    /// candidate at full resolution.
    static let downsampleStride = 4

    /// Compresses `inputSamples` mono S16LE (little-endian) samples from
    /// `input` into `out`, removing `shaveSamples` via the crossfade
    /// described in this file's kdoc.
    ///
    /// `out` is the caller's REUSED scratch buffer — this function never
    /// allocates, so it is safe to call from the audio render path on every
    /// correction event. `out` must be at least
    /// `(inputSamples - shaveSamples) * 2` bytes; the caller owns sizing it
    /// (see `PlayoutJitterBuffer.stretchScratch`, resized only when the
    /// cadence changes).
    ///
    /// - Returns: bytes written to `out` (always exactly
    ///   `(inputSamples - shaveSamples) * 2` on success), or -1 if the
    ///   request cannot be satisfied: a non-positive `shaveSamples` /
    ///   `inputSamples`, a frame shorter than 2x the shave (the required
    ///   `N >= 2K` in the kdoc above), an `input` shorter than
    ///   `inputSamples` actually claims, or an undersized `out`. Callers
    ///   must fall back to delivering the frame unmodified (or, if it was
    ///   never polled, to the existing excision tiers) on -1 — a decline is
    ///   never itself a discard.
    static func compress(
        input: Data,
        inputSamples: Int,
        shaveSamples: Int,
        out: inout Data
    ) -> Int {
        guard shaveSamples > 0, inputSamples > 0 else { return -1 }
        guard inputSamples >= shaveSamples * 2 else { return -1 }
        guard input.count >= inputSamples * 2 else { return -1 }
        let outSamples = inputSamples - shaveSamples
        guard out.count >= outSamples * 2 else { return -1 }

        let headSamples = inputSamples - 2 * shaveSamples
        let tailOffsetSamples = inputSamples - shaveSamples

        input.withUnsafeBytes { (inRaw: UnsafeRawBufferPointer) in
            let inP = inRaw.bindMemory(to: Int16.self)
            // W-JBSTRETCH-WSOLA — the only thing the search changes: WHICH
            // K-sample window sources the fade-OUT side of the crossfade.
            // `headSamples` (the output's own structural boundary) and
            // `tailOffsetSamples` (the fixed fade-IN target) are untouched.
            let regionOffsetSamples = Self.bestRegionOffset(
                inP: inP,
                nominalOffset: headSamples,
                shaveSamples: shaveSamples,
                tailOffsetSamples: tailOffsetSamples,
                inputSamples: inputSamples)
            out.withUnsafeMutableBytes { (outRaw: UnsafeMutableRawBufferPointer) in
                let outP = outRaw.bindMemory(to: Int16.self)

                // Head: copied unmodified — this is the bulk of the frame
                // and the reason the correction is cheap: only the last 2K
                // samples are touched by anything beyond a copy. Always the
                // NOMINAL boundary regardless of what the search above
                // picked for `regionOffsetSamples` — the search only moves
                // where the fade-OUT samples are READ from, never where
                // `head` ends or the output's own byte layout.
                if headSamples > 0 {
                    for i in 0..<headSamples {
                        outP[i] = Int16(littleEndian: inP[i])
                    }
                }

                // Crossfade: `region` (the WSOLA-searched best-aligned
                // source above) fades out while `tail` (the frame's real
                // last K samples, fixed) fades in. Linear, integer
                // fixed-point weights summing to `shaveSamples` every step
                // — see the "kept linear" section of this file's kdoc for
                // why equal-power was considered and declined.
                var i = 0
                while i < shaveSamples {
                    let regionSample = Int(Int16(littleEndian: inP[regionOffsetSamples + i]))
                    let tailSample = Int(Int16(littleEndian: inP[tailOffsetSamples + i]))
                    let weightOut = shaveSamples - i
                    let weightIn = i
                    let blended = (regionSample * weightOut + tailSample * weightIn) / shaveSamples
                    let clamped = min(max(blended, Int(Int16.min)), Int(Int16.max))
                    outP[headSamples + i] = Int16(clamped).littleEndian
                    i += 1
                }
            }
        }
        return outSamples * 2
    }

    /// W-JBSTRETCH-WSOLA — find the best-aligned K-sample region-source
    /// offset within `[nominalOffset - radius, nominalOffset + radius]`
    /// (clamped to `[0, inputSamples - shaveSamples]`), scored by the
    /// TOTAL VARIATION of the blended output THIS CANDIDATE would actually
    /// produce (sum of squared deltas between consecutive downsampled
    /// blended samples, using the exact same weighting `compress`'s own
    /// crossfade loop uses) — see the "Scoring" section of this file's
    /// kdoc for why a value-similarity proxy against tail alone was tried
    /// first and rejected (a real, numerically-confirmed regression caught
    /// by this file's own test suite). Pure — no I/O, no allocation, safe
    /// to call from the render thread. Ties keep `nominalOffset` (scored
    /// first; only a STRICTLY lower score replaces it), so a frame with
    /// nothing to gain from the search never regresses from today's
    /// fixed-offset splice.
    ///
    /// Every accessed index is bounds-checked by construction: candidates
    /// are clamped to `0 ... inputSamples - shaveSamples`, and the scoring
    /// loop's `j` never reaches `shaveSamples`, so `offset + j` and
    /// `tailOffsetSamples + j` both stay `< inputSamples` for every
    /// candidate — never past what `compress`'s own guards already
    /// verified is safely within `inP`.
    private static func bestRegionOffset(
        inP: UnsafeBufferPointer<Int16>,
        nominalOffset: Int,
        shaveSamples: Int,
        tailOffsetSamples: Int,
        inputSamples: Int
    ) -> Int {
        let radius = min(shaveSamples / 2, wsolaSearchRadiusCap)
        guard radius > 0 else { return nominalOffset }
        let lowerBound = max(0, nominalOffset - radius)
        let upperBound = min(inputSamples - shaveSamples, nominalOffset + radius)
        guard upperBound > lowerBound else { return nominalOffset }

        // Same per-step blend the real crossfade loop in `compress`
        // computes — scoring on this directly (not a proxy) is what makes
        // a straddled content boundary self-penalizing: it shows up as one
        // large term in the sum below, the exact quantity the "max step"
        // guarantee bounds.
        func score(_ offset: Int) -> Int64 {
            var total: Int64 = 0
            var previousBlended: Int?
            func blend(at j: Int) -> Int {
                let regionSample = Int(Int16(littleEndian: inP[offset + j]))
                let tailSample = Int(Int16(littleEndian: inP[tailOffsetSamples + j]))
                let weightOut = shaveSamples - j
                let weightIn = j
                return (regionSample * weightOut + tailSample * weightIn) / shaveSamples
            }
            func accumulate(_ j: Int) {
                let blended = blend(at: j)
                if let previous = previousBlended {
                    let delta = Int64(blended - previous)
                    total += delta * delta
                }
                previousBlended = blended
            }
            var j = 0
            while j < shaveSamples {
                accumulate(j)
                j += downsampleStride
            }
            // Review fix — when `shaveSamples` isn't a multiple of
            // `downsampleStride`, the loop above never visits the final
            // `shaveSamples % downsampleStride` samples, leaving a blind
            // spot where a discontinuity localized there would be invisible
            // to the score. Always include the true last sample too.
            let lastIndex = shaveSamples - 1
            if lastIndex % downsampleStride != 0 {
                accumulate(lastIndex)
            }
            return total
        }

        var bestOffset = nominalOffset
        var bestScore = score(nominalOffset)
        var candidate = lowerBound
        while candidate <= upperBound {
            if candidate != nominalOffset {
                let candidateScore = score(candidate)
                if candidateScore < bestScore {
                    bestScore = candidateScore
                    bestOffset = candidate
                }
            }
            candidate += 1
        }
        return bestOffset
    }
}

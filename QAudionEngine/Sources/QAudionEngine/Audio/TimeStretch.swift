import Foundation

/// W-JBSTRETCH (2026-08-25, parity plan Fase C3) — pure intra-frame time
/// compression for `PlayoutJitterBuffer`'s excess-depth correction.
///
/// Byte-for-byte port of Android's `com.bcrypto.qaudion.audio.TimeStretch`
/// (`qaudion-android-new/qaudion-engine/.../audio/TimeStretch.kt`) — same
/// fixed-splice SOLA-lite algorithm, same linear integer-weighted crossfade,
/// same decline contract. What follows is that file's own kdoc, carried over
/// verbatim because the design rationale did not change in the port.
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
/// from near the end of the frame by cross-fading the region immediately
/// before the cut with the frame's own true tail — standard overlap-add
/// time compression (SOLA-lite), restricted to a single fixed-size buffer
/// with a FIXED splice offset (no correlation search) so the cost is a
/// constant, small number of multiply-adds regardless of content.
///
/// ## The splice
///
/// Let N = `inputSamples`, K = `shaveSamples`. Requires N >= 2K (checked;
/// declines otherwise — callers must not ask to shave more than half a
/// frame).
///
///  - `head   = input[0, N-2K)`   — copied unmodified.
///  - `region = input[N-2K, N-K)` — the K samples immediately before the cut:
///    what would have played next had nothing been removed.
///  - `tail   = input[N-K, N)`    — the frame's real, final K samples.
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
/// ## Reviewed tradeoff: fixed splice point, no zero-crossing / correlation search
///
/// The cut point is a FIXED offset from the frame end regardless of signal
/// content — deliberately, per this file's own "no per-sample searching"
/// constraint. The Android twin's design was independently reviewed
/// (2026-08-25): the crossfade math itself is correct (bounded sub-LSB
/// rounding only), but skipping a correlation search has an honest cost —
/// on voiced speech the fixed cut can land inside a glottal pulse rather
/// than near a zero-crossing, which a correlation-searched splice (real
/// WSOLA) would avoid. Estimated impact: a faint micro-artifact generally
/// below -40 dBFS relative to typical speech level. Two cheap mitigations
/// (a small zero-crossing bias before the cut; a raised-cosine/Hann
/// crossfade) were deliberately NOT adopted, for the same reasons the
/// Android twin gives: the former reintroduces a per-frame search this
/// class is required to avoid, and the latter needs either a per-sample
/// trig call (ruled out above) or a precomputed weight table (new state for
/// a gain already sized as a further ~6 dB reduction on an artifact already
/// below the perception floor in the common case). If a future measurement
/// on real calls shows this artifact is actually audible, the Hann-window
/// variant is the recommended next step — it stays O(K), same as this one.
enum TimeStretch {

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
        let regionOffsetSamples = headSamples
        let tailOffsetSamples = inputSamples - shaveSamples

        input.withUnsafeBytes { (inRaw: UnsafeRawBufferPointer) in
            let inP = inRaw.bindMemory(to: Int16.self)
            out.withUnsafeMutableBytes { (outRaw: UnsafeMutableRawBufferPointer) in
                let outP = outRaw.bindMemory(to: Int16.self)

                // Head: copied unmodified — this is the bulk of the frame
                // and the reason the correction is cheap: only the last 2K
                // samples are touched by anything beyond a copy.
                if headSamples > 0 {
                    for i in 0..<headSamples {
                        outP[i] = Int16(littleEndian: inP[i])
                    }
                }

                // Crossfade: `region` (just before the cut) fades out while
                // `tail` (the frame's real last K samples) fades in.
                // Linear, integer fixed-point weights summing to
                // `shaveSamples` every step.
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
}

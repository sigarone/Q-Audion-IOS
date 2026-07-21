import Foundation

/// Pure, dependency-free voicing / pitch-period decision used by
/// `PitchExtractor`. Extracted into its own type (Foundation only — no
/// AVFoundation, no WebRTC) so the gate is unit-testable on the macOS
/// `swift test` runner and cannot be silently reverted by a later refactor
/// of the DSP file.
///
/// ## Why this exists (bug W-VOICEZERO, 2026-07-21)
///
/// The original `PitchExtractor` compared a **raw, un-normalised**
/// autocorrelation against a threshold that only makes sense for a
/// normalised correlation coefficient:
///
/// ```swift
/// for lag in minLag..<min(maxLag, n / 2) {
///     var corr: Float = 0
///     for i in 0..<(n - lag) { corr += samples[i] * samples[i + lag] }
///     corr /= Float(n - lag)          // <-- mean of products, NOT r(lag)
///     if corr > bestCorr { ... }
/// }
/// let voiced = bestCorr > 0.3 && ...  // <-- threshold for r ∈ [-1, 1]
/// ```
///
/// For a periodic signal the mean of `x[i]·x[i+T]` at the true period is
/// approximately the signal **power**, i.e. `rms²`. So `bestCorr > 0.3`
/// silently means `rms > 0.548` — roughly −5 dBFS RMS over a 20 ms frame,
/// a level decoded speech never reaches. Measured on the live fleet
/// (`call.audio.diag`, iOS 1.0.826, call e65013b7): whole-call RX
/// `rx_rms_pct = 3.8`, `rx_peak_pct = 59.5` — i.e. `rms ≈ 0.038`, giving
/// `bestCorr ≈ 0.0014`, ~200× below the gate. `voiced` was therefore
/// permanently `false`, and because `StressDetector`, `VoiceHealthMonitor`,
/// `SpeechRateAnalyzer` and `ConfidenceIndicator` all early-return on
/// `!pitch.voiced`, every Guardian-ribbon gauge (STRESS / BREATH·HNR /
/// PITCH) read exactly 0 on every call.
///
/// The unit tests did not catch it because `TestAudioHelpers.makeSinePCM`
/// defaults to `amplitude: 0.8` → `rms = 0.566` → `bestCorr ≈ 0.320`, which
/// clears the 0.3 gate by 6 %. Any quieter input failed.
///
/// The fix normalises the correlation to a true coefficient in `[-1, 1]`
/// (`r(τ) = Σx[i]x[i+τ] / √(Σx[i]² · Σx[i+τ]²)`), which is what Android's
/// `PitchExtractor.normalizedAutocorrelationAt` already does and what makes
/// Android's own `voicedThreshold = 0.3f` amplitude-invariant.
public enum VoicedDecisionPolicy {

    /// Minimum normalised correlation for a frame to count as voiced.
    /// Same numeric value and same (normalised) semantics as Android's
    /// `PitchExtractor.voicedThreshold`.
    public static let voicedCorrelationThreshold: Float = 0.3

    /// Noise floor below which a frame is treated as silence and never
    /// analysed (≈ −40 dBFS). Unchanged from the original implementation.
    public static let minRms: Float = 0.01

    /// A correlation peak is accepted as the fundamental period when it
    /// reaches this fraction of the global maximum. Selecting the SMALLEST
    /// qualifying local maximum (rather than the global one) is the classic
    /// octave-error guard: for a periodic signal `r(2T) ≈ r(T)`, so a plain
    /// arg-max frequently locks onto 2T and reports F0/2.
    public static let peakSelectionRatio: Float = 0.85

    public struct PeriodEstimate: Equatable {
        /// Estimated period in samples, sub-sample refined. 0 when unknown.
        public let lag: Float
        /// Normalised correlation at that period, in `[-1, 1]`.
        public let correlation: Float

        public init(lag: Float, correlation: Float) {
            self.lag = lag
            self.correlation = correlation
        }
    }

    /// RMS of a normalised `[-1, 1]` sample buffer. Double accumulator so a
    /// 960-sample frame cannot lose precision.
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for s in samples {
            let v = Double(s)
            sum += v * v
        }
        return Float((sum / Double(samples.count)).squareRoot())
    }

    /// Normalised autocorrelation `r(lag) ∈ [-1, 1]` over the overlapping
    /// window. Mirrors Android's `normalizedAutocorrelationAt`.
    public static func normalizedAutocorrelation(_ samples: [Float], lag: Int) -> Float {
        let n = samples.count - lag
        guard lag > 0, n > 0 else { return 0 }
        var cross = 0.0
        var energy0 = 0.0
        var energyLag = 0.0
        for i in 0..<n {
            let a = Double(samples[i])
            let b = Double(samples[i + lag])
            cross += a * b
            energy0 += a * a
            energyLag += b * b
        }
        let denom = (energy0 * energyLag).squareRoot()
        guard denom > 1e-12 else { return 0 }
        return Float(cross / denom)
    }

    /// `r(lag)` for every lag in `minLag...maxLag`; index 0 corresponds to
    /// `minLag`. Uses a prefix-sum-of-squares table so the two energy terms
    /// are O(1) per lag — total cost stays the same as the original
    /// single-accumulator loop (~272k multiply-adds for a 960-sample frame
    /// over lags 80…480), which matters because this runs synchronously on
    /// the RX dispatch thread (2026-07-04 never-block rules).
    public static func correlationCurve(_ samples: [Float], minLag: Int, maxLag: Int) -> [Float] {
        guard minLag > 0, maxLag >= minLag, samples.count > maxLag else { return [] }
        let n = samples.count

        var prefixSq = [Double](repeating: 0, count: n + 1)
        for i in 0..<n {
            let v = Double(samples[i])
            prefixSq[i + 1] = prefixSq[i] + v * v
        }

        var curve = [Float](repeating: 0, count: maxLag - minLag + 1)
        for lag in minLag...maxLag {
            let m = n - lag
            if m <= 0 { continue }
            var cross = 0.0
            for i in 0..<m {
                cross += Double(samples[i]) * Double(samples[i + lag])
            }
            let energy0 = prefixSq[m] - prefixSq[0]
            let energyLag = prefixSq[n] - prefixSq[lag]
            let denom = (energy0 * energyLag).squareRoot()
            curve[lag - minLag] = denom > 1e-12 ? Float(cross / denom) : 0
        }
        return curve
    }

    /// Pick the fundamental period: the smallest local maximum of `r` that
    /// reaches `peakSelectionRatio × max(r)`, refined by parabolic
    /// interpolation. Falls back to the global arg-max when no interior
    /// local maximum qualifies (e.g. the true period is longer than the
    /// searchable range).
    public static func bestPeriod(_ samples: [Float], minLag: Int, maxLag: Int) -> PeriodEstimate {
        let curve = correlationCurve(samples, minLag: minLag, maxLag: maxLag)
        guard !curve.isEmpty else { return PeriodEstimate(lag: 0, correlation: 0) }

        var maxCorr = curve[0]
        var maxIndex = 0
        for i in 1..<curve.count where curve[i] > maxCorr {
            maxCorr = curve[i]
            maxIndex = i
        }

        // Nothing is going to be declared voiced anyway — skip peak picking
        // and report the arg-max so the caller can log a real number.
        guard maxCorr > voicedCorrelationThreshold else {
            return PeriodEstimate(lag: Float(minLag + maxIndex), correlation: maxCorr)
        }

        let cut = peakSelectionRatio * maxCorr
        var i = 1
        while i < curve.count - 1 {
            if curve[i] >= cut, curve[i] > curve[i - 1], curve[i] >= curve[i + 1] {
                let delta = parabolicPeakOffset(curve[i - 1], curve[i], curve[i + 1])
                return PeriodEstimate(lag: Float(minLag + i) + delta, correlation: curve[i])
            }
            i += 1
        }
        return PeriodEstimate(lag: Float(minLag + maxIndex), correlation: maxCorr)
    }

    /// Sub-sample offset of the parabola vertex through `(-1, a) (0, b) (1, c)`,
    /// clamped to ±0.5 sample.
    public static func parabolicPeakOffset(_ a: Float, _ b: Float, _ c: Float) -> Float {
        let denom = 2 * (a - 2 * b + c)
        guard abs(denom) > 1e-12 else { return 0 }
        return max(-0.5, min(0.5, (a - c) / denom))
    }

    /// The single voicing gate. Amplitude-invariant by construction:
    /// `correlation` must be a NORMALISED coefficient.
    public static func isVoiced(correlation: Float,
                                f0Hz: Float,
                                rms: Float,
                                minF0: Float,
                                maxF0: Float) -> Bool {
        return rms > minRms
            && correlation > voicedCorrelationThreshold
            && f0Hz >= minF0
            && f0Hz <= maxF0
    }
}

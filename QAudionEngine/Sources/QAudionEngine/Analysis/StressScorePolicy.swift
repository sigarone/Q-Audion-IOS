import Foundation

/// Pure, dependency-free composite-stress scoring used by `StressDetector`.
/// Foundation only, so it runs under `swift test` on the macOS CI runner.
///
/// ## Why this exists (bug W-VOICEZERO follow-on, 2026-07-21)
///
/// Once the voicing gate is fixed (see `VoicedDecisionPolicy`) the old iOS
/// composite would immediately peg the STRESS gauge to "agitated" on normal
/// conversational speech. Old formula:
///
/// ```swift
/// let score = min(1.0, (jitter * 10 + shimmer * 5) / 2.0)   // jitter/shimmer are RATIOS
/// ```
///
/// Android has already field-calibrated the same metrics for phone audio
/// with hardware AEC/NS/AGC (`StressDetector.kt`: `JITTER_NORMAL = 6 %`,
/// `SHIMMER_NORMAL = 12 %`, "tuned so normal conversational speech scores
/// 10-35 %"). Substituting those *measured normal* values into the old iOS
/// formula gives `(0.06·10 + 0.12·5) / 2 = 0.60` → the UI reads 60/100,
/// which `InCallScreen.stressStatusWord` classifies as "agitated"
/// (`pct >= 60`) for a perfectly calm speaker. So the composite is ported
/// from Android instead: normalise each metric against its calibrated
/// [normal, high] range, apply the same weights, and EMA-smooth.
///
/// Units note: `VoiceAnalysisResult.Stress.jitter` / `.shimmer` stay
/// **ratios** on iOS (the security sheet renders them as `jitter * 100`,
/// and `ConfidenceIndicator` compares them against 0.05 / 0.1), so the
/// percent conversion happens inside `compositeScore` only.
public enum StressScorePolicy {

    /// Frames of voiced history kept for the jitter/shimmer/σ statistics.
    /// 25 analysed frames ≈ 2.5 s at the default `analysisRate = 5`
    /// (100 ms per analysed frame) — same window as Android's
    /// `PitchExtractor` history ring, so the calibrated ranges below mean
    /// the same thing on both platforms.
    public static let historyWindow = 25

    // Calibrated ranges — byte-for-byte the Android constants
    // (qaudion-engine/.../analysis/StressDetector.kt).
    public static let jitterNormalPct: Float = 6.0
    public static let jitterHighPct: Float = 15.0
    public static let shimmerNormalPct: Float = 12.0
    public static let shimmerHighPct: Float = 25.0
    public static let f0StdNormalHz: Float = 35.0
    public static let f0StdHighHz: Float = 90.0

    public static let weightJitter: Float = 0.30
    public static let weightShimmer: Float = 0.30
    public static let weightF0Variation: Float = 0.25
    public static let weightTremor: Float = 0.15

    /// EMA factor for the composite score (low = smooth, less reactive).
    public static let emaAlpha: Float = 0.08
    /// Per-frame decay applied while unvoiced, so the gauge glides to rest
    /// between words instead of snapping to 0 (Android parity).
    public static let unvoicedDecay: Float = 0.85

    /// Mean absolute successive difference divided by the mean — the shared
    /// shape of both jitter (over F0) and shimmer (over RMS). Returns a
    /// RATIO, not a percentage.
    public static func relativeMeanAbsDiff(_ values: [Float]) -> Float {
        guard values.count > 1 else { return 0 }
        var diffSum: Float = 0
        for i in 1..<values.count {
            diffSum += abs(values[i] - values[i - 1])
        }
        let meanDiff = diffSum / Float(values.count - 1)
        let mean = values.reduce(0, +) / Float(values.count)
        return mean > 1e-6 ? meanDiff / mean : 0
    }

    /// Sample standard deviation (n-1), matching Android's `computeStdDev`.
    public static func stdDev(_ values: [Float]) -> Float {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Float(values.count)
        var variance: Float = 0
        for v in values {
            let d = v - mean
            variance += d * d
        }
        return (variance / Float(values.count - 1)).squareRoot()
    }

    /// Tremor proxy in `[0, 1]`: fraction of direction changes in the F0
    /// contour (Android's `estimateTremor`).
    public static func tremor(_ values: [Float]) -> Float {
        guard values.count >= 4 else { return 0 }
        var signChanges = 0
        for i in 2..<values.count {
            let d1 = values[i - 1] - values[i - 2]
            let d2 = values[i] - values[i - 1]
            if d1 * d2 < 0 { signChanges += 1 }
        }
        let maxChanges = Float(values.count - 2)
        guard maxChanges > 0 else { return 0 }
        return min(1, max(0, Float(signChanges) / maxChanges))
    }

    /// Map `value` from `[normal, high]` onto `[0, 1]`, clamped.
    public static func normalize(_ value: Float, normal: Float, high: Float) -> Float {
        guard high > normal else { return value > normal ? 1 : 0 }
        return min(1, max(0, (value - normal) / (high - normal)))
    }

    /// Composite stress in `[0, 1]` (the UI multiplies by 100, so this is
    /// numerically Android's 0-100 score / 100).
    ///
    /// - Parameters:
    ///   - jitter: relative F0 jitter as a RATIO (0.06 == 6 %).
    ///   - shimmer: relative amplitude shimmer as a RATIO.
    ///   - f0StdDev: standard deviation of the voiced F0 history, in Hz.
    ///   - tremor: `[0, 1]` contour-reversal proxy.
    public static func compositeScore(jitter: Float,
                                      shimmer: Float,
                                      f0StdDev: Float,
                                      tremor: Float) -> Float {
        let j = normalize(jitter * 100, normal: jitterNormalPct, high: jitterHighPct)
        let s = normalize(shimmer * 100, normal: shimmerNormalPct, high: shimmerHighPct)
        let v = normalize(f0StdDev, normal: f0StdNormalHz, high: f0StdHighHz)
        let t = min(1, max(0, tremor))
        let raw = weightJitter * j
            + weightShimmer * s
            + weightF0Variation * v
            + weightTremor * t
        return min(1, max(0, raw))
    }

    /// One EMA step, clamped to `[0, 1]`.
    public static func smooth(previous: Float, raw: Float) -> Float {
        let next = emaAlpha * raw + (1 - emaAlpha) * previous
        return min(1, max(0, next))
    }
}

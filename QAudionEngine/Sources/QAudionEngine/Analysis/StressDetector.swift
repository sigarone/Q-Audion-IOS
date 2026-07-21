import Foundation

/// Vocal-stress indicators (jitter, shimmer, composite score) over the
/// voiced-frame history.
///
/// The composite scoring lives in `StressScorePolicy` — see its doc comment
/// for why the old inline `min(1, (jitter*10 + shimmer*5)/2)` had to go
/// (it reads 60/100 = "agitated" for a speaker Android measures as calm).
public final class StressDetector {
    private var pitchHistory: [Float] = []
    private var amplitudeHistory: [Float] = []
    private let windowSize = StressScorePolicy.historyWindow

    /// EMA-smoothed composite in [0, 1]. Survives unvoiced frames (decayed)
    /// so the gauge glides instead of flickering to 0 between words.
    private var smoothedScore: Float = 0

    public init() {}

    public func analyze(pitch: VoiceAnalysisResult.Pitch) -> VoiceAnalysisResult.Stress {
        guard pitch.voiced else {
            smoothedScore *= StressScorePolicy.unvoicedDecay
            return VoiceAnalysisResult.Stress(score: smoothedScore, jitter: 0, shimmer: 0)
        }

        pitchHistory.append(pitch.f0Hz)
        amplitudeHistory.append(pitch.rms)
        if pitchHistory.count > windowSize { pitchHistory.removeFirst() }
        if amplitudeHistory.count > windowSize { amplitudeHistory.removeFirst() }

        // Ratios, not percentages — the security sheet renders them as
        // `jitter * 100` and ConfidenceIndicator compares against 0.05/0.1.
        let jitter = StressScorePolicy.relativeMeanAbsDiff(pitchHistory)
        let shimmer = StressScorePolicy.relativeMeanAbsDiff(amplitudeHistory)

        // Too little history for a meaningful statistic — report the metrics
        // but hold the previous smoothed score (Android does the same).
        guard pitchHistory.count >= 3 else {
            return VoiceAnalysisResult.Stress(score: smoothedScore, jitter: jitter, shimmer: shimmer)
        }

        let raw = StressScorePolicy.compositeScore(
            jitter: jitter,
            shimmer: shimmer,
            f0StdDev: StressScorePolicy.stdDev(pitchHistory),
            tremor: StressScorePolicy.tremor(pitchHistory)
        )
        smoothedScore = StressScorePolicy.smooth(previous: smoothedScore, raw: raw)
        return VoiceAnalysisResult.Stress(score: smoothedScore, jitter: jitter, shimmer: shimmer)
    }

    public func reset() {
        pitchHistory.removeAll()
        amplitudeHistory.removeAll()
        smoothedScore = 0
    }
}

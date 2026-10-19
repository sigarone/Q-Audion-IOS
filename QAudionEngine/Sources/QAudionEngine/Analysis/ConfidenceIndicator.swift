import Foundation

/// Display-only confidence of the analysed voice, 0...1. Nothing that scores,
/// verifies or decides reads it.
///
/// A voiced window starts at 0.5 and gains a bonus per plausible reading. A
/// reading that is not valid right now (HNR before three voiced windows, speech
/// rate before two seconds of speech, jitter and shimmer before three voiced
/// windows) earns nothing: unknown is not a pass.
/// The HNR and speech-rate bonuses used to be granted on numbers that were not
/// measurements (a lag-1 correlation that sat above 10 dB for any smooth
/// signal; a counter that grew without bound), so they almost always fired;
/// they now fire only on real readings, which makes the score read lower
/// during the first seconds of a call and on noisy voices.
public final class ConfidenceIndicator {
    public init() {}

    public func analyze(pitch: VoiceAnalysisResult.Pitch, stress: VoiceAnalysisResult.Stress,
                        health: VoiceAnalysisResult.VoiceHealth, speechRate: VoiceAnalysisResult.SpeechRate) -> Float {
        guard pitch.voiced else { return 0 }
        var score: Float = 0.5
        if pitch.f0Valid && pitch.f0Hz > 80 && pitch.f0Hz < 400 { score += 0.1 }
        if stress.score < 0.5 { score += 0.1 }
        if health.hnrValid && health.hnr > 10 { score += 0.1 }
        if speechRate.valid && speechRate.syllablesPerSec > 2 && speechRate.syllablesPerSec < 8 { score += 0.1 }
        // Jitter and shimmer are 0 while `stress.valid` is false: that is "no reading", not a very steady
        // voice, so the two bonuses are granted on a reading only.
        if stress.valid && stress.jitter < 0.05 { score += 0.05 }
        if stress.valid && stress.shimmer < 0.1 { score += 0.05 }
        return min(1.0, score)
    }
}

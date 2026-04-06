import Foundation

public final class ConfidenceIndicator {
    public init() {}

    public func analyze(pitch: VoiceAnalysisResult.Pitch, stress: VoiceAnalysisResult.Stress,
                        health: VoiceAnalysisResult.VoiceHealth, speechRate: VoiceAnalysisResult.SpeechRate) -> Float {
        guard pitch.voiced else { return 0 }
        var score: Float = 0.5
        if pitch.f0Hz > 80 && pitch.f0Hz < 400 { score += 0.1 }
        if stress.score < 0.5 { score += 0.1 }
        if health.hnr > 10 { score += 0.1 }
        if speechRate.syllablesPerSec > 2 && speechRate.syllablesPerSec < 8 { score += 0.1 }
        if stress.jitter < 0.05 { score += 0.05 }
        if stress.shimmer < 0.1 { score += 0.05 }
        return min(1.0, score)
    }
}

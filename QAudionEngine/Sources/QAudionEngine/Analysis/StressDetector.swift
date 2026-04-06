import Foundation

public final class StressDetector {
    private var pitchHistory: [Float] = []
    private var amplitudeHistory: [Float] = []
    private let windowSize = 50

    public init() {}

    public func analyze(pitch: VoiceAnalysisResult.Pitch) -> VoiceAnalysisResult.Stress {
        guard pitch.voiced else { return VoiceAnalysisResult.Stress(score: 0, jitter: 0, shimmer: 0) }
        pitchHistory.append(pitch.f0Hz)
        amplitudeHistory.append(pitch.rms)
        if pitchHistory.count > windowSize { pitchHistory.removeFirst() }
        if amplitudeHistory.count > windowSize { amplitudeHistory.removeFirst() }

        let jitter = computeJitter(pitchHistory)
        let shimmer = computeShimmer(amplitudeHistory)
        let score = min(1.0, (jitter * 10 + shimmer * 5) / 2.0)
        return VoiceAnalysisResult.Stress(score: score, jitter: jitter, shimmer: shimmer)
    }

    private func computeJitter(_ values: [Float]) -> Float {
        guard values.count > 1 else { return 0 }
        var sum: Float = 0
        for i in 1..<values.count { sum += abs(values[i] - values[i-1]) }
        let mean = values.reduce(0, +) / Float(values.count)
        return mean > 0 ? (sum / Float(values.count - 1)) / mean : 0
    }

    private func computeShimmer(_ values: [Float]) -> Float {
        guard values.count > 1 else { return 0 }
        var sum: Float = 0
        for i in 1..<values.count { sum += abs(values[i] - values[i-1]) }
        let mean = values.reduce(0, +) / Float(values.count)
        return mean > 0 ? (sum / Float(values.count - 1)) / mean : 0
    }
}

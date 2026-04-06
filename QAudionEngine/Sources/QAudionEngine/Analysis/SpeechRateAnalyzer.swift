import Foundation

public final class SpeechRateAnalyzer {
    private var speechSegments: [Bool] = []
    private var syllableCount: Int = 0
    private var totalFrames: Int = 0
    private let rmsThreshold: Float = 0.02

    public init() {}

    public func analyze(pcmFrame: Data, pitch: VoiceAnalysisResult.Pitch) -> VoiceAnalysisResult.SpeechRate {
        totalFrames += 1
        let isSpeaking = pitch.voiced && pitch.rms > rmsThreshold
        speechSegments.append(isSpeaking)
        if speechSegments.count > 250 { speechSegments.removeFirst() }

        // Detect syllable boundaries (voiced -> unvoiced transitions)
        if speechSegments.count >= 2 && speechSegments[speechSegments.count - 2] && !speechSegments[speechSegments.count - 1] {
            syllableCount += 1
        }

        let durationSec = Float(speechSegments.count) * 0.02
        let rate = durationSec > 0 ? Float(syllableCount) / durationSec : 0
        let pauseFrames = speechSegments.filter { !$0 }.count
        let pauseRatio = Float(pauseFrames) / max(1, Float(speechSegments.count))

        return VoiceAnalysisResult.SpeechRate(syllablesPerSec: rate, pauseRatio: pauseRatio, isSpeaking: isSpeaking)
    }

    public func reset() { speechSegments.removeAll(); syllableCount = 0; totalFrames = 0 }
}

import Foundation

public struct VoiceAnalysisResult {
    public struct Pitch { public var f0Hz: Float; public var voiced: Bool; public var rms: Float }
    public struct Stress { public var score: Float; public var jitter: Float; public var shimmer: Float }
    public struct VoiceHealth { public var hnr: Float; public var breathiness: Float }
    public struct SpeechRate { public var syllablesPerSec: Float; public var pauseRatio: Float; public var isSpeaking: Bool }
    public struct Formants { public var f1: Float; public var f2: Float; public var f3: Float; public var f4: Float }

    public var pitch: Pitch
    public var stress: Stress
    public var voiceHealth: VoiceHealth
    public var speechRate: SpeechRate
    public var formants: Formants
    public var confidence: Float

    public init(pitch: Pitch = Pitch(f0Hz: 0, voiced: false, rms: 0),
                stress: Stress = Stress(score: 0, jitter: 0, shimmer: 0),
                voiceHealth: VoiceHealth = VoiceHealth(hnr: 0, breathiness: 0),
                speechRate: SpeechRate = SpeechRate(syllablesPerSec: 0, pauseRatio: 0, isSpeaking: false),
                formants: Formants = Formants(f1: 0, f2: 0, f3: 0, f4: 0),
                confidence: Float = 0) {
        self.pitch = pitch; self.stress = stress; self.voiceHealth = voiceHealth
        self.speechRate = speechRate; self.formants = formants; self.confidence = confidence
    }
}

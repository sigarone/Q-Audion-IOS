import Foundation

/// One analysis of the received voice.
///
/// Every measurement says whether it is a real reading RIGHT NOW. A value that
/// is not valid is exactly 0 and carries a false flag: it is never a seed, a
/// default "typical" figure or the last good reading, so a consumer that shows
/// numbers can show a dash instead of a made-up figure by looking at the flag.
public struct VoiceAnalysisResult {
    public struct Pitch {
        public var f0Hz: Float; public var voiced: Bool; public var rms: Float
        /// `f0Hz` is a measurement of the current window (voiced and in range).
        public var f0Valid: Bool
        /// 1 - normalised difference of the pitch search at the integer lag, 0...1.
        /// Reported for voiced and unvoiced windows alike (0 below the silence floor).
        public var periodicity: Float
        public init(f0Hz: Float = 0, voiced: Bool = false, rms: Float = 0, f0Valid: Bool? = nil,
                    periodicity: Float = 0) {
            self.f0Hz = f0Hz; self.voiced = voiced; self.rms = rms
            self.f0Valid = f0Valid ?? (voiced && f0Hz > 0)
            self.periodicity = periodicity
        }
    }
    public struct Stress {
        public var score: Float; public var jitter: Float; public var shimmer: Float
        /// `jitter` and `shimmer` are measurements of this step: it is voiced and the
        /// history of voiced steps holds at least three values. They are 0 while it
        /// is false, and a consumer that shows them shows a dash instead.
        public var valid: Bool
        public init(score: Float = 0, jitter: Float = 0, shimmer: Float = 0, valid: Bool = false) {
            self.score = score; self.jitter = jitter; self.shimmer = shimmer; self.valid = valid
        }
    }
    public struct VoiceHealth {
        /// Harmonics-to-noise ratio in dB. Meaningful only while `hnrValid`.
        public var hnr: Float
        /// Mean of 1 - r over the same readings as `hnr` (0...1); 0 while `hnrValid` is false.
        public var breathiness: Float
        /// At least three voiced steps measured, the last of them no more than one
        /// second (10 steps) of audio ago.
        public var hnrValid: Bool
        public init(hnr: Float = 0, breathiness: Float = 0, hnrValid: Bool = false) {
            self.hnr = hnr; self.breathiness = breathiness; self.hnrValid = hnrValid
        }
    }
    public struct SpeechRate {
        /// Syllable nuclei per second of speaking time over the last 6 s of audio.
        public var syllablesPerSec: Float
        /// Share of the last 6 s (of the audio received so far, during the first
        /// 6 s) taken by pauses longer than 300 ms. Meaningful only while `valid`.
        public var pauseRatio: Float
        /// At least one of the last 10 ms envelope frames of the step is within 25 dB
        /// of the loudest voiced frame of the last 6 s. Unrelated to `valid`.
        public var isSpeaking: Bool
        /// At least two seconds of speaking time inside the last 6 s.
        /// `syllablesPerSec` and `pauseRatio` are 0 while this is false.
        public var valid: Bool
        public init(syllablesPerSec: Float = 0, pauseRatio: Float = 0, isSpeaking: Bool = false, valid: Bool = false) {
            self.syllablesPerSec = syllablesPerSec; self.pauseRatio = pauseRatio
            self.isSpeaking = isSpeaking; self.valid = valid
        }
    }
    public struct Formants {
        public var f1: Float; public var f2: Float; public var f3: Float; public var f4: Float
        /// A formant that was not found is exactly 0 with its flag false.
        /// F3 and F4 are not measured: they are always 0 / not found.
        public var f1Found: Bool; public var f2Found: Bool; public var f3Found: Bool; public var f4Found: Bool
        public init(f1: Float = 0, f2: Float = 0, f3: Float = 0, f4: Float = 0,
                    f1Found: Bool? = nil, f2Found: Bool? = nil, f3Found: Bool? = nil, f4Found: Bool? = nil) {
            self.f1 = f1; self.f2 = f2; self.f3 = f3; self.f4 = f4
            self.f1Found = f1Found ?? (f1 > 0); self.f2Found = f2Found ?? (f2 > 0)
            self.f3Found = f3Found ?? (f3 > 0); self.f4Found = f4Found ?? (f4 > 0)
        }
    }

    public var pitch: Pitch
    public var stress: Stress
    public var voiceHealth: VoiceHealth
    public var speechRate: SpeechRate
    public var formants: Formants
    public var confidence: Float
    /// The word of the tone row (section 12.6 of the specification). The engine sets it on the display value
    /// (`VoiceAnalysisEngine.onDisplay`) only; a raw result and a value averaged by `VoiceAnalysisSmoothing`
    /// carry `noWord`.
    public var voiceWord: VoiceWord

    public init(pitch: Pitch = Pitch(f0Hz: 0, voiced: false, rms: 0),
                stress: Stress = Stress(score: 0, jitter: 0, shimmer: 0),
                voiceHealth: VoiceHealth = VoiceHealth(hnr: 0, breathiness: 0),
                speechRate: SpeechRate = SpeechRate(syllablesPerSec: 0, pauseRatio: 0, isSpeaking: false),
                formants: Formants = Formants(f1: 0, f2: 0, f3: 0, f4: 0),
                confidence: Float = 0,
                voiceWord: VoiceWord = .noWord) {
        self.pitch = pitch; self.stress = stress; self.voiceHealth = voiceHealth
        self.speechRate = speechRate; self.formants = formants; self.confidence = confidence
        self.voiceWord = voiceWord
    }
}

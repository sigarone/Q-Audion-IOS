import Foundation

/// W-VOICEUISMOOTH (2026-08-29) — collapse a burst of ``VoiceAnalysisResult``
/// samples into the single value the call UI shows for that window.
///
/// The analysis engine emits far faster than a person can read: on a live
/// call the Guardian ribbon's numbers changed several times per second, so
/// the instantaneous values were physically unreadable even though every
/// individual one was correct. Reported live 2026-08-29 ("i dati relativi
/// alla voce si aggiornano molto velocemente che non si riesce neanche a
/// leggere i valori istantanei").
///
/// Averaging happens at the PRESENTATION boundary only. Nothing downstream
/// of the analysis engine — Guardian verdicts, the deepfake monitor, the
/// per-contact verifier, voice learning — sees a smoothed value; they keep
/// consuming every raw sample exactly as before. This is a display filter,
/// never a detection input, because averaging a security signal would hide
/// exactly the brief anomaly it exists to catch.
///
/// ## The display rule (docs/voice-analysis-spec.md, section 9)
///
/// The window is the last 10 results, which is one second of AUDIO time (the
/// engine keeps it, see `VoiceAnalysisEngine.onDisplay`); it is never a batch
/// of wall-clock time, so a stall of the UI thread or a late timer cannot change
/// what a second means. Every measured field is the arithmetic mean over the
/// results whose own validity flag is set (`f0Valid`, `f1Found`, `f2Found`,
/// `hnrValid`, `speechRate.valid`, `stress.valid`), never over the zeros an
/// invalid result carries, and the averaged field is valid when at least one
/// result was: otherwise it is 0 with the flag false, which a consumer shows as
/// a dash. The level (`rms`) is averaged over all results, because a level is
/// meaningful across silence. The two booleans `voiced` and `isSpeaking` take a
/// MAJORITY vote (more than half of the results) rather than any-true or
/// last-wins: a single voiced frame in a second of silence should not light the
/// indicator, and one unvoiced gap mid-sentence should not blank it — either
/// would reintroduce the flicker this exists to remove.
///
/// The score and the confidence are undefined during silence, not zero-valued
/// (W-VOICEMEANVOICED, 2026-08-29: averaging those zeros in turned the readout
/// into "what fraction of the second was speech"), so they are averaged over the
/// VOICED results only, falling back to all of them when none is voiced.
///
/// Pure function: no clock, no state, no engine dependency.
public enum VoiceAnalysisSmoothing {

    /// Mean of `samples` by the display rule above, or `nil` when there is
    /// nothing to average — the caller keeps showing its previous value rather
    /// than blanking the UI.
    public static func average(of samples: [VoiceAnalysisResult]) -> VoiceAnalysisResult? {
        guard !samples.isEmpty else { return nil }

        var f0 = Mean(), f1 = Mean(), f2 = Mean()
        var hnr = Mean(), breathiness = Mean()
        var rate = Mean(), pause = Mean()
        var jitter = Mean(), shimmer = Mean()
        var rms = Mean(), periodicity = Mean()
        var score = Mean(), confidence = Mean()
        var scoreAll = Mean(), confidenceAll = Mean()
        var voicedVotes = 0
        var speakingVotes = 0

        for s in samples {
            if s.pitch.f0Valid { f0.add(s.pitch.f0Hz) }
            if s.formants.f1Found { f1.add(s.formants.f1) }
            if s.formants.f2Found { f2.add(s.formants.f2) }
            if s.voiceHealth.hnrValid {
                hnr.add(s.voiceHealth.hnr)
                breathiness.add(s.voiceHealth.breathiness)
            }
            if s.speechRate.valid {
                rate.add(s.speechRate.syllablesPerSec)
                pause.add(s.speechRate.pauseRatio)
            }
            if s.stress.valid {
                jitter.add(s.stress.jitter)
                shimmer.add(s.stress.shimmer)
            }
            rms.add(s.pitch.rms)
            periodicity.add(s.pitch.periodicity)
            scoreAll.add(s.stress.score)
            confidenceAll.add(s.confidence)
            if s.pitch.voiced {
                voicedVotes += 1
                score.add(s.stress.score)
                confidence.add(s.confidence)
            }
            if s.speechRate.isSpeaking { speakingVotes += 1 }
        }

        let n = samples.count
        return VoiceAnalysisResult(
            pitch: .init(f0Hz: f0.value, voiced: voicedVotes * 2 > n, rms: rms.value,
                         f0Valid: f0.count > 0, periodicity: periodicity.value),
            stress: .init(score: (score.count > 0 ? score : scoreAll).value,
                          jitter: jitter.value, shimmer: shimmer.value, valid: jitter.count > 0),
            voiceHealth: .init(hnr: hnr.value, breathiness: breathiness.value, hnrValid: hnr.count > 0),
            speechRate: .init(syllablesPerSec: rate.value, pauseRatio: pause.value,
                              isSpeaking: speakingVotes * 2 > n, valid: rate.count > 0),
            formants: .init(f1: f1.value, f2: f2.value, f3: 0, f4: 0,
                            f1Found: f1.count > 0, f2Found: f2.count > 0, f3Found: false, f4Found: false),
            confidence: (confidence.count > 0 ? confidence : confidenceAll).value
        )
    }

    /// Running arithmetic mean in binary64; 0 when nothing was added.
    private struct Mean {
        private var sum = 0.0
        private(set) var count = 0
        mutating func add(_ value: Float) {
            sum += Double(value)
            count += 1
        }
        var value: Float { count > 0 ? Float(sum / Double(count)) : 0 }
    }
}

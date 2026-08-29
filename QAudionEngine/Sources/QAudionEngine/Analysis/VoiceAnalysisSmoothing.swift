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
/// Continuous quantities take the arithmetic mean. The two booleans take a
/// MAJORITY vote rather than any-true or last-wins: a single voiced frame in
/// a second of silence should not light the indicator, and one unvoiced gap
/// mid-sentence should not blank it — either would reintroduce the flicker
/// this exists to remove.
///
/// Pure function: no clock, no state, no engine dependency, so the window
/// policy lives entirely with the caller (`AppState` publishes once per
/// second) and this stays unit-testable on its own.
public enum VoiceAnalysisSmoothing {

    /// Mean of `samples`, or `nil` when there is nothing to average — the
    /// caller keeps showing its previous value rather than blanking the UI.
    public static func average(of samples: [VoiceAnalysisResult]) -> VoiceAnalysisResult? {
        guard !samples.isEmpty else { return nil }
        let n = Float(samples.count)
        func mean(_ pick: (VoiceAnalysisResult) -> Float) -> Float {
            samples.reduce(Float(0)) { $0 + pick($1) } / n
        }
        // Majority, not any/last — see the type's own doc.
        func majority(_ pick: (VoiceAnalysisResult) -> Bool) -> Bool {
            samples.reduce(0) { $0 + (pick($1) ? 1 : 0) } * 2 > samples.count
        }
        return VoiceAnalysisResult(
            pitch: .init(
                f0Hz: mean { $0.pitch.f0Hz },
                voiced: majority { $0.pitch.voiced },
                rms: mean { $0.pitch.rms }
            ),
            stress: .init(
                score: mean { $0.stress.score },
                jitter: mean { $0.stress.jitter },
                shimmer: mean { $0.stress.shimmer }
            ),
            voiceHealth: .init(
                hnr: mean { $0.voiceHealth.hnr },
                breathiness: mean { $0.voiceHealth.breathiness }
            ),
            speechRate: .init(
                syllablesPerSec: mean { $0.speechRate.syllablesPerSec },
                pauseRatio: mean { $0.speechRate.pauseRatio },
                isSpeaking: majority { $0.speechRate.isSpeaking }
            ),
            formants: .init(
                f1: mean { $0.formants.f1 },
                f2: mean { $0.formants.f2 },
                f3: mean { $0.formants.f3 },
                f4: mean { $0.formants.f4 }
            ),
            confidence: mean { $0.confidence }
        )
    }
}

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
    ///
    /// W-VOICEMEANVOICED (2026-08-29) — the voice-dependent fields are
    /// averaged over the VOICED samples only, and that distinction is not a
    /// refinement, it is a correctness fix for a real regression this file
    /// introduced. `ConfidenceIndicator.analyze` returns exactly 0 for an
    /// unvoiced frame, and the same holds for pitch, stress, health and
    /// formants: they are undefined during silence, not zero-valued. Averaging
    /// those zeros in turns the readout into "what fraction of the second was
    /// speech" rather than "how trustworthy is the voice" — a second that is
    /// half silence and half a confident 0.8 displayed 0.4. Reported live
    /// 2026-08-29 ("il confidence è sempre molto basso a 0,4").
    ///
    /// `rms` and the speech-rate fields are deliberately NOT restricted: a
    /// level and a pause ratio are meaningful across silence, and averaging
    /// them over the whole window is what makes them mean what they say.
    public static func average(of samples: [VoiceAnalysisResult]) -> VoiceAnalysisResult? {
        guard !samples.isEmpty else { return nil }
        let n = Float(samples.count)
        func mean(_ pick: (VoiceAnalysisResult) -> Float) -> Float {
            samples.reduce(Float(0)) { $0 + pick($1) } / n
        }
        // Voice-dependent fields: see the note above. Falls back to the full
        // window when nothing in it was voiced, which then averages the zeros
        // the analysis itself produced — the honest answer for a silent
        // second, and identical to the previous behavior in that case.
        let voiced = samples.filter { $0.pitch.voiced }
        let voicedN = Float(voiced.count)
        func voicedMean(_ pick: (VoiceAnalysisResult) -> Float) -> Float {
            guard !voiced.isEmpty else { return mean(pick) }
            return voiced.reduce(Float(0)) { $0 + pick($1) } / voicedN
        }
        // Majority, not any/last — see the type's own doc.
        func majority(_ pick: (VoiceAnalysisResult) -> Bool) -> Bool {
            samples.reduce(0) { $0 + (pick($1) ? 1 : 0) } * 2 > samples.count
        }
        return VoiceAnalysisResult(
            pitch: .init(
                f0Hz: voicedMean { $0.pitch.f0Hz },
                voiced: majority { $0.pitch.voiced },
                // A level is meaningful across silence — full window.
                rms: mean { $0.pitch.rms }
            ),
            stress: .init(
                score: voicedMean { $0.stress.score },
                jitter: voicedMean { $0.stress.jitter },
                shimmer: voicedMean { $0.stress.shimmer }
            ),
            voiceHealth: .init(
                hnr: voicedMean { $0.voiceHealth.hnr },
                breathiness: voicedMean { $0.voiceHealth.breathiness }
            ),
            speechRate: .init(
                // Rate and pause ratio describe the WINDOW, silence included.
                syllablesPerSec: mean { $0.speechRate.syllablesPerSec },
                pauseRatio: mean { $0.speechRate.pauseRatio },
                isSpeaking: majority { $0.speechRate.isSpeaking }
            ),
            formants: .init(
                f1: voicedMean { $0.formants.f1 },
                f2: voicedMean { $0.formants.f2 },
                f3: voicedMean { $0.formants.f3 },
                f4: voicedMean { $0.formants.f4 }
            ),
            confidence: voicedMean { $0.confidence }
        )
    }
}

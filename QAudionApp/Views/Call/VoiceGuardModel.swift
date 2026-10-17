import Foundation
import QAudionEngine

// Pure decisions behind the voice analysis shown during a call: the pitch
// reading of the ribbon, the "voice check" card and the technical-data rows of
// the security sheet. No SwiftUI in here, so every threshold, word and format
// is covered by unit tests; the views only map a `VoiceTone` onto a
// design-system colour and a string onto a Text.
//
// Nothing here turns a measurement into a claim about the person (stress,
// agitation, health, authenticity): the measures are not validated for
// phone-quality speech, so the only verdict shown is the speaker-change one.

/// Colour role of one indicator. The views translate it into the
/// design-system colours (`extras.success`, `extras.warning`, `extras.riskHigh`
/// and the secondary text colour) so light and dark themes stay in step.
enum VoiceTone: Equatable {
    case success
    case warning
    case riskHigh
    /// No claim is made: drawn in the secondary text colour.
    case neutral
}

// MARK: - Pitch reading of the ribbon

/// The status text of a reading. The views turn it into the printed text; the
/// decision itself stays free of any language.
enum VoiceGaugeStatus: Equatable {
    /// Nothing to add under the value.
    case none
    /// Printed as a dash: there is no pitch to speak of (unvoiced segment).
    case dash
}

/// What the pitch cell prints: the number, its unit (a symbol, never
/// translated), the status text and the colour role of the status text.
struct VoiceGaugeReading: Equatable {
    let value: String
    let unit: String
    let status: VoiceGaugeStatus
    let tone: VoiceTone
}

enum VoiceGauges {
    /// Printed where a measurement does not exist.
    static let noValue = "—"

    /// The whole part of a measurement, cut towards zero (not rounded): 44.9
    /// reads "44". A value that is not a finite number reads as `noValue`.
    static func wholeNumber(_ value: Float) -> String {
        guard value.isFinite, abs(value) < 1_000_000 else { return noValue }
        return Int(value).description
    }

    /// Pitch reading: no status text while the segment is voiced, a dash while
    /// it is not (an unvoiced segment has no pitch to speak of). It is never
    /// coloured: a pitch is a measurement, not a verdict.
    static func pitch(hz: Float, voiced: Bool) -> VoiceGaugeReading {
        VoiceGaugeReading(value: wholeNumber(hz), unit: "Hz", status: voiced ? .none : .dash, tone: .neutral)
    }
}

// MARK: - Technical data of the security sheet

/// The measures that are left once nothing is read as a claim about the
/// person. They are plain numbers, never coloured, and the view puts them in a
/// section titled as not validated.
enum VoiceBiometricsFormat {
    /// Jitter and shimmer arrive as ratios (0.03 = 3 %); shown as percentages
    /// with one decimal: "3.0% / 8.5%".
    static func jitterShimmer(jitter: Float, shimmer: Float) -> String {
        guard jitter.isFinite, shimmer.isFinite else { return VoiceGauges.noValue }
        return oneDecimal(jitter * 100) + "% / " + oneDecimal(shimmer * 100) + "%"
    }

    /// Guardian confidence as plain text: "C=0.87", or "C=—" when no real score
    /// exists (a negative value is the "no score yet" sentinel; a NaN is no
    /// score either). It is a number and nothing more: no colour, no band, no
    /// word, because the score is not validated for phone-quality speech.
    static func confidence(_ value: Double) -> String {
        guard value >= 0 else { return "C=" + VoiceGauges.noValue }
        return String(format: "C=%.2f", min(1.0, max(0.0, value)))
    }

    /// Harmonic-to-noise ratio in whole dB: "21 dB".
    static func hnr(_ decibels: Float) -> String {
        guard decibels.isFinite else { return VoiceGauges.noValue }
        return String(format: "%.0f", Double(decibels)) + " dB"
    }

    /// Pitch and speech rate: "142 Hz · 4.1 <unit>", where the unit (syllables
    /// per second) is the localized abbreviation the caller passes in.
    static func pitchRate(hz: Float, syllablesPerSecond: Float, syllableUnit: String) -> String {
        guard hz.isFinite, syllablesPerSecond.isFinite else { return VoiceGauges.noValue }
        return String(format: "%.0f", Double(hz)) + " Hz · " + oneDecimal(syllablesPerSecond) + " " + syllableUnit
    }

    private static func oneDecimal(_ value: Float) -> String {
        String(format: "%.1f", Double(value))
    }
}

// MARK: - "Voice check" card

/// How the speaker-change verdict reads on the card.
enum VoiceGuardLevel: Equatable {
    case verified
    case caution
    case highRisk
}

/// The short confirmation shown when the voice-learning session ends.
enum VoiceGuardBanner: Equatable {
    case learned
    case failed
}

/// What the card shows, in priority order: the banner, the learning progress,
/// the waiting state (before the first sample: the view draws it as the
/// "Dati insufficienti" word with a flat trace), and finally the verdict with
/// its wave.
enum VoiceGuardContent: Equatable {
    case banner(VoiceGuardBanner)
    case learning(progress: Float)
    case waiting
    case verdict(level: VoiceGuardLevel?)
}

enum VoiceGuardIcon: Equatable {
    case check
    case warning
    case microphone
}

/// The word shown under the card's title. These are the only four states the
/// card ever shows, each with a short explanation under it:
///  - `verified`  "Voce coerente": no unusual change from the person's usual voice;
///  - `caution`   "Da controllare": a change worth verifying (for example with
///                the 60-digit safety number);
///  - `highRisk`  "Anomalia": the voice changed in an unusual way, so the
///                identity of the person should be verified;
///  - `pending`   "Dati insufficienti": not enough data to compare yet.
/// None of them says anything about emotion, stress, health or coercion.
enum VoiceGuardWord: Equatable {
    /// There is no verdict yet: the card must not claim the voice is consistent.
    case pending
    case verified
    case caution
    case highRisk
}

enum VoiceGuard {
    /// How long a banner stays on the card.
    static let bannerSeconds: Double = 3.5

    /// The verdict of "is this still the voice the call started with". An
    /// unknown verdict has no level: the card then shows the neutral wording.
    static func level(of change: RemoteSpeakerChangeMonitor.Level) -> VoiceGuardLevel? {
        switch change {
        case .unknown: return nil
        case .steady:  return .verified
        case .suspect: return .caution
        case .changed: return .highRisk
        }
    }

    /// The banner a learning-session state asks for, if any. Only the two final
    /// states do; the card shows it once, when the state changes to it.
    static func banner(for state: VoiceLearningSession.State?) -> VoiceGuardBanner? {
        guard let state = state else { return nil }
        switch state {
        case .completed:
            return .learned
        case .failed:
            return .failed
        case .idle, .inProgress:
            return nil
        }
    }

    static func content(banner: VoiceGuardBanner?,
                        learning: VoiceLearningSession.State?,
                        hasHistory: Bool,
                        level: VoiceGuardLevel?) -> VoiceGuardContent {
        if let banner {
            return .banner(banner)
        }
        if let state = learning, case .inProgress(let progress) = state {
            return .learning(progress: clampedProgress(progress))
        }
        if !hasHistory {
            return .waiting
        }
        return .verdict(level: level)
    }

    static func clampedProgress(_ progress: Float) -> Float {
        guard progress.isFinite else { return 0 }
        return min(1, max(0, progress))
    }

    /// Learning progress as a whole percentage, for the spoken value of the bar.
    static func percentText(_ progress: Float) -> String {
        let percent = Int((clampedProgress(progress) * 100).rounded())
        return percent.description + "%"
    }

    static func tone(of level: VoiceGuardLevel?) -> VoiceTone {
        switch level {
        case .verified?: return .success
        case .caution?:  return .warning
        case .highRisk?: return .riskHigh
        case nil:        return .neutral
        }
    }

    /// Colour role of the banner, or nil when there is no banner.
    static func bannerTone(of banner: VoiceGuardBanner?) -> VoiceTone? {
        switch banner {
        case .learned?: return .success
        case .failed?:  return .riskHigh
        case nil:       return nil
        }
    }

    /// "Voce coerente" is said only for an explicit verified level; no verdict
    /// yet has its own neutral word ("Dati insufficienti").
    static func word(for level: VoiceGuardLevel?) -> VoiceGuardWord {
        switch level {
        case nil:        return .pending
        case .verified?: return .verified
        case .caution?:  return .caution
        case .highRisk?: return .highRisk
        }
    }

    static func icon(banner: VoiceGuardBanner?, level: VoiceGuardLevel?) -> VoiceGuardIcon {
        if banner == .learned || level == .verified {
            return .check
        }
        if level == .highRisk {
            return .warning
        }
        return .microphone
    }
}

// MARK: - "Custody of your voice" card

/// The parts of the custody card that depend on the state of the call.
enum VoiceCustody {
    /// Value of the "Post-quantum" cell: the algorithm (a name, not translated)
    /// only while the post-quantum exchange is really in use.
    static func postQuantumValue(active: Bool) -> String {
        active ? "ML-KEM" : VoiceCustodyCopy.postQuantumOff
    }

    /// Value of the "Identity" cell: the short-authentication-string check mark
    /// once verified, otherwise the localized "not verified".
    static func identityValue(verified: Bool) -> String {
        verified ? "SAS ✓" : VoiceCustodyCopy.identityUnverified
    }

    /// Text of the verdict box. The cipher and the post-quantum exchange are
    /// named only when the post-quantum exchange is active; the statement about
    /// the microphone holds either way.
    static func verdictText(pqcActive: Bool) -> String {
        if pqcActive {
            return String(localized: "in_call.custody.verdict",
                          defaultValue: "La protezione comincia al sigillo: l'audio viene cifrato con AES-256 usando chiavi derivate da ML-KEM-1024 e le chiavi della tua identità restano nel Keychain. Ma il microfono sta appena fuori dalla zona protetta: l'audio grezzo esiste nel telefono per un istante prima di essere sigillato, quindi un sistema operativo compromesso potrebbe intercettarlo a monte della cifratura, senza bisogno di alcuna chiave.",
                          comment: "Call security sheet, custody of the voice card — verdict while the post-quantum key exchange is active: where the protection starts and what it does not cover")
        }
        return String(localized: "in_call.custody.verdict_no_pqc",
                      defaultValue: "Il microfono sta appena fuori dalla zona protetta: l'audio grezzo esiste nel telefono per un istante prima di essere sigillato, quindi un sistema operativo compromesso potrebbe intercettarlo a monte della cifratura, senza bisogno di alcuna chiave.",
                      comment: "Call security sheet, custody of the voice card — verdict while the post-quantum key exchange is not active: what the protection does not cover")
    }
}

// MARK: - Single-trace wave

enum VoiceGuardWave {
    /// Floor on the spread the trace is scaled by: a perfectly steady window
    /// must not have its tiny noise blown up into movement.
    static let minSpread: Float = 0.02

    /// Each sample's distance from the window's mean, in units of the largest
    /// distance (but never less than `minSpread`), kept within -1...1. An empty
    /// result means there is too little to draw and the wave is a flat line.
    static func deviations(of history: [Float]) -> [Float] {
        let samples = history.filter { $0.isFinite }
        guard samples.count >= 2 else { return [] }
        let mean = samples.reduce(0, +) / Float(samples.count)
        var spread = minSpread
        for sample in samples {
            spread = max(spread, abs(sample - mean))
        }
        var result: [Float] = []
        result.reserveCapacity(samples.count)
        for sample in samples {
            let deviation: Float = (sample - mean) / spread
            result.append(min(1, max(-1, deviation)))
        }
        return result
    }
}

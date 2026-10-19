import Foundation
import QAudionEngine

// Pure decisions behind the voice analysis shown during a call: the tone row
// of the ribbon, the "voice check" card and its wave, and the technical-data
// rows of the security sheet. No SwiftUI in here, so every threshold, word and
// format is covered by unit tests; the views only map a `VoiceTone` onto a
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

// MARK: - Tone row of the ribbon

/// What the tone row prints: the whole-number f0, its unit (a symbol, never
/// translated) and whether a voice is present. The unit goes with a number and
/// never with the dash: a pitch that is not a reading is written "—", not
/// "— Hz" (docs/voice-analysis-spec.md, section 12.5). The row never colours
/// any of it and never adds a sentence: a pitch is a measurement, not a verdict.
struct VoiceToneReading: Equatable {
    let value: String
    /// "Hz" next to a number; empty next to the dash.
    let unit: String
    let voiced: Bool

    /// The tone as one string, wherever it is written: "143 Hz", or the dash alone.
    var text: String {
        unit.isEmpty ? value : value + " " + unit
    }
}

// MARK: - Number formats (docs/voice-analysis-spec.md, section 12)

/// The number formats of the voice analysis, the same on iOS and Android and shared by the tone row, the
/// technical-data block and the video diagnostics: rounded half away from zero by an explicit rule (never by
/// a printf-style format, which rounds an exact binary tie to even), a decimal separator that comes from the
/// language of the app, and a dash for a value that is not a reading. Everything is computed in binary64, in
/// the order docs/voice-analysis-spec.md (section 12) writes it, so the two apps print the same string for
/// the same value.
enum VoiceNumberFormat {
    /// A magnitude above this is not a reading either; it keeps the integer conversions below safe. No
    /// measurement of the voice gets anywhere near it.
    static let magnitudeLimit = 1_000_000_000.0

    /// Round half away from zero (docs/voice-analysis-spec.md, section 12.1): 142.5 gives 143 and -2.5 gives -3.
    static func roundHalfAwayFromZero(_ t: Double) -> Double {
        if t < 0 { return -roundHalfAwayFromZero(-t) }
        let whole: Double = t.rounded(.down)
        return t - whole >= 0.5 ? whole + 1 : whole
    }

    /// A whole number of the value ("143"), or nil when it is not finite or out of range.
    static func whole(_ x: Double) -> String? {
        guard x.isFinite, abs(x) < magnitudeLimit else { return nil }
        return String(Int(roundHalfAwayFromZero(x)))
    }

    /// The value to the nearest 10, as a whole number ("1480" for 1475), or nil.
    static func nearestTen(_ x: Double) -> String? {
        guard x.isFinite, abs(x) < magnitudeLimit else { return nil }
        return String(Int(roundHalfAwayFromZero(x / 10)) * 10)
    }

    /// The value with exactly one decimal ("4,3" in Italian, "4.3" in English for 4.25), or nil: `x * 10` is
    /// rounded to a whole number and the last digit is printed after the separator of `locale`. A value that
    /// rounds to zero never shows a minus sign.
    static func oneDecimal(_ x: Double, locale: Locale) -> String? {
        guard x.isFinite, abs(x) < magnitudeLimit else { return nil }
        let tenths: Int = Int(roundHalfAwayFromZero(x * 10))
        let magnitude: Int = tenths < 0 ? -tenths : tenths
        let sign: String = tenths < 0 ? "-" : ""
        return sign + String(magnitude / 10) + decimalSeparator(of: locale) + String(magnitude % 10)
    }

    /// The decimal separator of the language of `locale`.
    static func decimalSeparator(of locale: Locale) -> String {
        locale.decimalSeparator ?? "."
    }
}

enum VoiceGauges {
    /// Printed where a measurement does not exist.
    static let noValue = "—"

    /// The pitch as a whole number of Hz, rounded half away from zero (142.5 reads "143"; it is never cut
    /// towards zero). A pitch that is not a reading, which is NaN, infinite, zero or negative, reads as
    /// `noValue`.
    static func wholeNumber(_ value: Float) -> String {
        guard value > 0, let text = VoiceNumberFormat.whole(Double(value)) else { return noValue }
        return text
    }

    /// The unit of the tone: a symbol, the same in every language.
    static let pitchUnit = "Hz"

    /// The tone reading: the f0 as a whole number, "Hz", and whether the
    /// segment is voiced (the row then says "voice", otherwise "silence"). A
    /// pitch that is not a reading has the dash and no unit.
    static func pitch(hz: Float, voiced: Bool) -> VoiceToneReading {
        let value: String = wholeNumber(hz)
        return VoiceToneReading(value: value, unit: value == noValue ? "" : pitchUnit, voiced: voiced)
    }

    /// What a screen reader says for the whole row: the label, the value with
    /// its unit, the voice word and, when there are any, the details with their
    /// separators turned into pauses. A dash (a value that does not exist) is
    /// read as `unavailable`, never as a symbol.
    static func spokenTone(label: String,
                           reading: VoiceToneReading,
                           voiceWord: String,
                           details: String?,
                           unavailable: String = VoiceToneCopy.unavailable) -> String {
        let measure: String = reading.value == noValue ? unavailable : reading.text
        var parts: [String] = [label, measure, voiceWord]
        if let details = details, !details.isEmpty {
            let paused: String = details.replacingOccurrences(of: VoiceSpectralDetails.separator, with: ", ")
            parts.append(paused.replacingOccurrences(of: noValue, with: unavailable))
        }
        return parts.joined(separator: ", ")
    }
}

/// The two words of the tone row, for a segment with a voice and one without.
/// They state what was heard, nothing about the person.
enum VoiceToneCopy {
    static func voiceWord(voiced: Bool) -> String {
        if voiced {
            return String(localized: "in_call.gauge.pitch_voiced",
                          defaultValue: "voce",
                          comment: "Call screen voice ribbon, tone row — word after the pitch value when a voice is present in the audio being measured")
        }
        return String(localized: "in_call.gauge.pitch_silent",
                      defaultValue: "silenzio",
                      comment: "Call screen voice ribbon, tone row — word after the pitch value when there is no voice in the audio being measured")
    }

    /// What a screen reader says where the row prints a dash: a measurement that
    /// does not exist right now.
    static var unavailable: String {
        String(localized: "in_call.gauge.a11y_unavailable",
               defaultValue: "non disponibile",
               comment: "Call screen voice ribbon, tone row — spoken by a screen reader in place of the dash printed where a measurement (pitch, formant, speech rate, harmonic-to-noise ratio) does not exist right now")
    }
}

// MARK: - Spectral details of the tone row

/// The details printed to the right of the tone, on the same row, as neutral
/// acoustic measurements from the voice analysis result: the first two formants,
/// the speech rate and the harmonic-to-noise ratio, in this order, joined by " · ":
///
///     F1 520 · F2 1480 · 4,2 sill/s · HNR 18 dB
///
/// Formants are rounded to the nearest 10 Hz, the rate has one decimal in the
/// decimal separator of the language of the app (not of the device region), the
/// HNR is a whole number of dB; all of it rounded half away from zero (see
/// `VoiceNumberFormat`). Every one of the four follows the validity flag of its
/// own measurement: the caller passes NaN for a formant that was not found, a
/// speech rate that is not a reading yet and an HNR that is not valid, and a dash
/// is printed in its place ("F1 —", "— sill/s", "HNR —"). A zero is only ever
/// printed for a measured zero.
/// Never colour the details, and never add a score, jitter, shimmer or any word
/// about emotion, stress, health or the state of the person: they are values of
/// the signal and nothing else.
enum VoiceSpectralDetails {
    enum Field: CaseIterable {
        case formant1
        case formant2
        case speechRate
        case hnr
    }

    /// Between two details.
    static let separator = " · "

    /// The details that are printed: all four. The extractors behind them are the
    /// ones of the specification of the remote-voice analysis
    /// (docs/voice-analysis-spec.md), and are checked against its reference vectors
    /// (see `VoiceDspVectorTests`): formants
    /// from an order-18 LPC fit on the 16 kHz view, withheld where the harmonics
    /// cannot resolve them; an HNR measured on the 48 kHz window, independent of
    /// the loudness; a speech rate counted from syllable nuclei over the last 6 s.
    static let measured: Set<Field> = Set(Field.allCases)

    /// The text of the details, or nil when `fields` selects none. `locale` is the locale of the language of
    /// the app (`VoiceDisplayLocale.app`); it only decides the decimal separator of the rate.
    static func text(formant1Hz: Float,
                     formant2Hz: Float,
                     syllablesPerSecond: Float,
                     hnrDecibels: Float,
                     rateUnit: String,
                     fields: Set<Field> = VoiceSpectralDetails.measured,
                     locale: Locale) -> String? {
        var parts: [String] = []
        if fields.contains(.formant1) {
            let first: String = "F1 " + formant(formant1Hz)
            parts.append(first)
        }
        if fields.contains(.formant2) {
            let second: String = "F2 " + formant(formant2Hz)
            parts.append(second)
        }
        if fields.contains(.speechRate) {
            let speed: String = rate(syllablesPerSecond, unit: rateUnit, locale: locale)
            parts.append(speed)
        }
        if fields.contains(.hnr) {
            let noise: String = "HNR " + hnr(hnrDecibels)
            parts.append(noise)
        }
        if parts.isEmpty { return nil }
        return parts.joined(separator: separator)
    }

    /// The widest line the details can take, in the language of the app: F1 up to
    /// 1100 Hz, F2 up to 3200 Hz, a speech rate up to 12 syllables per second and an
    /// HNR down to -40 dB, "F1 1100 · F2 3200 · 12,0 sill/s · HNR -40 dB"
    /// (docs/voice-analysis-spec.md, section 12.5). A screen that fits the details to
    /// its width sizes them on this line and not on the text it shows, so the size
    /// does not change when a dash becomes a number.
    static func widestLine(rateUnit: String, locale: Locale) -> String {
        text(formant1Hz: 1100, formant2Hz: 3200, syllablesPerSecond: 12, hnrDecibels: -40,
             rateUnit: rateUnit, locale: locale) ?? ""
    }

    /// A formant in Hz, rounded to the nearest 10 (half away from zero: 1475 reads
    /// "1480"), or a dash for a formant that was not found (NaN, or the 0 of a
    /// result without one).
    static func formant(_ hertz: Float) -> String {
        guard hertz > 0, let text = VoiceNumberFormat.nearestTen(Double(hertz)) else { return VoiceGauges.noValue }
        return text
    }

    /// The speech rate with one decimal, in the decimal separator of `locale`, and
    /// the unit; a dash and the unit while it is not a reading.
    static func rate(_ syllablesPerSecond: Float, unit: String, locale: Locale) -> String {
        guard syllablesPerSecond >= 0,
              let number = VoiceNumberFormat.oneDecimal(Double(syllablesPerSecond), locale: locale) else {
            return VoiceGauges.noValue + " " + unit
        }
        return number + " " + unit
    }

    /// The harmonic-to-noise ratio in whole dB, rounded half away from zero (-2.5
    /// reads "-3 dB"), or a dash while it is not valid.
    static func hnr(_ decibels: Float) -> String {
        guard let text = VoiceNumberFormat.whole(Double(decibels)) else { return VoiceGauges.noValue }
        return text + " dB"
    }
}

// MARK: - Size of a line that keeps one size

/// The font size of a line of text that is fitted to the width it is given and must
/// keep ONE size while its words change (the details of the tone row,
/// docs/voice-analysis-spec.md, section 12.5): the size is decided from the natural
/// width of the widest line it can ever hold, never from the text it holds now, and
/// the real text is then drawn at that size. No SwiftUI in here: the view measures
/// the two widths and asks.
enum VoiceLineFit {
    /// The smallest share of the base size (70 %). Below it the line is cut at the
    /// end instead of being shrunk further.
    static let smallestShare: Double = 0.7

    /// Width kept free, in points. A text width is rounded up to a whole pixel, so a
    /// line fitted to the very last point can come out a pixel too wide and be cut
    /// with an ellipsis.
    static let slack: Double = 1

    /// `baseSize` is the font size at full scale (at the reader's Dynamic Type
    /// setting), `availableWidth` the width the line is given and `templateWidth` the
    /// natural width of the widest line at `baseSize`. The result is `baseSize` when
    /// the widest line fits, otherwise `baseSize` scaled by the share of its width
    /// that is available, never below `smallestShare`. A width that is not known (NaN,
    /// or a template without width) leaves the base size.
    static func fontSize(baseSize: Double, availableWidth: Double, templateWidth: Double) -> Double {
        guard baseSize.isFinite, baseSize > 0 else { return baseSize }
        guard templateWidth.isFinite, templateWidth > 0, !availableWidth.isNaN else { return baseSize }
        let share: Double = (availableWidth - slack) / templateWidth
        return baseSize * min(1, max(smallestShare, share))
    }
}

// MARK: - From a display value to what the screens show

extension InCallScreen.VoiceBiometrics {
    /// The snapshot the call screens draw, from the display value of the voice
    /// analysis (`AppState.voiceAnalysis`). Every measurement carries its own
    /// validity flag, and one that is not a reading right now is passed as NaN,
    /// which every consumer prints as a dash, instead of as a measured 0: the
    /// pitch (`f0Valid`), the first two formants (`f1Found`, `f2Found`), the
    /// speech rate (`speechRate.valid`), the HNR (`hnrValid`) and jitter and
    /// shimmer (`stress.valid`). The voiced flag only chooses the word of the tone
    /// row ("voce" / "silenzio") and the tint of the spectrum.
    init(_ result: VoiceAnalysisResult) {
        self.init(
            stressScore: result.stress.score,
            jitter: result.stress.valid ? result.stress.jitter : .nan,
            shimmer: result.stress.valid ? result.stress.shimmer : .nan,
            hnr: result.voiceHealth.hnrValid ? result.voiceHealth.hnr : .nan,
            breathiness: result.voiceHealth.breathiness,
            pitchHz: result.pitch.f0Valid ? result.pitch.f0Hz : .nan,
            syllablesPerSec: result.speechRate.valid ? result.speechRate.syllablesPerSec : .nan,
            confidence: result.confidence,
            f1: result.formants.f1Found ? result.formants.f1 : .nan,
            f2: result.formants.f2Found ? result.formants.f2 : .nan,
            f3: result.formants.f3,
            f4: result.formants.f4,
            speaking: result.speechRate.isSpeaking && result.pitch.voiced,
            pitchVoiced: result.pitch.voiced)
    }
}

// MARK: - Technical data of the security sheet

/// The measures that are left once nothing is read as a claim about the
/// person: jitter and shimmer, the pitch with the speech rate, and the
/// harmonic-to-noise ratio. They are plain numbers, never coloured, and the view
/// puts them in a section titled as not validated. Each one follows the validity
/// flag of its measurement: the caller passes NaN where there is none, and a dash
/// is printed. (The Guardian confidence number is not among them: it is computed
/// by a different algorithm on each platform, so the two screens could not show
/// the same figure.)
enum VoiceBiometricsFormat {
    /// Jitter and shimmer as PERCENTAGES (3.0 = 3 %; the screens pass the engine's ratio times 100), with one
    /// decimal, in the decimal separator of `locale` (the language of the app): "3,0% / 8,5%". One dash for the
    /// whole row while they are not readings (both follow the same flag).
    static func jitterShimmer(jitterPercent: Float, shimmerPercent: Float, locale: Locale) -> String {
        guard jitterPercent >= 0, shimmerPercent >= 0,
              let jitterText = VoiceNumberFormat.oneDecimal(Double(jitterPercent), locale: locale),
              let shimmerText = VoiceNumberFormat.oneDecimal(Double(shimmerPercent), locale: locale) else {
            return VoiceGauges.noValue
        }
        return jitterText + "% / " + shimmerText + "%"
    }

    /// The pitch in whole Hz, rounded half away from zero: "143 Hz" for 142.5, or a
    /// dash alone while it is not a reading (the analysis hands it over as NaN then).
    /// It is the text of the tone row (`VoiceToneReading.text`); the voiced flag does
    /// not enter it.
    static func pitch(hz: Float) -> String {
        VoiceGauges.pitch(hz: hz, voiced: false).text
    }

    /// Harmonic-to-noise ratio in whole dB: "21 dB", or a dash while it is not valid.
    static func hnr(_ decibels: Float) -> String {
        VoiceSpectralDetails.hnr(decibels)
    }

    /// Pitch and speech rate: "142 Hz · 4,1 <unit>", where the unit (syllables per
    /// second) is the localized abbreviation the caller passes in and the decimal
    /// separator is the one of `locale`. Each part that is not a reading is a dash
    /// of its own, with no unit: "— · 4,1 <unit>", "142 Hz · —", "— · —". The speech
    /// rate is not a reading for the first seconds of speech (the analysis hands it
    /// over as NaN until it is): then the pitch still shows and the rate is a dash.
    static func pitchRate(hz: Float, syllablesPerSecond: Float, syllableUnit: String, locale: Locale) -> String {
        let pitchText: String = pitch(hz: hz)
        var rateText: String = VoiceGauges.noValue
        if syllablesPerSecond >= 0,
           let number = VoiceNumberFormat.oneDecimal(Double(syllablesPerSecond), locale: locale) {
            rateText = number + " " + syllableUnit
        }
        return pitchText + VoiceSpectralDetails.separator + rateText
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
/// the waiting state (no verdict level and no Guardian sample yet: the view
/// draws just the waiting line, without the wave), and finally the verdict
/// with its wave.
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

/// The one line of text the card shows, one per state, with no sentence of
/// explanation under it (the explanation is the popup the card opens, see
/// `VoiceGuardCopy.infoBody`):
///  - `waiting`     no verdict yet: the card must not claim the voice is steady;
///  - `steady`      the detector sees no change of voice since the start of this
///                  call (it says nothing about past calls);
///  - `suspect`     the LOCAL detector sees a possible change of voice;
///  - `changed`     the local detector confirmed that the voice changed;
///  - `learning`    this contact's voice is being learned;
///  - `learned`     banner: the voice was saved;
///  - `learnFailed` banner: learning did not work.
/// What the far end reports about its own detector is not a state of this
/// card (see `RemoteSpeakerChangeMonitor`). None of the lines says anything
/// about emotion, stress, health, sincerity or coercion.
enum VoiceGuardLine: Equatable, CaseIterable {
    case waiting
    case steady
    case suspect
    case changed
    case learning
    case learned
    case learnFailed
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

    /// The card's level from the monitor's verdict. The verdict is built from
    /// the local detector alone, so nothing the far end reports can reach the
    /// card through here.
    static func level(ofVerdict verdict: RemoteSpeakerChangeMonitor.Verdict) -> VoiceGuardLevel? {
        level(of: verdict.level)
    }

    /// The line of text a card content reads as.
    static func line(for content: VoiceGuardContent) -> VoiceGuardLine {
        switch content {
        case .banner(.learned):
            return .learned
        case .banner(.failed):
            return .learnFailed
        case .learning:
            return .learning
        case .waiting:
            return .waiting
        case .verdict(let level):
            return line(forLevel: level)
        }
    }

    /// "Nessun cambio di voce in chiamata" is said only for an explicit
    /// verified level; no verdict yet reads as waiting.
    static func line(forLevel level: VoiceGuardLevel?) -> VoiceGuardLine {
        switch level {
        case nil:        return .waiting
        case .verified?: return .steady
        case .caution?:  return .suspect
        case .highRisk?: return .changed
        }
    }

    /// Colour role of a line: grey while there is nothing to say, green for
    /// steady (and for the saved-voice banner), amber for a possible change,
    /// red for a confirmed one (and for a failed learning).
    static func tone(ofLine line: VoiceGuardLine) -> VoiceTone {
        switch line {
        case .waiting, .learning: return .neutral
        case .steady, .learned:   return .success
        case .suspect:            return .warning
        case .changed, .learnFailed: return .riskHigh
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
        // The level, when known, always wins: it is shown even while the
        // history that draws the trend is still empty. The bare waiting line
        // is for the case with no level and no sample at all.
        if !hasHistory && level == nil {
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

/// The words of the card. One line per state (`VoiceGuardLine`) and the
/// popup the card opens; the keys are in `Localizable.xcstrings` in all six
/// languages of the app, and the Italian text here is the source language.
enum VoiceGuardCopy {
    /// Title of the popup and first words a screen reader says for the card.
    static var title: String {
        String(localized: "in_call.voice_guard.title",
               defaultValue: "Verifica vocale",
               comment: "Call screen voice check card — title of the info popup and first words a screen reader says for the card")
    }

    /// Body of the popup. It says what is compared (the voice of the other
    /// person against the start of THIS call), that nothing leaves the phone,
    /// and that it is a hint, not proof of identity.
    static var infoBody: String {
        String(localized: "in_call.voice_guard.info_body",
               defaultValue: "Confronta la voce dell'altra persona con l'inizio di questa chiamata. Tutto avviene su questo telefono. È un indizio, non una prova d'identità: per esserne certo usa il codice di sicurezza della chiamata.",
               comment: "Call screen voice check card — body of the info popup opened by tapping the card: what is compared, that it stays on the phone, and that it is a hint and not proof of identity")
    }

    /// The single line of the card for a state. Never a claim about emotion,
    /// stress, health, sincerity or coercion.
    static func text(for line: VoiceGuardLine) -> String {
        switch line {
        case .waiting:
            return String(localized: "in_call.voice_guard.line_waiting",
                          defaultValue: "Ascolto della voce in corso",
                          comment: "Call screen voice check card — line while the detector has no verdict yet")
        case .steady:
            return String(localized: "in_call.voice_guard.line_steady",
                          defaultValue: "Nessun cambio di voce in chiamata",
                          comment: "Call screen voice check card — line while the voice has not changed since the start of this call; it says nothing about past calls")
        case .suspect:
            return String(localized: "in_call.voice_guard.line_suspect",
                          defaultValue: "Possibile cambio di voce",
                          comment: "Call screen voice check card — line when this phone hears a possible change of the voice during the call")
        case .changed:
            return String(localized: "in_call.voice_guard.line_changed",
                          defaultValue: "Voce cambiata durante la chiamata",
                          comment: "Call screen voice check card — line when this phone confirmed that the voice changed during the call")
        case .learning:
            return String(localized: "in_call.voice_guard.line_learning",
                          defaultValue: "Apprendimento della voce",
                          comment: "Call screen voice check card — line while the voice of the other person is being learned")
        case .learned:
            return String(localized: "in_call.voice_guard.line_learned",
                          defaultValue: "Voce memorizzata",
                          comment: "Call screen voice check card — shown briefly when the voice of the other person has been saved on this phone; it does not claim the voice was verified")
        case .learnFailed:
            return String(localized: "in_call.voice_guard.line_learn_failed",
                          defaultValue: "Apprendimento non riuscito",
                          comment: "Call screen voice check card — shown briefly when learning the voice of the other person did not succeed")
        }
    }

    /// What a screen reader says for the card: the title, then the line.
    static func spoken(for line: VoiceGuardLine) -> String {
        title + ", " + text(for: line)
    }
}

/// Voice indicators whose thresholds were never tried against a different
/// speaker. They are hidden, not removed: they come back when calibrated.
enum UncalibratedVoiceIndicators {
    /// The "voce remota" ear shield compares the voice with the profile saved
    /// from past calls. Its two thresholds were fitted to one call with the
    /// same person, and the scores measured since sit where chance would put
    /// them, so a verdict from it would be mostly noise. Off until it has been
    /// calibrated with several different speakers.
    static let contactVoiceShieldCalibrated = false

    /// Whether the ear shield is drawn for `level`. Never, while uncalibrated.
    static func showsContactVoiceShield(level: ContactVoiceContinuityGate.Level) -> Bool {
        guard contactVoiceShieldCalibrated else { return false }
        return level != .unknown
    }
}

// MARK: - Contact screen: the saved voice

/// How the contact screen words a saved voice. Saving a voice is not
/// verifying the person, so the row says when the voice was saved and never
/// "verified".
enum VoiceSavedRow {
    /// "Voce memorizzata il 12 ott 2026" once a voice is saved, otherwise the
    /// plain statement that none is. The date is formatted for the app's
    /// language, not as a fixed pattern.
    static func label(savedAt: Date?, locale: Locale = Locale(identifier: AppLanguageManager.effectiveLanguageCode)) -> String {
        guard let savedAt else {
            return String(localized: "contact_detail.voice_not_saved",
                          defaultValue: "Voce non ancora memorizzata",
                          comment: "Contact screen, trust card — voice row while no voice of this contact has been saved on this phone")
        }
        let date: String = dateText(savedAt, locale: locale)
        return String(localized: "contact_detail.voice_saved_on",
                      defaultValue: "Voce memorizzata il \(date)",
                      comment: "Contact screen, trust card — voice row once the voice of this contact has been saved on this phone; %@ is the date, already formatted for the language of the app. It does not claim the voice was verified.")
    }

    /// The date in the medium style of `locale`.
    static func dateText(_ date: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
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

// MARK: - Which session key the call screens may show

/// The session key the call screens may present as the key of the call: its fingerprint, the algorithm name, the
/// "post-quantum active" shield and cell, and the custody verdict that names ML-KEM.
///
/// A call starts with a transitional key derived from the pairwise secret (`callSasKeySource == .psk`). It exists
/// before any key exchange happened, so it is not the post-quantum key and nothing may be presented as such. Only the
/// key that replaced it (`.mlKem`) may be shown; before that, and when the key is empty, there is nothing to show.
enum CallSessionKeyShown {
    static func realKey(_ key: Data?, source: AppState.CallSasKeySource) -> Data? {
        guard source == .mlKem, let key = key, !key.isEmpty else { return nil }
        return key
    }

    /// Whether the call holds a session key of any kind, the transitional one a call starts with included. It is not
    /// an answer about the post-quantum exchange (that is `realKey`): it is the answer the "DEMO" badge of the
    /// in-call screen has always followed, "no key at all yet", so it stays on it.
    static func isPresent(_ key: Data?) -> Bool {
        guard let key = key else { return false }
        return !key.isEmpty
    }
}

// MARK: - The wave of the voice check card

/// Which of its two pictures the voice wave draws right now.
enum VoiceWavePicture: Equatable {
    /// The live spectrum of the far end drawn over the reference spectrum
    /// taken in this call.
    case overlay
    /// The trend of the combined Guardian confidence score, as a variation
    /// around its average.
    case trend
}

enum VoiceGuardWave {
    /// Floor on the spread the trace is scaled by: a perfectly steady window
    /// must not have its tiny noise blown up into movement.
    static let minSpread: Float = 0.02

    /// How the displayed height of a band follows the spectrum: up at once to a
    /// louder value, and down keeping this share of the old height per spectrum
    /// frame (the rest comes from the new value). The same attack and decay as
    /// the wave of the Android call screen, which steps once per frame.
    static let fall: Float = 0.78

    /// Spectrum frames per second that `fall` is counted in: the analyser
    /// (`SpectrumExtractor`, fed from the decoded audio) publishes about 15 a
    /// second. The fall is a rate on the clock, not a step per draw, so it does
    /// not depend on how often or why the wave is redrawn.
    static let framesPerSecond: Float = 15

    /// How many spectrum frames a stretch of time is worth. Zero when the clock
    /// did not advance (two draws in the same instant) or ran backwards, so such
    /// a draw changes nothing.
    static func frameSteps(elapsed: TimeInterval) -> Float {
        guard elapsed.isFinite, elapsed > 0 else { return 0 }
        return Float(elapsed) * framesPerSecond
    }

    /// Whether the wave overlays the live spectrum on the reference of this
    /// call. It does only when both exist and have the same number of bands;
    /// otherwise, in the opening seconds of a call, it draws the trend of the
    /// confidence score. The wave and the words read aloud for it both rely on
    /// this, so the picture and its label come from one test. The one case it
    /// does not cover: a reference and live bands that are all zero, where the
    /// wave also falls back to the trend (see `overlay`).
    static func overlaysReference(live: [Float]?, reference: [Float]?) -> Bool {
        guard let live = live, let reference = reference else { return false }
        return live.count == reference.count
    }

    static func picture(live: [Float]?, reference: [Float]?) -> VoiceWavePicture {
        overlaysReference(live: live, reference: reference) ? .overlay : .trend
    }

    /// The next displayed height of one band after `steps` spectrum frames (one
    /// by default; see `frameSteps`). A louder target is shown at once. A quieter
    /// one is approached geometrically, keeping `fall` of the distance per
    /// frame, so two partial steps give the same height as one whole step: the
    /// result depends on the time that passed, not on how many draws it was cut
    /// into. No steps (or not a number) leave the height where it was.
    static func nextDisplay(previous: Float, target: Float, steps: Float = 1) -> Float {
        if target > previous { return target }
        guard steps > 0 else { return previous }
        let keep = Float(pow(Double(fall), Double(steps)))
        return previous * keep + target * (1 - keep)
    }

    /// The two curves of the overlay, each band as a share (0...1) of the
    /// largest value of EITHER curve.
    struct Overlay: Equatable {
        let reference: [Float]
        let live: [Float]
    }

    /// Both curves are scaled by that one peak so the reference fills the box
    /// whatever the loudness of the caller, and so the curves coincide only when
    /// they really do: scaling each on its own would make them agree even when
    /// they do not. nil when there is nothing to scale by (all zero, or not a
    /// number), and the wave then draws the trend.
    static func overlay(display: [Float], reference: [Float]) -> Overlay? {
        let count = min(display.count, reference.count)
        guard count > 0 else { return nil }
        guard display.prefix(count).allSatisfy({ $0.isFinite }),
              reference.prefix(count).allSatisfy({ $0.isFinite }) else { return nil }
        var peak: Float = 0
        for index in 0..<count {
            peak = max(peak, reference[index], display[index])
        }
        guard peak.isFinite, peak > 0 else { return nil }
        var scaledReference: [Float] = []
        var scaledLive: [Float] = []
        scaledReference.reserveCapacity(count)
        scaledLive.reserveCapacity(count)
        for index in 0..<count {
            scaledReference.append(reference[index] / peak)
            scaledLive.append(display[index] / peak)
        }
        return Overlay(reference: scaledReference, live: scaledLive)
    }

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

/// The words read aloud for the wave, for the picture it is drawing: the two
/// overlaid spectra, or the trend of the confidence score. The pairing lives
/// here, in one place a test can call, so swapping the two labels fails a test.
enum VoiceWaveCopy {
    static func accessibilityLabel(for picture: VoiceWavePicture) -> String {
        switch picture {
        case .overlay:
            return String(localized: "in_call.voice_guard.wave_a11y_overlay",
                          defaultValue: "Spettro della voce attuale sovrapposto a quello del riferimento preso in questa chiamata",
                          comment: "Accessibility label of the wave on the call screen voice check card while it draws the live spectrum of the voice over the reference spectrum taken in this call")
        case .trend:
            return String(localized: "in_call.voice_guard.wave_a11y_trend",
                          defaultValue: "Andamento del punteggio di confidenza combinato in questa chiamata, come variazione rispetto alla media",
                          comment: "Accessibility label of the wave on the call screen voice check card while it draws the trend of the combined confidence score of this call as a variation around its average")
        }
    }
}

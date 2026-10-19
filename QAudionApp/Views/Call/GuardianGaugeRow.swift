import SwiftUI

/// The tone row under the spectrum of the voice ribbon, on a single line: a
/// small label ("Tono"), the whole-number pitch with its unit, and the word for
/// a voice being present or not ("voce" / "silenzio"). The spectral details (see
/// `VoiceSpectralDetails`: "F1 520 · F2 1480 · 4,2 sill/s · HNR 18 dB") follow on
/// the same line and give way first on a narrow screen: they shrink, then are cut
/// from the right, and never wrap. A value that is not a reading is NaN here and
/// prints as a dash; the pitch, the formants, the speech rate and the HNR are all
/// that way.
///
/// It carries no sentence and no colour: a pitch moves with what is being said
/// and says nothing about the person, so it is a measurement, never a verdict.
struct GuardianGaugeRow: View {
    @Environment(\.qaudionScheme) private var scheme

    private let reading: VoiceToneReading
    private let details: String?

    /// Builds the row from the values of one analysis result (NaN where a value
    /// is not valid).
    init(pitchHz: Float,
         pitchVoiced: Bool,
         formant1Hz: Float,
         formant2Hz: Float,
         syllablesPerSecond: Float,
         hnrDecibels: Float) {
        self.reading = VoiceGauges.pitch(hz: pitchHz, voiced: pitchVoiced)
        self.details = VoiceSpectralDetails.text(formant1Hz: formant1Hz,
                                                 formant2Hz: formant2Hz,
                                                 syllablesPerSecond: syllablesPerSecond,
                                                 hnrDecibels: hnrDecibels,
                                                 rateUnit: VoiceTechnicalCopy.syllableUnit,
                                                 locale: VoiceDisplayLocale.app)
    }

    private var label: String {
        String(localized: "in_call.gauge.pitch",
               defaultValue: "Tono",
               comment: "Call screen voice ribbon — label of the pitch reading")
    }

    var body: some View {
        let voiceWord = VoiceToneCopy.voiceWord(voiced: reading.voiced)
        let spoken = VoiceGauges.spokenTone(label: label, reading: reading, voiceWord: voiceWord, details: details)
        HStack(alignment: .lastTextBaseline, spacing: 0) {
            Text(label)
                .tracking(0.5)
                .foregroundStyle(scheme.onSurfaceVariant)
                .scaledMono(11)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.trailing, 8)
                .layoutPriority(1)
            Text(reading.value)
                .foregroundStyle(scheme.onSurface)
                .scaledMono(14, weight: .semibold, relativeTo: .body)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .layoutPriority(1)
            Text(reading.unit)
                .foregroundStyle(scheme.onSurfaceVariant)
                .scaledMono(11)
                .lineLimit(1)
                .padding(.leading, 2)
                .layoutPriority(1)
            Text(voiceWord)
                .foregroundStyle(scheme.onSurfaceVariant)
                .scaledMono(11)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.leading, 10)
                .layoutPriority(1)
            if let details = details {
                Text(details)
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .scaledMono(11)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .truncationMode(.tail)
                    .padding(.leading, 10)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spoken))
    }
}

/// Shown in place of the pitch reading until the first voice analysis of the
/// call exists.
struct GuardianWaitingForVoice: View {
    @Environment(\.qaudionScheme) private var scheme

    var body: some View {
        Text(String(localized: "in_call.gauge.waiting",
                    defaultValue: "in attesa di voce…",
                    comment: "Call screen voice ribbon — shown in place of the pitch reading until the first voice analysis of the call is available"))
            .foregroundStyle(scheme.onSurfaceVariant)
            .scaledMono(11)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

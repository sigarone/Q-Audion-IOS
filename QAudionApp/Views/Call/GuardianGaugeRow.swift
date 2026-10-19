import SwiftUI

/// The tone row under the spectrum of the voice ribbon, on a single line: a
/// small label ("Tono"), the whole-number pitch with its unit (or the dash alone,
/// never "— Hz"), and the word for a voice being present or not ("voce" /
/// "silenzio"). The spectral details (see `VoiceSpectralDetails`: "F1 520 ·
/// F2 1480 · 4,2 sill/s · HNR 18 dB") follow on the same line and give way first
/// on a narrow screen: they are drawn at one size, fitted to the widest line they
/// can take and not to the text they show (`VoiceDetailsLine`), down to 70 % of
/// the full size, then cut from the right, and never wrap. A value that is not a
/// reading is NaN here and prints as a dash; the pitch, the formants, the speech
/// rate and the HNR are all that way.
///
/// It carries no sentence and no colour: a pitch moves with what is being said
/// and says nothing about the person, so it is a measurement, never a verdict.
struct GuardianGaugeRow: View {
    @Environment(\.qaudionScheme) private var scheme

    private let reading: VoiceToneReading
    private let details: String?
    /// The widest line the details can take, in the language of the app: the details are sized on it.
    private let detailsTemplate: String

    /// Builds the row from the values of one analysis result (NaN where a value
    /// is not valid).
    init(pitchHz: Float,
         pitchVoiced: Bool,
         formant1Hz: Float,
         formant2Hz: Float,
         syllablesPerSecond: Float,
         hnrDecibels: Float) {
        let rateUnit: String = VoiceTechnicalCopy.syllableUnit
        let locale: Locale = VoiceDisplayLocale.app
        self.reading = VoiceGauges.pitch(hz: pitchHz, voiced: pitchVoiced)
        self.details = VoiceSpectralDetails.text(formant1Hz: formant1Hz,
                                                 formant2Hz: formant2Hz,
                                                 syllablesPerSecond: syllablesPerSecond,
                                                 hnrDecibels: hnrDecibels,
                                                 rateUnit: rateUnit,
                                                 locale: locale)
        self.detailsTemplate = VoiceSpectralDetails.widestLine(rateUnit: rateUnit, locale: locale)
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
            if !reading.unit.isEmpty {
                Text(reading.unit)
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .scaledMono(11)
                    .lineLimit(1)
                    .padding(.leading, 2)
                    .layoutPriority(1)
            }
            Text(voiceWord)
                .foregroundStyle(scheme.onSurfaceVariant)
                .scaledMono(11)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.leading, 10)
                .layoutPriority(1)
            if let details = details {
                // Takes the rest of the row by itself (no spacer after it).
                VoiceDetailsLine(text: details, template: detailsTemplate)
                    .padding(.leading, 10)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spoken))
    }
}

/// The details of the tone row, on one line and at ONE size. The size is decided
/// from the widest line the details can take in the language of the app (`template`,
/// see `VoiceSpectralDetails.widestLine`), measured at the size of the reader's
/// Dynamic Type setting, and the real text is drawn at that size: it is the same
/// whether a field is a number or a dash (docs/voice-analysis-spec.md, section
/// 12.5). The decision is `VoiceLineFit.fontSize`; this view only measures the
/// width it is given and the width of the template, and asks. The size stops at
/// 70 % of the full size, and under that the line is cut from the right. Until
/// both widths are measured the text is drawn at the full size.
struct VoiceDetailsLine: View {
    @Environment(\.qaudionScheme) private var scheme
    /// The font size at the reader's Dynamic Type setting, the same base as `scaledMono(11)`.
    @ScaledMetric(relativeTo: .caption) private var baseSize: CGFloat = 11

    let text: String
    let template: String

    @State private var availableWidth: CGFloat?
    @State private var templateWidth: CGFloat?

    private var fontSize: CGFloat {
        guard let available = availableWidth, let measuredTemplate = templateWidth else { return baseSize }
        let size: Double = VoiceLineFit.fontSize(baseSize: Double(baseSize),
                                                 availableWidth: Double(available),
                                                 templateWidth: Double(measuredTemplate))
        return CGFloat(size)
    }

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .medium, design: .monospaced))
            .foregroundStyle(scheme.onSurfaceVariant)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(availableWidthProbe)
            .background(templateWidthProbe)
            .onPreferenceChange(DetailsAvailableWidthKey.self) { newValue in
                if !Self.sameWidth(availableWidth, newValue) { availableWidth = newValue }
            }
            .onPreferenceChange(DetailsTemplateWidthKey.self) { newValue in
                if !Self.sameWidth(templateWidth, newValue) { templateWidth = newValue }
            }
    }

    /// Reports the width the line is given (the frame above takes the rest of the row).
    private var availableWidthProbe: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: DetailsAvailableWidthKey.self, value: proxy.size.width)
        }
    }

    /// Reports the natural width of the widest line at the full size. Drawn invisible, and it takes no
    /// room of its own: it is a background.
    private var templateWidthProbe: some View {
        Text(template)
            .font(.system(size: baseSize, weight: .medium, design: .monospaced))
            .lineLimit(1)
            .fixedSize()
            .hidden()
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: DetailsTemplateWidthKey.self, value: proxy.size.width)
                }
            )
    }

    /// Two widths less than half a point apart are the same: no state change, no new layout.
    private static func sameWidth(_ lhs: CGFloat?, _ rhs: CGFloat?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (a?, b?):
            return abs(a - b) < 0.5
        default:
            return false
        }
    }
}

private struct DetailsAvailableWidthKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

private struct DetailsTemplateWidthKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
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

import SwiftUI

/// The pitch reading under the spectrum of the voice ribbon: a neutral label
/// ("Tono"), the whole-number value with its unit, and a line saying what the
/// number is. It makes no claim about the person: a pitch is a measurement,
/// never a verdict, so it is never coloured and never carries a status word.
struct GuardianGaugeRow: View {
    @Environment(\.qaudionScheme) private var scheme

    let pitch: VoiceGaugeReading

    /// Builds the reading from the values of one analysis result.
    init(pitchHz: Float, pitchVoiced: Bool) {
        self.pitch = VoiceGauges.pitch(hz: pitchHz, voiced: pitchVoiced)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            GuardianGaugeCell(
                label: String(localized: "in_call.gauge.pitch",
                              defaultValue: "Tono",
                              comment: "Call screen voice ribbon — label of the pitch reading"),
                reading: pitch)
            Text(String(localized: "in_call.gauge.pitch_note",
                        defaultValue: "Quanto è alta o bassa la voce dell'altra persona in questo momento.",
                        comment: "Call screen voice ribbon — one-line explanation under the pitch reading: how high or low the voice of the other person (the received audio) is right now; it states what the number is, with no conclusion about the person"))
                .foregroundStyle(scheme.onSurfaceVariant)
                .scaledMono(11)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GuardianGaugeCell: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras

    let label: String
    let reading: VoiceGaugeReading

    private var statusText: String {
        reading.status.localizedText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .tracking(0.5)
                .foregroundStyle(scheme.onSurfaceVariant)
                .scaledMono(11)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(reading.value)
                    .foregroundStyle(scheme.onSurface)
                    .scaledMono(14, weight: .semibold, relativeTo: .body)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !reading.unit.isEmpty {
                    Text(reading.unit)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .scaledMono(11)
                        .lineLimit(1)
                }
            }
            if !statusText.isEmpty {
                Text(statusText)
                    .tracking(0.4)
                    .foregroundStyle(reading.tone.color(scheme: scheme, extras: extras))
                    .scaledMono(11)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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

extension VoiceGaugeStatus {
    /// The text printed under the pitch value. The dash is not language, so it
    /// is not in the catalog.
    var localizedText: String {
        switch self {
        case .none:
            return ""
        case .dash:
            return VoiceGauges.noValue
        }
    }
}

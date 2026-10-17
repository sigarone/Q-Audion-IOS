import SwiftUI

/// The three voice gauges under the spectrum of the voice ribbon: stress,
/// breath (harmonic-to-noise ratio) and pitch. Each cell shows the label, the
/// whole-number value with its unit, and a one-word status in the colour of
/// its role.
struct GuardianGaugeRow: View {
    @Environment(\.qaudionScheme) private var scheme
    @ScaledMetric(relativeTo: .caption) private var dividerHeight: CGFloat = 38

    let stress: VoiceGaugeReading
    let breath: VoiceGaugeReading
    let pitch: VoiceGaugeReading

    /// Builds the readings from the values of one analysis result.
    /// `stressPoints` is the stress score on a 0...100 scale.
    init(stressPoints: Float, hnr: Float, pitchHz: Float, pitchVoiced: Bool) {
        self.stress = VoiceGauges.stress(points: stressPoints)
        self.breath = VoiceGauges.breath(hnr: hnr)
        self.pitch = VoiceGauges.pitch(hz: pitchHz, voiced: pitchVoiced)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            GuardianGaugeCell(
                label: String(localized: "in_call.gauge.stress",
                              defaultValue: "STRESS",
                              comment: "Call screen voice ribbon — label of the stress gauge"),
                reading: stress)
            divider
            GuardianGaugeCell(
                label: String(localized: "in_call.gauge.breath",
                              defaultValue: "RESPIRO·HNR",
                              comment: "Call screen voice ribbon — label of the breath gauge (harmonic-to-noise ratio)"),
                reading: breath)
            divider
            GuardianGaugeCell(
                label: String(localized: "in_call.gauge.pitch",
                              defaultValue: "TONO",
                              comment: "Call screen voice ribbon — label of the pitch gauge"),
                reading: pitch)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(scheme.outline.opacity(0.5))
            .frame(width: 1, height: dividerHeight)
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

/// Shown in place of the gauges until the first voice analysis of the call
/// exists.
struct GuardianWaitingForVoice: View {
    @Environment(\.qaudionScheme) private var scheme

    var body: some View {
        Text(String(localized: "in_call.gauge.waiting",
                    defaultValue: "in attesa di voce…",
                    comment: "Call screen voice ribbon — shown in place of the gauges until the first voice analysis of the call is available"))
            .foregroundStyle(scheme.onSurfaceVariant)
            .scaledMono(11)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension VoiceGaugeStatus {
    /// The word printed under a gauge value. The unit symbols and the dash are
    /// not language, so they are not in the catalog.
    var localizedText: String {
        switch self {
        case .none:
            return ""
        case .dash:
            return VoiceGauges.noValue
        case .calm:
            return String(localized: "in_call.gauge.status.calm",
                          defaultValue: "calmo",
                          comment: "Call screen voice ribbon — stress gauge status word for a calm voice")
        case .elevated:
            return String(localized: "in_call.gauge.status.elevated",
                          defaultValue: "elevato",
                          comment: "Call screen voice ribbon — stress gauge status word for an elevated stress")
        case .high:
            return String(localized: "in_call.gauge.status.high",
                          defaultValue: "alto",
                          comment: "Call screen voice ribbon — stress gauge status word for a high stress")
        case .clear:
            return String(localized: "in_call.gauge.status.clear",
                          defaultValue: "chiaro",
                          comment: "Call screen voice ribbon — breath gauge status word for a clear voice")
        case .mild:
            return String(localized: "in_call.gauge.status.mild",
                          defaultValue: "lieve",
                          comment: "Call screen voice ribbon — breath gauge status word for a mildly breathy voice")
        case .hoarse:
            return String(localized: "in_call.gauge.status.hoarse",
                          defaultValue: "rauco",
                          comment: "Call screen voice ribbon — breath gauge status word for a hoarse voice or a noisy link")
        }
    }
}

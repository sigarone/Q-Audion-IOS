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
            if !reading.status.isEmpty {
                Text(reading.status)
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

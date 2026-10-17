import SwiftUI

/// The "voice biometrics" section of the call security sheet: one row per
/// measurement, each with its value (coloured when it has a verdict) and a
/// plain-language note on how to read it. Without an analysis it shows a single
/// line saying so.
struct VoiceBiometricsSection: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    let biometrics: InCallScreen.VoiceBiometrics?

    var body: some View {
        if let bio = biometrics {
            rows(bio)
        } else {
            Text("Biometria vocale non disponibile per questa chiamata.")
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurfaceVariant)
        }
    }

    private func rows(_ bio: InCallScreen.VoiceBiometrics) -> some View {
        let authenticity = VoiceBiometricsFormat.authenticity(bio.confidence)
        let stress = VoiceBiometricsFormat.stress(points: bio.stressScore * 100)
        let breath = VoiceBiometricsFormat.breath(hnr: bio.hnr, breathiness: bio.breathiness)
        let jitterShimmer = VoiceBiometricsFormat.jitterShimmer(jitter: bio.jitter, shimmer: bio.shimmer)
        let pitchRate = VoiceBiometricsFormat.pitchRate(hz: bio.pitchHz, syllablesPerSecond: bio.syllablesPerSec)
        return VStack(alignment: .leading, spacing: 0) {
            BiometricRow(label: BioCopy.authenticity, value: authenticity.text,
                         valueColor: color(authenticity.tone), note: BioCopy.authenticityNote)
            BiometricRow(label: BioCopy.stress, value: stress.text,
                         valueColor: color(stress.tone), note: BioCopy.stressNote)
            BiometricRow(label: BioCopy.jitterShimmer, value: jitterShimmer,
                         valueColor: scheme.onSurface, note: BioCopy.jitterShimmerNote)
            BiometricRow(label: BioCopy.breath, value: breath.text,
                         valueColor: color(breath.tone), note: BioCopy.breathNote)
            BiometricRow(label: BioCopy.pitchRate, value: pitchRate,
                         valueColor: scheme.onSurface, note: BioCopy.pitchRateNote)
        }
    }

    private func color(_ tone: VoiceTone) -> Color {
        tone.color(scheme: scheme, extras: extras)
    }
}

/// The texts of the section, kept apart from the layout.
private enum BioCopy {
    static var authenticity: String {
        String(localized: "in_call.bio.authenticity",
               defaultValue: "Autenticità",
               comment: "Call security sheet, voice biometrics — row label for the authenticity score of the voice")
    }
    static var authenticityNote: String {
        String(localized: "in_call.bio.authenticity_note",
               defaultValue: ">0.80 genuina · 0.50–0.80 verifica con SAS · <0.50 probabile voce sintetica.",
               comment: "Call security sheet, voice biometrics — how to read the authenticity score")
    }
    static var stress: String {
        String(localized: "in_call.bio.stress",
               defaultValue: "Stress",
               comment: "Call security sheet, voice biometrics — row label for the vocal stress score")
    }
    static var stressNote: String {
        String(localized: "in_call.bio.stress_note",
               defaultValue: "10–35 rilassato · >60 agitato / possibile coercizione — un picco sostenuto va verificato a voce.",
               comment: "Call security sheet, voice biometrics — how to read the stress score")
    }
    static var jitterShimmer: String {
        String(localized: "in_call.bio.jitter_shimmer",
               defaultValue: "Jitter / Shimmer",
               comment: "Call security sheet, voice biometrics — row label for pitch jitter and amplitude shimmer")
    }
    static var jitterShimmerNote: String {
        String(localized: "in_call.bio.jitter_shimmer_note",
               defaultValue: "Normale su questo microfono (con AEC/NS attivi): jitter sotto il 6 per cento, shimmer sotto il 12 per cento. Valori oltre 15/25 indicano forte instabilità della voce.",
               comment: "Call security sheet, voice biometrics — how to read jitter and shimmer")
    }
    static var breath: String {
        String(localized: "in_call.bio.breath",
               defaultValue: "Respiro · HNR",
               comment: "Call security sheet, voice biometrics — row label for breath (harmonic-to-noise ratio)")
    }
    static var breathNote: String {
        String(localized: "in_call.bio.breath_note",
               defaultValue: "≥ 15 dB chiaro · 10–15 dB lieve · < 10 dB rauco o link rumoroso.",
               comment: "Call security sheet, voice biometrics — how to read the breath value; the limits are those of the breath gauge on the voice ribbon")
    }
    static var pitchRate: String {
        String(localized: "in_call.bio.pitch_rate",
               defaultValue: "Tono f0 · ritmo",
               comment: "Call security sheet, voice biometrics — row label for pitch and speech rate")
    }
    static var pitchRateNote: String {
        String(localized: "in_call.bio.pitch_rate_note",
               defaultValue: "Ritmo normale 3–5 sillabe al secondo, pause tra il 20 e il 40 per cento del tempo. Un cambio improvviso rispetto al tono abituale del contatto può segnalare una sostituzione.",
               comment: "Call security sheet, voice biometrics — how to read pitch and speech rate")
    }
}

private struct BiometricRow: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    let label: String
    let value: String
    let valueColor: Color
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                Text(label)
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .scaledMono(11)
                Spacer(minLength: 8)
                Text(value)
                    .foregroundStyle(valueColor)
                    .scaledMono(14, weight: .semibold, relativeTo: .body)
                    .multilineTextAlignment(.trailing)
            }
            Text(note)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

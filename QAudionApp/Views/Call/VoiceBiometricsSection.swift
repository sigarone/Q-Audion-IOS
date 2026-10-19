import SwiftUI

/// The "voice biometrics" section of the call security sheet. Every raw
/// measure of the voice (jitter and shimmer, pitch and speech rate, HNR) lives
/// here, in one block that is collapsed until the user opens it and titled as
/// not validated: these numbers have not been validated for phone-quality
/// speech, so they are plain values, never coloured and never read as a claim
/// about the person (no stress, breath, authenticity or risk reading). A value
/// that is not a reading right now is a dash. Without any measure it shows a
/// single line saying so.
struct VoiceBiometricsSection: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    let biometrics: InCallScreen.VoiceBiometrics?

    /// Collapsed by default, and again every time the sheet is presented.
    @State private var expanded = false

    var body: some View {
        if biometrics != nil {
            DisclosureGroup(isExpanded: $expanded) {
                rows
                    .padding(.top, 6)
            } label: {
                Text(VoiceTechnicalCopy.title)
                    .qaudionStyle(type.labelMedium)
                    .foregroundStyle(scheme.onSurface)
            }
        } else {
            Text(BioCopy.unavailable)
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurfaceVariant)
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(VoiceTechnicalCopy.note)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)
            if let bio = biometrics {
                BiometricRow(label: BioCopy.jitterShimmer,
                             value: VoiceBiometricsFormat.jitterShimmer(jitterPercent: bio.jitter * 100,
                                                                        shimmerPercent: bio.shimmer * 100,
                                                                        locale: VoiceDisplayLocale.app))
                BiometricRow(label: BioCopy.pitchRate,
                             value: VoiceBiometricsFormat.pitchRate(hz: bio.pitchHz,
                                                                    syllablesPerSecond: bio.syllablesPerSec,
                                                                    syllableUnit: BioCopy.syllableUnit,
                                                                    locale: VoiceDisplayLocale.app))
                BiometricRow(label: BioCopy.hnr, value: VoiceBiometricsFormat.hnr(bio.hnr))
            }
        }
    }
}

/// The title and the note of the technical-data block, shared with the video
/// call diagnostics so both say the same thing. It also holds the abbreviation
/// of syllables per second, which the security sheet and the tone row of the
/// ribbon both print next to the speech rate.
enum VoiceTechnicalCopy {
    static var title: String {
        String(localized: "in_call.bio.technical_title",
               defaultValue: "Dati tecnici (non validati)",
               comment: "Call security sheet and video diagnostics — title of the collapsed block that holds every raw voice measure; it says up front that they are not validated")
    }
    static var note: String {
        String(localized: "in_call.bio.technical_note",
               defaultValue: "Misure non ancora validate per la voce al telefono. Non indicano lo stato di una persona.",
               comment: "Call security sheet and video diagnostics — note inside the technical-data block: the raw voice measures are not validated for phone-quality speech and say nothing about the state of a person")
    }
    static var syllableUnit: String {
        String(localized: "in_call.bio.syllables_unit",
               defaultValue: "sill/s",
               comment: "Call security sheet, voice biometrics — abbreviation of syllables per second, next to the speech rate")
    }
}

/// The texts of the section, kept apart from the layout.
private enum BioCopy {
    static var unavailable: String {
        String(localized: "in_call.bio.unavailable",
               defaultValue: "Analisi vocale non disponibile per questa chiamata.",
               comment: "Call security sheet, voice section — shown when no voice analysis is available for the call")
    }
    static var syllableUnit: String {
        VoiceTechnicalCopy.syllableUnit
    }
    static var jitterShimmer: String {
        String(localized: "in_call.bio.jitter_shimmer",
               defaultValue: "Jitter / Shimmer",
               comment: "Call security sheet, voice biometrics — row label for pitch jitter and amplitude shimmer")
    }
    static var pitchRate: String {
        String(localized: "in_call.bio.pitch_rate",
               defaultValue: "Tono f0 · ritmo",
               comment: "Call security sheet, voice biometrics — row label for pitch and speech rate")
    }
    static var hnr: String {
        String(localized: "in_call.bio.hnr",
               defaultValue: "HNR",
               comment: "Call security sheet, voice biometrics — row label for the harmonic-to-noise ratio, in dB (a raw measure, not a verdict)")
    }
}

/// The locale the numbers of the voice analysis are printed in: the language of the app (the user can set it
/// apart from the device), never the region of the device, so the decimal separator of the tone row, the
/// technical-data block and the video diagnostics follows the unit and the words next to it
/// (docs/voice-analysis-spec.md, section 12.2). It is taken from the same place as the text
/// (`AppLanguageManager.effectiveLanguageCode`), fallback included: a device language the app does
/// not have shows the Italian text and prints the Italian separator.
enum VoiceDisplayLocale {
    static var app: Locale {
        Locale(identifier: AppLanguageManager.effectiveLanguageCode)
    }

    /// The locale the screens would use for a given override and a given list of preferred languages of
    /// the device: the same choice as `app` (`AppLanguageManager.languageCode`), with the inputs given
    /// instead of read, so that the separator can be checked for any device setting.
    static func locale(override: String?, preferredLanguages: [String]) -> Locale {
        Locale(identifier: AppLanguageManager.languageCode(override: override, preferredLanguages: preferredLanguages))
    }

    /// `locale(override:preferredLanguages:)` for a device with a single preferred language.
    static func locale(override: String?, preferredLanguage: String?) -> Locale {
        locale(override: override, preferredLanguages: preferredLanguage.map { [$0] } ?? [])
    }
}

private struct BiometricRow: View {
    @Environment(\.qaudionScheme) private var scheme

    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            Text(label)
                .foregroundStyle(scheme.onSurfaceVariant)
                .scaledMono(11)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(scheme.onSurface)
                .scaledMono(14, weight: .semibold, relativeTo: .body)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

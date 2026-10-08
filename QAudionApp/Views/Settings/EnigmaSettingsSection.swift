import SwiftUI
import QAudionEngine

/// Settings > Privacy > "Modalità Enigma": Off (default) / Leggera / Scenografica.
///
/// Shown only while the remote flag `enigma_mode.enabled` is on (default OFF): with the flag off the entry does not appear
/// and the effect is off whatever is stored. The line under the control says what it is: a visual effect that changes nothing
/// about the security of the messages.
///
/// Takes no AppState (CLAUDE.md section 16): the flag and the stored level are read through `EnigmaFeature` / `EnigmaSettings`.
struct EnigmaSettingsSection: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    @State private var level: Int = EnigmaSettings.storedLevel().rawValue

    var body: some View {
        if EnigmaFeature.flagOn {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(Self.sectionTitle)
            VStack(alignment: .leading, spacing: 8) {
                Picker(Self.rowTitle, selection: levelBinding) {
                    Text(Self.optionOff).tag(0)
                    Text(Self.optionLite).tag(1)
                    Text(Self.optionFull).tag(2)
                }
                .pickerStyle(.segmented)
                Text(Self.caption)
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(scheme.surfaceVariant.opacity(0.4))
            )
        }
    }

    private var levelBinding: Binding<Int> {
        Binding(
            get: { level },
            set: { newValue in
                level = newValue
                applyLevel(newValue)
            }
        )
    }

    private func applyLevel(_ raw: Int) {
        EnigmaSettings.setStoredLevel(EnigmaLevel.fromStored(raw))
        EnigmaHost.shared.configurationChanged(flagOn: EnigmaFeature.flagOn)
    }

    private static let sectionTitle: String = String(localized: "enigma.settings.section", defaultValue: "MODALITÀ ENIGMA", comment: "Header of the Enigma mode section in Settings > Privacy.")
    private static let rowTitle: String = String(localized: "enigma.settings.title", defaultValue: "Modalità Enigma", comment: "Title of the Enigma mode control (a visual effect on message bubbles).")
    private static let optionOff: String = String(localized: "enigma.settings.off", defaultValue: "Off", comment: "Enigma mode: effect off (default).")
    private static let optionLite: String = String(localized: "enigma.settings.lite", defaultValue: "Leggera", comment: "Enigma mode: light effect (text morphing only).")
    private static let optionFull: String = String(localized: "enigma.settings.full", defaultValue: "Scenografica", comment: "Enigma mode: full effect (text morphing and the historical rotors).")
    private static let caption: String = String(localized: "enigma.settings.caption", defaultValue: "Solo effetto visivo. Non cambia la sicurezza dei messaggi.", comment: "Caption under the Enigma mode control: it is only a visual effect.")
}

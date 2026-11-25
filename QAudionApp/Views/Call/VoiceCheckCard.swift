import SwiftUI
import QAudionEngine

/// The state of the contact-voice check that the call screen shows. The engine sets it (through `VoiceCallWiring`) and clears it
/// when the call ends; while the check is off it is never set, so nothing is drawn.
final class VoiceCheckModel: ObservableObject {
    static let shared = VoiceCheckModel()

    @Published private(set) var display: VoiceCheckDisplay?

    /// Called on the main thread (the bridge moves it there).
    func set(_ new: VoiceCheckDisplay?) {
        if display != new { display = new }
    }
}

/// The words of the card. Non-accusatory: nothing here says impostor, fake, deepfake or fraud. `name` is the contact's name.
enum VoiceCheckCopy {
    static func line(for display: VoiceCheckDisplay, name: String) -> String {
        switch display {
        case .matches:
            return String(localized: "in_call.voice_check.matches", defaultValue: "La voce corrisponde",
                          comment: "Call screen voice check card — the voice matches the one learned")
        case .checking, .checkingDifferentSetup:
            return String(localized: "in_call.voice_check.checking", defaultValue: "Verifica della voce",
                          comment: "Call screen voice check card — the voice is being checked")
        case .differs:
            return String(localized: "in_call.voice_check.differs", defaultValue: "La voce sembra diversa da quella appresa",
                          comment: "Call screen voice check card — the voice sounds different from the one learned")
        case .differsNewDevice:
            let format = String(localized: "in_call.voice_check.differs_new_device",
                                defaultValue: "La voce sembra diversa e %@ chiama da un dispositivo non usato nelle chiamate precedenti",
                                comment: "Call screen voice check card — different voice and a device not used before; %@ is the contact name")
            return String(format: format, name)
        case .off:
            return String(localized: "in_call.voice_check.off", defaultValue: "Verifica della voce disattivata per questa chiamata",
                          comment: "Call screen voice check card — the check is off for this call")
        case .cannotVerify:
            return String(localized: "in_call.voice_check.cannot_verify", defaultValue: "Voce non verificabile ora (qualità audio)",
                          comment: "Call screen voice check card — the voice cannot be checked at the moment")
        case .learning:
            return String(localized: "in_call.voice_check.learning", defaultValue: "Apprendimento della voce",
                          comment: "Call screen voice check card — the voice is being learned")
        case .changed:
            return String(localized: "in_call.voice_check.changed", defaultValue: "La voce sembra cambiata durante la chiamata",
                          comment: "Call screen voice check card — the voice seems to have changed during the call")
        }
    }

    /// The text of the popup that a tap opens, for the states that have one.
    static func detail(for display: VoiceCheckDisplay, name: String) -> String? {
        switch display {
        case .checkingDifferentSetup:
            return String(localized: "in_call.voice_check.checking_setup_detail",
                          defaultValue: "Questa chiamata usa una configurazione diversa da quelle in cui la voce è stata appresa, quindi la voce viene solo verificata.",
                          comment: "Call screen voice check card — detail while the call uses a setup the voice was not learned on")
        case .differs, .differsNewDevice:
            let format = String(localized: "in_call.voice_check.differs_detail",
                                defaultValue: "Può succedere con un raffreddore, un telefono nuovo, un auricolare o una linea disturbata. Il codice di sicurezza conferma che la chiamata arriva al dispositivo di %1$@, ma non chi sta parlando. Nel dubbio, chiedi qualcosa che solo %1$@ può sapere, oppure richiama più tardi.",
                                comment: "Call screen voice check card — detail when the voice sounds different; %1$@ is the contact name")
            return String(format: format, name)
        default:
            return nil
        }
    }

    /// The two actions of the detail of a Differs state: "It was <name>" (it marks the call, no trust state and no tier changes) and
    /// "Compare security code" (the existing security code view).
    static func offersActions(for display: VoiceCheckDisplay) -> Bool {
        display == .differs || display == .differsNewDevice
    }

    static func wasHimTitle(name: String) -> String {
        let format = String(localized: "in_call.voice_check.was_him", defaultValue: "Era %@",
                            comment: "Call screen voice check card, detail popup of the Differs state: marks this call as made by the contact; %@ is the contact name")
        return String(format: format, name)
    }

    static var compareCodeTitle: String {
        String(localized: "in_call.voice_check.compare_code", defaultValue: "Confronta il codice di sicurezza",
               comment: "Call screen voice check card, detail popup of the Differs state: opens the security code of the call")
    }

    static func tone(for display: VoiceCheckDisplay) -> VoiceTone {
        switch display {
        case .matches: return .success
        case .differs, .differsNewDevice, .changed: return .warning
        case .checking, .checkingDifferentSetup, .off, .cannotVerify, .learning: return .neutral
        }
    }

    static func iconName(for display: VoiceCheckDisplay) -> String {
        switch display {
        case .matches: return "checkmark"
        case .differs, .differsNewDevice, .changed: return "exclamationmark.triangle"
        case .checking, .checkingDifferentSetup, .off, .cannotVerify, .learning: return "mic"
        }
    }
}

/// The card of the contact-voice check: an icon and one line, under the voice card of the call screen. It draws nothing while
/// there is no state, which is every call while the check is off. No sound, no vibration, no red.
struct VoiceCheckCard: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject private var model = VoiceCheckModel.shared
    let contactName: String
    /// Opens the security code of the call (the existing view); it changes no trust state and no tier.
    var onCompareCode: () -> Void = {}
    @State private var showingDetail = false

    var body: some View {
        if let display = model.display {
            card(display)
        }
    }

    private func card(_ display: VoiceCheckDisplay) -> some View {
        let tone = VoiceCheckCopy.tone(for: display)
        let line = VoiceCheckCopy.line(for: display, name: contactName)
        let detail = VoiceCheckCopy.detail(for: display, name: contactName)
        return VStack(spacing: 0) {
            Spacer().frame(height: 6)
            HStack(spacing: 10) {
                Image(systemName: VoiceCheckCopy.iconName(for: display))
                    .qaudionScaledFont(size: 16, weight: .semibold, maxSize: .xLarge)
                    .foregroundStyle(tone.color(scheme: scheme, extras: extras))
                    .accessibilityHidden(true)
                Text(line)
                    .foregroundStyle(tone.color(scheme: scheme, extras: extras))
                    .scaledMono(11, weight: .semibold)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(scheme.surface.opacity(reduceTransparency ? 1.0 : 0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(scheme.outline.opacity(0.5), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture { if detail != nil { showingDetail = true } }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(line))
            .alert(Text(VoiceGuardCopy.title), isPresented: $showingDetail) {
                if VoiceCheckCopy.offersActions(for: display) {
                    Button(VoiceCheckCopy.wasHimTitle(name: contactName)) {
                        showingDetail = false
                        AppState.shared.voiceCheckWasHim()
                    }
                    Button(VoiceCheckCopy.compareCodeTitle) {
                        showingDetail = false
                        onCompareCode()
                    }
                }
                Button("Ho capito") { showingDetail = false }
            } message: {
                Text(detail ?? "")
            }
        }
        .padding(.horizontal, 20)
    }
}

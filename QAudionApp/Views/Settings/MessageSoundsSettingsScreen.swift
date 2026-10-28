import SwiftUI
import Combine

/// State and actions of the message-sounds screen: the on/off switch, the sound, the vibration. The values live in
/// `MessageSoundStore`; `NotificationCenterService` reads them when a message notification is posted or shown.
@MainActor
final class MessageSoundsSettingsContainer: ObservableObject {

    @Published private(set) var settings: MessageSoundSettings
    private let store: MessageSoundStore

    init(store: MessageSoundStore = MessageSoundStore(), legacyInAppSound: Bool = NotificationsGate.inAppSoundEnabled) {
        self.store = store
        self.settings = store.load(legacyInAppSound: legacyInAppSound)
    }

    func setSoundEnabled(_ enabled: Bool) {
        update { $0.soundEnabled = enabled }
    }

    func setHapticEnabled(_ enabled: Bool) {
        update { $0.hapticEnabled = enabled }
    }

    /// Selects a sound and plays it once, so the choice can be heard.
    func select(_ id: String) {
        guard MessageSoundCatalog.isKnown(id) else { return }
        update { $0.soundId = id }
        preview(id)
    }

    func preview(_ id: String) {
        var heard = settings
        heard.soundEnabled = true
        heard.soundId = id
        MessageSoundPlayer.shared.play(MessageSoundPolicy.sound(for: heard, quietNow: false))
    }

    private func update(_ change: (inout MessageSoundSettings) -> Void) {
        var next = settings
        change(&next)
        settings = next
        store.save(next)
        Task.detached(priority: .utility) { MessageAlertSoundFile.syncCurrent() }
    }
}

/// Settings, Notifications, "Suoni dei messaggi".
struct MessageSoundsSettingsScreen: View {
    @StateObject private var container = MessageSoundsSettingsContainer()

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    private func loc(_ key: String.LocalizationValue) -> String { String(localized: key) }

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    soundSection
                    toneSection
                    vibrationSection
                    footerSection
                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
            }
        }
        .navigationTitle(loc("Suoni dei messaggi"))
    }

    private var soundSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(loc("Suono").uppercased())
            SettingsToggleRow(
                title: loc("Suono dei messaggi"),
                subtitle: loc("Riproduce un suono quando arriva un messaggio"),
                isOn: Binding(get: { container.settings.soundEnabled }, set: { container.setSoundEnabled($0) }))
        }
    }

    private var toneSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(loc("Tono").uppercased())
            toneRow(id: MessageSoundCatalog.systemId, title: loc("Predefinito di sistema"))
            ForEach(MessageSoundCatalog.bundledIds, id: \.self) { id in
                toneRow(id: id, title: toneName(id))
            }
        }
        .opacity(container.settings.soundEnabled ? 1 : 0.5)
        .disabled(!container.settings.soundEnabled)
    }

    private var vibrationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(loc("Vibrazione").uppercased())
            SettingsToggleRow(
                title: loc("Vibrazione"),
                subtitle: loc("Vibra quando arriva un messaggio mentre l'app è aperta"),
                isOn: Binding(get: { container.settings.hapticEnabled }, set: { container.setHapticEnabled($0) }))
        }
    }

    /// The two things the app cannot control are said, not faked with a slider or a switch.
    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc("Il volume è quello del sistema: si regola con i tasti del volume."))
                .qaudionStyle(type.labelSmall).foregroundStyle(scheme.onSurfaceVariant).padding(.horizontal, 14)
            Text(loc("Le app non possono controllare il flash LED. Attivalo in Impostazioni > Accessibilità > Audio e video > Flash LED per avvisi."))
                .qaudionStyle(type.labelSmall).foregroundStyle(scheme.onSurfaceVariant).padding(.horizontal, 14)
        }
        .padding(.top, 16)
    }

    private func toneName(_ id: String) -> String {
        switch id {
        case "goccia": return loc("Goccia")
        case "nota": return loc("Nota")
        case "tocco": return loc("Tocco")
        case "doppio": return loc("Doppio")
        case "brezza": return loc("Brezza")
        default: return id
        }
    }

    private func toneRow(id: String, title: String) -> some View {
        let selected = MessageSoundCatalog.normalized(container.settings.soundId) == id
        return HStack(spacing: 14) {
            Button { container.select(id) } label: {
                HStack(spacing: 14) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17)).foregroundStyle(selected ? scheme.primary : scheme.onSurfaceVariant).frame(width: 22)
                    Text(title).qaudionStyle(type.bodyMedium).foregroundStyle(scheme.onSurface).lineLimit(1)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            Button { container.preview(id) } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 14)).foregroundStyle(scheme.onSurfaceVariant).frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(loc("Anteprima"))
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .background(RoundedRectangle(cornerRadius: 12).fill(scheme.surfaceVariant.opacity(0.4)))
    }
}

import SwiftUI
import QAudionEngine

@MainActor
final class PrivacySettingsContainer: ObservableObject {
    @Published var viewModel: PrivacySettingsViewModel
    private let store: SettingsStore

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
        // W404: read from the canonical PrivacyGate UserDefaults keys
        // first; the SettingsStore values become a legacy fallback only
        // if PrivacyGate has never been written. Defaults match prior
        // production behavior so users observe no change.
        let legacy = store.loadPrivacy()
        self.viewModel = PrivacySettingsViewModel(
            readReceiptsEnabled: PrivacyGate.readReceiptsEnabled,
            typingIndicatorEnabled: PrivacyGate.typingIndicatorEnabled,
            presenceVisibleToContacts: PrivacyGate.presenceVisibleToContacts,
            disappearingMessagesDuration: PrivacyGate.disappearingSeconds == 0
                ? legacy.disappearingMessagesDuration
                : PrivacyGate.disappearingSeconds,
            blockedUserIds: legacy.blockedUserIds,
            torEnabled: PrivacyGate.torEnabled
        )
    }

    func toggleReadReceipts(_ enabled: Bool) {
        viewModel = makeUpdated(readReceipts: enabled)
        store.savePrivacy(viewModel)
        PrivacyGate.setReadReceiptsEnabled(enabled)
    }

    func toggleTypingIndicator(_ enabled: Bool) {
        viewModel = makeUpdated(typing: enabled)
        store.savePrivacy(viewModel)
        PrivacyGate.setTypingIndicatorEnabled(enabled)
    }

    func togglePresence(_ enabled: Bool) {
        viewModel = makeUpdated(presence: enabled)
        store.savePrivacy(viewModel)
        PrivacyGate.setPresenceVisibleToContacts(enabled)
    }

    func setDisappearingDuration(_ seconds: TimeInterval) {
        viewModel = makeUpdated(disappearing: seconds)
        store.savePrivacy(viewModel)
        PrivacyGate.setDisappearingSeconds(seconds)
    }

    func toggleTor(_ enabled: Bool) {
        viewModel = makeUpdated(tor: enabled)
        store.savePrivacy(viewModel)
        PrivacyGate.setTorEnabled(enabled)
    }

    private func makeUpdated(
        readReceipts: Bool? = nil,
        typing: Bool? = nil,
        presence: Bool? = nil,
        disappearing: TimeInterval? = nil,
        tor: Bool? = nil
    ) -> PrivacySettingsViewModel {
        PrivacySettingsViewModel(
            readReceiptsEnabled: readReceipts ?? viewModel.readReceiptsEnabled,
            typingIndicatorEnabled: typing ?? viewModel.typingIndicatorEnabled,
            presenceVisibleToContacts: presence ?? viewModel.presenceVisibleToContacts,
            disappearingMessagesDuration: disappearing ?? viewModel.disappearingMessagesDuration,
            blockedUserIds: viewModel.blockedUserIds,
            torEnabled: tor ?? viewModel.torEnabled
        )
    }
}

/// Privacy settings sub-screen. W26 design-token refactor — replaces
/// stock SwiftUI `Form` with the new design vocabulary.
struct PrivacySettingsScreen: View {
    @StateObject private var container: PrivacySettingsContainer

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    init(state: AppState) {
        _container = StateObject(wrappedValue: PrivacySettingsContainer())
    }

    private let durationOptions: [(label: String, value: TimeInterval)] = [
        ("Off",       0),
        ("1 minuto",  60),
        ("1 ora",     3600),
        ("1 giorno",  86400),
        ("7 giorni",  604800)
    ]

    /// W106: hide message content in lock-screen / banner notifications.
    /// When on, the banner body shows "Nuovo messaggio" instead of the
    /// plaintext preview. Read by AppState when scheduling local notifs.
    @AppStorage("qaudion.privacy.hide_notification_content")
    private var hideNotificationContent: Bool = false

    /// W152: link preview / auto-detection toggle. When off, NSDataDetector
    /// won't render http(s) URLs in chat bubbles as tappable links — useful
    /// when the user is suspicious of phishing peers. ChatDetailScreen
    /// reads this @AppStorage key directly.
    @AppStorage("qaudion.privacy.detect_links")
    private var detectLinks: Bool = true

    /// W155: control whether unsent composer drafts are surfaced on the
    /// chat list as "Bozza: …" rows. Off → list always shows the last
    /// message preview, drafts stay invisible from the home screen
    /// (still persisted, still restored when entering the chat).
    @AppStorage("qaudion.privacy.show_drafts_in_list")
    private var showDraftsInList: Bool = true

    /// W160: master haptic feedback kill-switch. Off → all
    /// HapticFeedback.* helpers short-circuit, useful for
    /// accessibility / battery sensitivity.
    @AppStorage("qaudion.haptics.enabled")
    private var hapticsEnabled: Bool = true

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsSectionHeader("BANNER")
                    VStack(spacing: 8) {
                        SettingsToggleRow(
                            title: "Nascondi contenuto notifiche",
                            subtitle: "Mostra solo \"Nuovo messaggio\" nei banner",
                            isOn: $hideNotificationContent
                        )
                    }
                    SettingsSectionHeader("MESSAGGI")
                    VStack(spacing: 8) {
                        SettingsToggleRow(
                            title: "Conferme di lettura",
                            subtitle: "Notifica al mittente quando hai letto",
                            isOn: Binding(
                                get: { container.viewModel.readReceiptsEnabled },
                                set: { container.toggleReadReceipts($0) }
                            )
                        )
                        SettingsToggleRow(
                            title: "Indicatore di scrittura",
                            subtitle: "Mostra quando stai scrivendo",
                            isOn: Binding(
                                get: { container.viewModel.typingIndicatorEnabled },
                                set: { container.toggleTypingIndicator($0) }
                            )
                        )
                        SettingsToggleRow(
                            title: "Presenza visibile",
                            // W411 honest copy: client-side gating limits
                            // what we subscribe to. Full server-side
                            // hiding richiede endpoint dedicato non
                            // ancora esposto.
                            subtitle: "Off: non vedi quando i contatti sono online (l'app non si iscrive ai loro stati)",
                            isOn: Binding(
                                get: { container.viewModel.presenceVisibleToContacts },
                                set: { container.togglePresence($0) }
                            )
                        )
                        // W152: gate URL auto-detection. Off → bubbles
                        // render plain text and any http link the peer
                        // sent stays inert (user must long-press → copy).
                        SettingsToggleRow(
                            title: "Anteprima link",
                            subtitle: "Rileva URL nei messaggi e li rende toccabili",
                            isOn: $detectLinks
                        )
                        // W155: hide drafts from the chat list so a
                        // glance at the home screen doesn't reveal
                        // half-typed messages.
                        SettingsToggleRow(
                            title: "Mostra abbozzi nella lista",
                            subtitle: "Indica le chat con messaggi non inviati",
                            isOn: $showDraftsInList
                        )
                        // W160: master haptic kill-switch.
                        SettingsToggleRow(
                            title: "Vibrazione",
                            subtitle: "Tatto sui tap, invio messaggi e azioni",
                            isOn: $hapticsEnabled
                        )
                    }

                    SettingsSectionHeader("MESSAGGI A SCADENZA")
                    durationPickerRow

                    SettingsSectionHeader("ANONIMIZZAZIONE RETE")
                    VStack(spacing: 8) {
                        SettingsToggleRow(
                            title: "Instrada via Tor",
                            subtitle: "Tutte le connessioni passano per la rete Tor",
                            isOn: Binding(
                                get: { container.viewModel.torEnabled },
                                set: { container.toggleTor($0) }
                            )
                        )
                        if container.viewModel.torEnabled {
                            Text("Tutto il traffico è instradato via Tor. Le chiamate potrebbero avere latenza maggiore.")
                                .qaudionStyle(type.labelSmall)
                                .foregroundStyle(scheme.onSurfaceVariant)
                                .padding(.horizontal, 14)
                        }
                    }

                    if !container.viewModel.blockedUserIds.isEmpty {
                        SettingsSectionHeader("UTENTI BLOCCATI")
                        kvRow(label: "Bloccati",
                              value: "\(container.viewModel.blockedUserIds.count) utente/i",
                              mono: false)
                    }

                    // W284: deep-link into iOS Settings → Privacy &
                    // Security for Q-Audion. Lets the user revisit
                    // mic / contacts / NFC / camera permissions
                    // without hunting through Settings. Sister of
                    // W169 (same destination, different entry point).
                    SettingsSectionHeader("SISTEMA")
                    Button {
                        openIOSPrivacySettings()
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "lock.shield")
                                .font(.system(size: 17, weight: .regular))
                                .foregroundStyle(.orange)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Apri Privacy in Impostazioni iOS")
                                    .qaudionStyle(type.bodyMedium)
                                    .foregroundStyle(scheme.onSurface)
                                Text("Mic · contatti · NFC · fotocamera")
                                    .qaudionStyle(type.labelSmall)
                                    .foregroundStyle(scheme.onSurfaceVariant)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 14, weight: .regular))
                                .foregroundStyle(scheme.onSurfaceVariant)
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 52)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(scheme.surfaceVariant.opacity(0.4))
                        )
                    }
                    .buttonStyle(.plain)

                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
            }
        }
        .navigationTitle("Privacy")
    }

    /// W284: open iOS Settings → Q-Audion entry. Same URL as W169 but
    /// reachable from the Privacy screen (closer to mental context).
    private func openIOSPrivacySettings() {
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }

    // MARK: - Duration picker

    private var durationPickerRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "timer")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(scheme.onSurfaceVariant)
                .frame(width: 22)

            Text("Scadenza")
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)

            Spacer(minLength: 6)

            Picker("Scadenza", selection: Binding(
                get: { container.viewModel.disappearingMessagesDuration },
                set: { container.setDisappearingDuration($0) }
            )) {
                ForEach(durationOptions, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .pickerStyle(.menu)
            .tint(scheme.primary)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }

    private func kvRow(label: String, value: String, mono: Bool) -> some View {
        HStack(spacing: 14) {
            Text(label)
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)
            Spacer()
            Text(value)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .modifier(MonoIfNeededP(mono: mono))
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }
}

private struct MonoIfNeededP: ViewModifier {
    let mono: Bool
    func body(content: Content) -> some View {
        if mono {
            content.font(.system(.caption, design: .monospaced))
        } else {
            content
        }
    }
}

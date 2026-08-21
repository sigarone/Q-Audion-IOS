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
        //
        // 2026-08-10 settings cleanup — two controls were REMOVED from this
        // screen because neither had a consumer anywhere in the app:
        //   • "Instrada via Tor": PrivacyGate.torEnabled was read by this
        //     container and by nothing else. No SOCKS / Tor path ever
        //     consulted it, so the subtitle ("tutte le connessioni passano
        //     per la rete Tor") was a false anonymisation claim on a privacy
        //     screen. The honest, explicitly-disabled row on Impostazioni →
        //     Trasporto (TransportSettingsScreen) is the surviving statement
        //     about Tor on iOS.
        //   • "Messaggi a scadenza / Scadenza": PrivacyGate.disappearingSeconds
        //     was likewise read only here. The TTL that actually ships is the
        //     per-conversation Conversation.ephemeralTimerSeconds
        //     (ChatContainer / ChatDetailScreen), set from the chat itself.
        // Both ViewModel fields are still hydrated from — and saved back to —
        // the legacy SettingsStore blob, so no stored user value is migrated
        // or deleted; they are simply no longer read by anything.
        let legacy = store.loadPrivacy()
        self.viewModel = PrivacySettingsViewModel(
            readReceiptsEnabled: PrivacyGate.readReceiptsEnabled,
            typingIndicatorEnabled: PrivacyGate.typingIndicatorEnabled,
            presenceVisibleToContacts: PrivacyGate.presenceVisibleToContacts,
            disappearingMessagesDuration: legacy.disappearingMessagesDuration,
            blockedUserIds: legacy.blockedUserIds,
            torEnabled: legacy.torEnabled
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

    // 2026-08-10: setDisappearingDuration / toggleTor deleted together with
    // their controls (see the note in init). The two fields below are carried
    // through unchanged so savePrivacy round-trips the stored value.
    private func makeUpdated(
        readReceipts: Bool? = nil,
        typing: Bool? = nil,
        presence: Bool? = nil
    ) -> PrivacySettingsViewModel {
        PrivacySettingsViewModel(
            readReceiptsEnabled: readReceipts ?? viewModel.readReceiptsEnabled,
            typingIndicatorEnabled: typing ?? viewModel.typingIndicatorEnabled,
            presenceVisibleToContacts: presence ?? viewModel.presenceVisibleToContacts,
            disappearingMessagesDuration: viewModel.disappearingMessagesDuration,
            blockedUserIds: viewModel.blockedUserIds,
            torEnabled: viewModel.torEnabled
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

    // MARK: - W441 device security — bound through PrivacyGate directly
    //
    // 2026-08-06 fix: these three used to be @AppStorage, writing plain
    // UserDefaults keys. PrivacyGate's readers (SECURITY M-28) are
    // Keychain-first with a ONE-TIME UserDefaults→Keychain migration that
    // DELETES the UserDefaults key once it runs — and AppLockService calls
    // those readers on nearly every foreground event, so the migration
    // fires almost immediately after the first toggle. Every subsequent
    // edit here (including trying to turn it back OFF) wrote to a
    // UserDefaults key the readers never looked at again, so the real
    // app-lock/screenshot-protection state silently stopped tracking the
    // switch — and the switch's own displayed position went stale too,
    // since @AppStorage reset to its declared default once its backing key
    // was deleted. Binding straight through PrivacyGate's get/set removes
    // the second, shadow storage location entirely.
    private var screenshotProtectionEnabled: Binding<Bool> {
        Binding(
            get: { PrivacyGate.screenshotProtectionEnabled },
            set: { PrivacyGate.setScreenshotProtectionEnabled($0) }
        )
    }

    private var appLockEnabled: Binding<Bool> {
        Binding(
            get: { PrivacyGate.appLockEnabled },
            set: { PrivacyGate.setAppLockEnabled($0) }
        )
    }

    // MARK: - C7 operational-diagnostics consent (audit 2026-08-19)
    //
    // Parity with Android `operationalDiagnosticsEnabled` / Desktop
    // `SealedTelemetryService.enabled`: opt-in, default OFF. Setter has
    // side effects — it arms/tears down the live flush timer immediately,
    // not just a stored preference.
    //
    // W-DIAGTOGGLE-DEAD (2026-08-20) — was a plain `Binding(get:set:)`
    // over `TelemetryService.isEnabled`/`setEnabled`, no `@State`/
    // `@Published` backing it. Reported live: the switch does not move at
    // all on tap. `SettingsToggleRow`'s own `@Binding var isOn` mutation
    // (`isOn.toggle()`, fired from the row's `.onTapGesture` — the native
    // `Toggle` has `.allowsHitTesting(false)` and never receives the touch
    // itself) invalidates that row, but nothing here ever confirmed a
    // closure-only `Binding` with no SwiftUI-tracked storage underneath
    // reliably re-renders through that path, and `TelemetryService
    // .setEnabled` posts no notification either — unlike
    // `screenshotProtectionEnabled`'s `.screenshotProtectionDidChange`,
    // there is nothing else that could rescue a re-render if the direct
    // path silently doesn't fire one. A real `@State` var is the one
    // SwiftUI primitive guaranteed to invalidate on write regardless of
    // that uncertainty — `TelemetryService.setEnabled` still runs as the
    // side effect, this only fixes what drives the switch's own position.
    @State private var operationalDiagnosticsToggleState: Bool = TelemetryService.isEnabled

    private var operationalDiagnosticsEnabled: Binding<Bool> {
        Binding(
            get: { operationalDiagnosticsToggleState },
            set: { newValue in
                operationalDiagnosticsToggleState = newValue
                TelemetryService.setEnabled(newValue)
            }
        )
    }

    // MARK: - MASVS-PRIVACY remediation (2026-08-20) — LiveLogStreamer consent
    //
    // DISTINCT from `operationalDiagnosticsEnabled` above: that one gates the
    // encrypted call-pipeline metrics stream (X25519+AES-GCM). This one gates
    // `LiveLogStreamer` — raw-ish application log lines (redacted, but a
    // continuous stream, not a single encrypted event) shipped every ~3s
    // while the app runs. Before this fix `LiveLogStreamer.setEnabled` had
    // zero reachable UI call sites anywhere in the app and the flag defaulted
    // on for TestFlight — see `docs/security/MASVS_ASSESSMENT_2026-08-20.md`
    // §1.1. Uses the same real-`@State`-backing pattern as
    // `operationalDiagnosticsEnabled` (W-DIAGTOGGLE-DEAD, 2026-08-20) so the
    // switch actually re-renders on tap.
    @State private var liveLogStreamerToggleState: Bool = LiveLogStreamer.isEnabled

    private var liveLogStreamerEnabled: Binding<Bool> {
        Binding(
            get: { liveLogStreamerToggleState },
            set: { newValue in
                liveLogStreamerToggleState = newValue
                LiveLogStreamer.setEnabled(newValue)
            }
        )
    }

    private var appLockTimeoutMs: Binding<Int> {
        Binding(
            get: { PrivacyGate.appLockTimeoutMs },
            set: { PrivacyGate.setAppLockTimeoutMs($0) }
        )
    }

    private let appLockTimeoutOptions: [(label: String, ms: Int)] = [
        ("1 minuto",   60_000),
        ("2 minuti",  120_000),
        ("5 minuti",  300_000),
        ("10 minuti", 600_000),
        ("30 minuti", 1_800_000)
    ]

    // MARK: - IOS-SE biometric key protection (audit 2026-06-12)
    // Opt-in, default OFF. Enabling re-protects the SOVEREIGN PSK vault items
    // with a `.userPresence` access control (biometry/passcode, survives
    // re-enrollment). Migration is non-destructive — see SovereignKeyVault.
    @State private var keyProtectionEnabled: Bool = KeychainProtectionPolicy.shared.isEnabled
    @State private var keyProtectionBusy: Bool = false
    @State private var keyProtectionError: String?

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

                    // 2026-08-10: the "MESSAGGI A SCADENZA" picker and the
                    // "ANONIMIZZAZIONE RETE" Tor toggle were removed here —
                    // both wrote a preference no production path ever read.
                    // Rationale and the surviving real mechanisms are
                    // documented in PrivacySettingsContainer.init above.

                    // W441: Screenshot protection + App lock
                    SettingsSectionHeader("SICUREZZA DISPOSITIVO")
                    VStack(spacing: 8) {
                        SettingsToggleRow(
                            title: "Protezione screenshot",
                            subtitle: "Oscura il contenuto nell'anteprima app e avvisa se viene fatto uno screenshot",
                            isOn: screenshotProtectionEnabled
                        )
                        SettingsToggleRow(
                            title: "Blocco app",
                            subtitle: "Richiede Face ID / Touch ID / codice quando l'app torna in primo piano",
                            isOn: appLockEnabled
                        )
                        if appLockEnabled.wrappedValue {
                            appLockTimeoutRow
                        }
                    }

                    // C7: encrypted operational-diagnostics opt-in (audit
                    // 2026-08-19). Default OFF — parity with Android/Desktop.
                    SettingsSectionHeader("DIAGNOSTICA")
                    VStack(spacing: 8) {
                        SettingsToggleRow(
                            title: "Diagnostica operativa cifrata",
                            subtitle: "Invia metriche della pipeline di chiamata (audio, rete, self-test) cifrate con X25519+AES-GCM, decifrabili solo lato server. ID sessione temporaneo, non raccoglie messaggi né contatti. Disattivato di default.",
                            isOn: operationalDiagnosticsEnabled
                        )
                        // MASVS-PRIVACY remediation (2026-08-20) — real
                        // toggle for LiveLogStreamer, previously unreachable
                        // from any UI and on by default for TestFlight.
                        SettingsToggleRow(
                            title: "Log diagnostici in tempo reale",
                            subtitle: "Invia log applicativi redatti (tag, dimensioni, fingerprint troncati — mai chiavi, token o contenuto messaggi) al backend di diagnostica ogni pochi secondi mentre l'app è in uso. Canale separato dal precedente. Disattivato di default.",
                            isOn: liveLogStreamerEnabled
                        )
                    }

                    // IOS-SE: hardware-gated custody of session keys. Default OFF
                    // (opt-in). Disabled if the device has no Face ID/Touch ID/
                    // passcode configured.
                    SettingsSectionHeader("CHIAVI SICURE")
                    VStack(spacing: 8) {
                        SettingsToggleRow(
                            title: "Protezione biometrica chiavi",
                            subtitle: "Richiede Face ID / Touch ID (o codice) per le chiavi di sessione, una volta per sessione",
                            isOn: Binding(
                                get: { keyProtectionEnabled },
                                set: { setKeyProtection($0) }
                            )
                        )
                        .disabled(keyProtectionBusy || !KeychainProtectionPolicy.shared.isAuthenticationAvailable)
                        if !KeychainProtectionPolicy.shared.isAuthenticationAvailable {
                            Text("Nessuna autenticazione dispositivo configurata (Face ID / Touch ID / codice).")
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
        .alert("Protezione chiavi", isPresented: Binding(
            get: { keyProtectionError != nil },
            set: { if !$0 { keyProtectionError = nil } }
        )) {
            Button("OK", role: .cancel) { keyProtectionError = nil }
        } message: {
            Text(keyProtectionError ?? "")
        }
    }

    /// IOS-SE: enable/disable biometric key protection. Re-protects (or
    /// un-protects) the existing PSK items via a NON-DESTRUCTIVE migration and
    /// reverts the toggle on any failure — keys are never lost. Default OFF.
    private func setKeyProtection(_ enable: Bool) {
        guard !keyProtectionBusy else { return }
        keyProtectionBusy = true
        keyProtectionEnabled = enable // optimistic; reverted on error
        Task { @MainActor in
            let policy = KeychainProtectionPolicy.shared
            let vault = SovereignKeyVault()
            do {
                if enable {
                    // Existing items are currently unprotected → readable freely.
                    try vault.migratePskProtection(enable: true)
                    policy.setEnabledFlag(true)
                } else {
                    // Items are protected → authenticate once to read them.
                    let ok = await policy.prepareSession(
                        reason: "Conferma per disattivare la protezione biometrica delle chiavi")
                    if !ok {
                        // Auth cancelled/failed: leave protection ON, keys intact.
                        keyProtectionEnabled = policy.isEnabled
                        keyProtectionError = "Autenticazione annullata. La protezione resta attiva."
                        keyProtectionBusy = false
                        return
                    }
                    try vault.migratePskProtection(enable: false, context: policy.authenticationContext())
                    policy.setEnabledFlag(false)
                    policy.invalidateSession()
                }
            } catch {
                // Keys are intact (migration is non-destructive). Revert the UI.
                keyProtectionEnabled = policy.isEnabled
                keyProtectionError = "Operazione non riuscita: \(error). Le chiavi non sono state modificate."
            }
            keyProtectionBusy = false
        }
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

    // MARK: - App lock timeout picker

    private var appLockTimeoutRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "clock")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(scheme.onSurfaceVariant)
                .frame(width: 22)

            Text("Blocca dopo")
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)

            Spacer(minLength: 6)

            Picker("Blocca dopo", selection: appLockTimeoutMs) {
                ForEach(appLockTimeoutOptions, id: \.ms) { option in
                    Text(option.label).tag(option.ms)
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

import SwiftUI
import QAudionEngine

/// New design-token-aware Settings root. 1:1 visual port of Android
/// `qaudion-android-new/feature/feature-settings/.../SettingsScreen.kt`.
///
/// Cross-platform parity is the contract:
///   - Same component vocabulary (ProfileHeroCard, SecurityChipsRow,
///     SettingsRow, SettingsSectionHeader)
///   - Same color tokens (scheme.X, extras.Y) — byte-for-byte hex with
///     Android core-ui
///   - Same Italian copy strings (canonical user-facing text from spec)
///   - Same section ordering and dp/pt values
///
/// Layout (top → bottom):
///   1. Top bar — "Impostazioni" title + ⋯ menu (placeholder)
///   2. ProfileHeroCard — avatar + display name + handle + status + EDIT
///   3. SecurityChipsRow — PSK / PQC / VOICE / OTA badges
///   4. ACCOUNT — Profilo / Numero di telefono / Dispositivi / Esci
///   5. SICUREZZA — Security / Voice-as-Key / Gestione chiavi /
///                  Trasporto / Scambio NFC
///   6. PRIVACY — Privacy / Chat / Notifiche / Chiamate
///   7. DATI — Backup
///   8. INFO — Info app
///   9. SVILUPPATORE — Call Design Showcase (TestFlight QA entry)
///
/// Existing iOS sub-screens (AccountSettingsScreen, PrivacySettingsScreen,
/// CallsSettingsScreen, ChatSettingsScreen, NotificationsSettingsScreen,
/// BackupSettingsScreen, KeyManagementScreen, TransportSettingsScreen,
/// AboutSettingsScreen, SecurityDashboardScreen, DeviceManagementScreen)
/// remain untouched — they're reachable via NavigationLink destinations
/// from this root. Internal toggles (Deepfake Guard, Read Receipts, etc.)
/// stay inside their respective sub-screens; lifting them to root is
/// deferred until the engine surfaces a unified `SettingsUiState`.
struct SettingsScreen: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type
    @Environment(\.qaudionSnackbar) private var snackbar
    /// W102: cache-clear feedback alert state.
    @State private var cacheClearedAlertVisible: Bool = false
    @State private var cacheClearedMessage: String = ""
    /// W151: confirm dialog gate for sign-out. Logging out wipes the
    /// auth token + flips ContentView routing back to OnboardingRoot;
    /// trivial to do by accident from the bottom of Settings.
    @State private var showSignOutConfirm: Bool = false
    /// W165: confirm dialog gate for "Svuota cache allegati". Cache
    /// wipe forces re-download of voice notes + images from peers,
    /// which costs bandwidth on cellular — worth a confirmation tap.
    @State private var showClearCacheConfirm: Bool = false
    /// W113: bump on every clear to force the SettingsRow subtitle
    /// to recompute (computed property reads filesystem; cheap but
    /// only worth doing when the row re-renders).
    @State private var cacheUsageRefreshTrigger: Int = 0

    /// W118+W134: footer with version + build + uptime tagline.
    /// Format: "v1.0.200 (build 105) · sessione 3h 12m"
    /// Uptime is computed from a process-launch timestamp captured
    /// when SettingsScreen first appears (StaticUptimeAnchor).
    private var versionFooter: some View {
        let info = Bundle.main.infoDictionary
        let v = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let b = (info?["CFBundleVersion"] as? String) ?? "?"
        let uptime = ProcessInfo.processInfo.systemUptime
            - StaticUptimeAnchor.processStartedAt
        let uptimeStr: String = {
            let total = max(0, Int(uptime))
            if total < 60 { return "\(total)s" }
            if total < 3600 { return "\(total / 60)m \(total % 60)s" }
            return "\(total / 3600)h \((total % 3600) / 60)m"
        }()
        // W156: copy-friendly bundle string. Tapping the version row
        // pops a confirmation snackbar after writing it to the
        // pasteboard — handy for bug reports against a specific build.
        let bundleSummary = "Q-Audion v\(v) (build \(b))"
        return VStack(spacing: 4) {
            Text("Q-Audion")
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
            Text("v\(v) (build \(b))")
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .monospacedDigit()
            Text("Sessione attiva da \(uptimeStr)")
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            #if canImport(UIKit)
            UIPasteboard.general.string = bundleSummary
            snackbar?.show(.init(
                text: "Versione copiata: \(bundleSummary)",
                severity: .info,
                durationSeconds: 3
            ))
            #endif
        }
        .overlay(alignment: .bottom) {
            // W172: tiny copyright line — appears under the version
            // info as a footnote. No tap action.
            Text("© 2026 Q-Audion · ML-KEM-1024 PQC")
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant.opacity(0.6))
                .offset(y: 24)
        }
        .padding(.bottom, 24)
    }

    private var cacheUsageSubtitle: String {
        let s = AttachmentCacheCleaner.cacheSizes()
        let totalMb = Double(s.voiceNotes &+ s.images) / (1024.0 * 1024.0)
        if totalMb < 0.1 {
            return "Vuota — nessun allegato in cache"
        }
        let c = AttachmentCacheCleaner.cacheCounts()
        let voiceMb = Double(s.voiceNotes) / (1024.0 * 1024.0)
        let imgMb = Double(s.images) / (1024.0 * 1024.0)
        // W128: include item counts so the user knows whether the disk
        // usage comes from many small notes vs. a few big images.
        return String(format: "%d voice (%.1f MB) · %d immagini (%.1f MB)",
                      c.voiceNotes, voiceMb, c.images, imgMb)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                scheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        topBar
                        ProfileHeroCard(
                            displayName: profileDisplayName,
                            handle: profileHandle,
                            statusMessage: "Disponibile per chiamate sicure.",
                            avatarUrl: nil,
                            onEditTap: { /* navigation handled via row below */ }
                        )
                        .padding(.horizontal, 16)
                        .padding(.top, 4)

                        SecurityChipsRow()
                            .padding(.top, 8)

                        accountSection
                        sicurezzaSection
                        privacySection
                        datiSection
                        infoSection
                        sviluppatoreSection

                        Spacer().frame(height: 24)
                        signOutButton
                            .padding(.horizontal, 16)
                            // W151: confirmation dialog before
                            // wiping the session. Anchored to the
                            // sign-out button so the dialog inherits
                            // its presentation context.
                            .confirmationDialog(
                                "Uscire da Q-Audion?",
                                isPresented: $showSignOutConfirm,
                                titleVisibility: .visible
                            ) {
                                Button("Esci", role: .destructive) {
                                    snackbar?.show(.init(
                                        text: "Sessione chiusa.",
                                        severity: .info,
                                        durationSeconds: 3))
                                    appState.logout()
                                }
                                Button("Annulla", role: .cancel) { }
                            } message: {
                                Text("Dovrai accedere di nuovo per usare le chat e le chiamate. I messaggi salvati su questo dispositivo non vengono cancellati.")
                            }

                        // W118: app version + build number footer.
                        // Helps testers report bugs against a specific
                        // build without digging into TestFlight UI.
                        // Reads from the running bundle so it's always
                        // accurate regardless of XcodeGen's plist
                        // injection state.
                        versionFooter
                            .padding(.top, 16)
                            .padding(.bottom, 32)
                    }
                }
            }
            .navigationBarHidden(true)
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Text("Impostazioni")
                .qaudionStyle(type.titleLarge)
                .foregroundStyle(scheme.onSurface)
            Spacer()
            Button(action: { /* TODO: header menu */ }) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(scheme.onSurface)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Altro")
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    // MARK: - Sections

    private var accountSection: some View {
        VStack(spacing: 8) {
            SettingsSectionHeader("ACCOUNT")
            NavigationLink {
                AccountSettingsScreen(appState: appState)
            } label: {
                SettingsRow(icon: "person",
                            iconColor: scheme.primary,
                            title: "Profilo",
                            subtitle: profileDisplayName)
            }
            .buttonStyle(.plain)

            NavigationLink {
                DeviceManagementScreen(state: appState)
            } label: {
                SettingsRow(icon: "iphone",
                            iconColor: scheme.primary,
                            title: "Dispositivi collegati",
                            subtitle: "Gestisci i dispositivi attivi")
            }
            .buttonStyle(.plain)

            // W44: I miei numeri (multi-phone management) — 1:1 port del
            // blocco "I MIEI NUMERI" di Android `ProfileScreen.kt`. Permette
            // di registrare multipli E.164 sull'account così i peer ti
            // raggiungono via uno qualsiasi (engine wiring per
            // POST /contacts/phones pending).
            NavigationLink {
                MyPhonesScreen()
            } label: {
                SettingsRow(icon: "phone.badge.plus",
                            iconColor: scheme.primary,
                            title: "I miei numeri",
                            subtitle: "Interno · numeri di telefono")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }

    private var sicurezzaSection: some View {
        VStack(spacing: 8) {
            SettingsSectionHeader("SICUREZZA")
            NavigationLink {
                SecurityDashboardScreen(state: appState)
            } label: {
                SettingsRow(icon: "shield.lefthalf.filled",
                            iconColor: scheme.primary,
                            title: "Security Dashboard",
                            subtitle: "Confidence · trust · eventi")
            }
            .buttonStyle(.plain)

            NavigationLink {
                KeyManagementScreen(state: appState)
            } label: {
                SettingsRow(icon: "key.fill",
                            iconColor: extras.pqcAccent,
                            title: "Gestione chiavi",
                            subtitle: "PSK · PQC · rotazione")
            }
            .buttonStyle(.plain)

            NavigationLink {
                VoiceEnrollmentScreen()
            } label: {
                SettingsRow(icon: "waveform.badge.mic",
                            iconColor: extras.pqcAccent,
                            title: "Voice-as-Key",
                            subtitle: "Registra voiceprint · 5 campioni")
            }
            .buttonStyle(.plain)

            NavigationLink {
                TransportSettingsScreen(state: appState)
            } label: {
                SettingsRow(icon: "arrow.left.arrow.right",
                            iconColor: scheme.primary,
                            title: "Protocollo di trasporto",
                            subtitle: "P2P · TURN · Relay")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }

    private var privacySection: some View {
        VStack(spacing: 8) {
            SettingsSectionHeader("PRIVACY E COMUNICAZIONI")
            NavigationLink {
                PrivacySettingsScreen(state: appState)
            } label: {
                SettingsRow(icon: "hand.raised.fill",
                            iconColor: scheme.primary,
                            title: "Controlli privacy",
                            subtitle: "Conferme · ultimo accesso · scopribilità")
            }
            .buttonStyle(.plain)

            NavigationLink {
                CallsSettingsScreen(state: appState)
            } label: {
                SettingsRow(icon: "phone.fill",
                            iconColor: scheme.primary,
                            title: "Chiamate",
                            subtitle: "Codec · qualità · echo cancellation")
            }
            .buttonStyle(.plain)

            NavigationLink {
                ChatSettingsScreen(state: appState)
            } label: {
                SettingsRow(icon: "bubble.right",
                            iconColor: scheme.primary,
                            title: "Chat",
                            subtitle: "Cifratura · scadenza messaggi")
            }
            .buttonStyle(.plain)

            NavigationLink {
                NotificationsSettingsScreen(state: appState)
            } label: {
                SettingsRow(icon: "bell.fill",
                            iconColor: scheme.primary,
                            title: "Notifiche",
                            subtitle: "VoIP push · banner · suoni")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }

    private var datiSection: some View {
        VStack(spacing: 8) {
            SettingsSectionHeader("DATI")
            NavigationLink {
                BackupSettingsScreen(state: appState)
            } label: {
                SettingsRow(icon: "externaldrive.fill",
                            iconColor: scheme.primary,
                            title: "Backup cifrato",
                            subtitle: "SCRYPT(N=2¹⁷) · AES-256-GCM")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }

    private var infoSection: some View {
        VStack(spacing: 8) {
            SettingsSectionHeader("INFO")
            NavigationLink {
                AboutSettingsScreen(state: appState)
            } label: {
                SettingsRow(icon: "info.circle",
                            iconColor: scheme.primary,
                            title: "Informazioni",
                            subtitle: "Versione · protocollo · OSS")
            }
            .buttonStyle(.plain)

            // W42: Aggiornamento firmato OTA. Stub UI con mock catalog —
            // l'engine wirerà il vero fetch + Ed25519 verify quando lands.
            // 1:1 visual port di Android `OtaUpdateScreen.kt`.
            NavigationLink {
                OtaUpdateScreen()
            } label: {
                SettingsRow(icon: "arrow.triangle.2.circlepath.icloud",
                            iconColor: extras.pqcAccent,
                            title: "Aggiornamento OTA",
                            subtitle: "Catalogo firmato · Ed25519 · canali")
            }
            .buttonStyle(.plain)

            // W49: Cosa c'è di nuovo — changelog viewer per i tester.
            // Lista hardcoded delle release con bullet di feature, così
            // un tester sa cosa testare in ogni nuova versione.
            NavigationLink {
                WhatsNewScreen()
            } label: {
                SettingsRow(icon: "sparkles",
                            iconColor: scheme.primary,
                            title: "Cosa c'è di nuovo",
                            subtitle: "Changelog · novità per release")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }

    private var sviluppatoreSection: some View {
        VStack(spacing: 8) {
            SettingsSectionHeader("SVILUPPATORE")
            NavigationLink {
                CallDesignShowcase()
            } label: {
                SettingsRow(icon: "paintbrush.fill",
                            iconColor: .orange,
                            title: "Call Design Showcase",
                            subtitle: "Anteprima Incoming · Outgoing · InCall · Group")
            }
            .buttonStyle(.plain)

            // W43: dev-only network simulator. UI-only stub today; will
            // wire to engine `NetworkConditionSimulator` when surfaced
            // on iOS. 1:1 port of Android `NetworkSimulatorScreen.kt`.
            NavigationLink {
                NetworkSimulatorScreen()
            } label: {
                SettingsRow(icon: "antenna.radiowaves.left.and.right",
                            iconColor: .orange,
                            title: "Simulatore rete (dev)",
                            subtitle: "Latenza · perdita · offline · presets")
            }
            .buttonStyle(.plain)

            // W46: Reset dati locali (UserDefaults wipe non-credenziale).
            // Utile per QA TestFlight per ripartire pulito senza
            // reinstallare l'app o forzare logout.
            NavigationLink {
                DevResetScreen()
            } label: {
                SettingsRow(icon: "trash.slash.fill",
                            iconColor: .orange,
                            title: "Reset dati locali",
                            subtitle: "UserDefaults wipe · auth preservata")
            }
            .buttonStyle(.plain)

            // W48: Esporta diagnostica — text dump shareable per
            // bug-report. Sister di W46 DevReset; insieme formano la
            // QA toolkit. Nessun token / private-key nel report.
            NavigationLink {
                DiagnosticsExportScreen()
            } label: {
                SettingsRow(icon: "doc.text.magnifyingglass",
                            iconColor: .orange,
                            title: "Esporta diagnostica",
                            subtitle: "Build · device · stato · share")
            }
            .buttonStyle(.plain)

            // W102: clear voice-note + image attachment cache. Wipes
            // Library/Caches/voicenotes and Library/Caches/images so
            // disk usage drops without losing the chat history (the
            // qfile markers stay; cache is re-fetched on next tap).
            // W165: gated behind a confirm dialog because re-fetching
            // hits cellular bandwidth.
            Button {
                showClearCacheConfirm = true
            } label: {
                SettingsRow(icon: "tray.2.fill",
                            iconColor: .orange,
                            title: "Svuota cache allegati",
                            subtitle: cacheUsageSubtitle)
            }
            .buttonStyle(.plain)
            .id(cacheUsageRefreshTrigger)
            // W165: confirmationDialog anchored to the cache row.
            .confirmationDialog(
                "Svuotare la cache degli allegati?",
                isPresented: $showClearCacheConfirm,
                titleVisibility: .visible
            ) {
                Button("Svuota", role: .destructive) {
                    let bytesFreed = AttachmentCacheCleaner.clearAllCaches()
                    let mb = Double(bytesFreed) / (1024.0 * 1024.0)
                    cacheClearedMessage = String(format: "Cache liberata: %.1f MB", mb)
                    cacheClearedAlertVisible = true
                    cacheUsageRefreshTrigger += 1
                }
                Button("Annulla", role: .cancel) { }
            } message: {
                Text("Le foto e i vocali ricevuti verranno ri-scaricati dai mittenti la prossima volta che li apri. La cronologia dei messaggi non viene toccata.")
            }

            // W150: bulk-clear all per-conversation composer drafts.
            // Useful when handing the device to someone else without a
            // full account reset — drafts can leak in-progress thoughts.
            Button {
                let cleared = Self.clearAllDrafts()
                cacheClearedMessage = cleared > 0
                    ? "Eliminati \(cleared) abbozzi."
                    : "Nessun abbozzo da eliminare."
                cacheClearedAlertVisible = true
                cacheUsageRefreshTrigger += 1
            } label: {
                // W154: dynamic subtitle shows the live count.
                SettingsRow(icon: "doc.text.below.ecg",
                            iconColor: .orange,
                            title: "Cancella abbozzi",
                            subtitle: Self.draftsSubtitle())
            }
            .buttonStyle(.plain)
            .id(cacheUsageRefreshTrigger)

            // W163: combined reset of all small per-device metadata
            // accumulated by W137 / W142 / W158 / W162 (drafts,
            // last-seen, first-seen, build-seen). One-click privacy
            // reset for testers handing off a device.
            Button {
                let n = Self.resetAllLocalMetadata()
                cacheClearedMessage = n > 0
                    ? "Eliminate \(n) chiavi di metadati locali."
                    : "Nessun metadato da eliminare."
                cacheClearedAlertVisible = true
                cacheUsageRefreshTrigger += 1
            } label: {
                SettingsRow(icon: "wand.and.stars",
                            iconColor: .orange,
                            title: "Reset metadati locali",
                            subtitle: "Abbozzi · ultimo accesso · primo lancio · build seen")
            }
            .buttonStyle(.plain)

            // W166: clear the home-screen badge counter without
            // dismissing actual delivered notifications. Useful for
            // testers who got the badge stuck during a CI session.
            Button {
                NotificationCenterService.shared.clearBadge()
                cacheClearedMessage = "Badge notifiche azzerato."
                cacheClearedAlertVisible = true
            } label: {
                SettingsRow(icon: "app.badge",
                            iconColor: .orange,
                            title: "Pulisci badge notifiche",
                            subtitle: "Azzera il numero rosso sull'icona dell'app")
            }
            .buttonStyle(.plain)

            // W153: wipe all "ultimo accesso" stamps captured by
            // PresenceService. The next time the chat detail topbar
            // renders for a peer, it falls back to the static crypto
            // label until the peer is observed online again.
            Button {
                let cleared = Self.clearAllLastSeen()
                cacheClearedMessage = cleared > 0
                    ? "Eliminati \(cleared) timestamp di ultimo accesso."
                    : "Nessun timestamp da eliminare."
                cacheClearedAlertVisible = true
                cacheUsageRefreshTrigger += 1
            } label: {
                // W154: dynamic subtitle shows the live count.
                SettingsRow(icon: "eye.slash.fill",
                            iconColor: .orange,
                            title: "Cancella timestamp ultimo accesso",
                            subtitle: Self.lastSeenSubtitle())
            }
            .buttonStyle(.plain)
            .id(cacheUsageRefreshTrigger)

            // W268: PQC self-test. Synchronously runs ML-KEM-1024
            // keygen + encap + decap and verifies the shared secret
            // round-trips. If liboqs returns OQS_SUCCESS and the
            // shared secrets match byte-for-byte, the row reports OK
            // with elapsed milliseconds. Useful as a tester sanity
            // check that the PQC stack is alive without making a real
            // call.
            Button {
                runPqcSelfTest()
            } label: {
                SettingsRow(icon: "lock.shield.fill",
                            iconColor: .orange,
                            title: "Self-test crittografia",
                            subtitle: "Round-trip ML-KEM-1024 (encap+decap)")
            }
            .buttonStyle(.plain)
        }
        // W268: alert title made neutral ("Sviluppatore") because this
        // same dispatch surface now serves the PQC self-test as well as
        // the cache/drafts/lastSeen wipes. The actual title was always
        // a bit of a lie for those flavors anyway.
        .alert("Sviluppatore", isPresented: $cacheClearedAlertVisible) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(cacheClearedMessage)
        }
        .padding(.horizontal, 16)
    }

    /// W150: walk standardUserDefaults dictionary keys and remove any
    /// composer-draft entries (prefix `qa.composer.draft.`). Returns
    /// the number of keys removed so the alert can confirm.
    private static func clearAllDrafts() -> Int {
        let prefix = "qa.composer.draft."
        let store = UserDefaults.standard
        let allKeys = store.dictionaryRepresentation().keys
        var removed = 0
        for k in allKeys where k.hasPrefix(prefix) {
            store.removeObject(forKey: k)
            removed += 1
        }
        return removed
    }

    /// W163: combined reset of all small per-device metadata.
    /// Removes drafts, last-seen, first-seen, build-seen entries.
    /// Returns the number of UserDefaults keys actually removed.
    private static func resetAllLocalMetadata() -> Int {
        let prefixes: [String] = [
            "qa.composer.draft.",
            "qa.lastSeenAt.",
            "qaudion.buildSeen.",
        ]
        let single: [String] = [
            "qaudion.firstSeen",
        ]
        let store = UserDefaults.standard
        let allKeys = store.dictionaryRepresentation().keys
        var removed = 0
        for k in allKeys {
            for p in prefixes where k.hasPrefix(p) {
                store.removeObject(forKey: k)
                removed += 1
                break
            }
        }
        for k in single where store.object(forKey: k) != nil {
            store.removeObject(forKey: k)
            removed += 1
        }
        return removed
    }

    /// W153: wipe all `qa.lastSeenAt.*` keys (LastSeenTracker
    /// stamps). Returns the count for user feedback.
    private static func clearAllLastSeen() -> Int {
        let prefix = "qa.lastSeenAt."
        let store = UserDefaults.standard
        let allKeys = store.dictionaryRepresentation().keys
        var removed = 0
        for k in allKeys where k.hasPrefix(prefix) {
            store.removeObject(forKey: k)
            removed += 1
        }
        return removed
    }

    /// W154: count keys with a given prefix without mutating the
    /// store. Cheap walk of the in-memory defaults dictionary.
    private static func countKeys(prefix: String) -> Int {
        let allKeys = UserDefaults.standard.dictionaryRepresentation().keys
        var n = 0
        for k in allKeys where k.hasPrefix(prefix) { n += 1 }
        return n
    }

    /// W154: dynamic subtitle for the "Cancella abbozzi" row.
    private static func draftsSubtitle() -> String {
        let n = countKeys(prefix: "qa.composer.draft.")
        if n == 0 {
            return "Nessun abbozzo salvato"
        }
        if n == 1 {
            return "1 abbozzo salvato"
        }
        return "\(n) abbozzi salvati"
    }

    /// W154: dynamic subtitle for the "Cancella timestamp" row.
    private static func lastSeenSubtitle() -> String {
        let n = countKeys(prefix: "qa.lastSeenAt.")
        if n == 0 {
            return "Nessun timestamp da dimenticare"
        }
        if n == 1 {
            return "1 contatto memorizzato"
        }
        return "\(n) contatti memorizzati"
    }

    // MARK: - PQC self-test (W268)

    /// W268: synchronous round-trip of the ML-KEM-1024 stack. Generates
    /// a fresh keypair, encapsulates against the public key, decapsulates
    /// with the private key, and verifies the shared secrets match. If
    /// any step throws or the bytes don't compare equal, surfaces a red
    /// alert. On success, shows elapsed time + shared-secret length.
    ///
    /// Extracted to a method (not inline closure) per CLAUDE.md §13.
    /// Method body has only flat statements + local lets — no nested
    /// closures, no @Sendable Tasks. Uses cacheClearedAlertVisible as
    /// the dispatch surface to avoid plumbing a separate alert state.
    private func runPqcSelfTest() {
        let pqc = PqcKeyExchange()
        let t0: TimeInterval = ProcessInfo.processInfo.systemUptime
        let kp = pqc.generateKeyPair()
        do {
            let enc = try pqc.encapsulate(remotePublicKey: kp.publicKey)
            let dec = try pqc.decapsulate(ciphertext: enc.ciphertext,
                                          privateKey: kp.privateKey)
            let elapsedMs: Int = Int(
                (ProcessInfo.processInfo.systemUptime - t0) * 1000.0
            )
            if dec == enc.sharedSecret {
                let bytesLabel: String = String(enc.sharedSecret.count)
                let msLabel: String = String(elapsedMs)
                cacheClearedMessage = "PQC OK: " + bytesLabel
                    + " bytes shared secret · " + msLabel + " ms"
            } else {
                cacheClearedMessage = "PQC FAIL: shared secret mismatch"
            }
        } catch {
            cacheClearedMessage = "PQC FAIL: " + String(describing: error)
        }
        cacheClearedAlertVisible = true
    }

    // MARK: - Sign-out destructive button

    private var signOutButton: some View {
        Button {
            // W151: gate behind a confirmation dialog. The actual
            // logout (token wipe + routing flip) runs from the
            // dialog's destructive button below.
            showSignOutConfirm = true
        } label: {
            HStack {
                // SF Symbol that semantically reads as "log out" rather
                // than "hide". OpenRouter review on v1.0.65 flagged
                // `eye.slash.fill` as misleading for sign-out.
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 16, weight: .regular))
                Text("Esci")
                    .qaudionStyle(type.bodyMedium)
            }
            .foregroundStyle(extras.riskHigh)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(extras.riskHigh.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(extras.riskHigh.opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var profileDisplayName: String {
        // Pull display name from AppState if available, else show userId
        // prefix or a friendly fallback. The legacy AppState exposes
        // `currentUserId`; richer profile data lives in
        // AccountSettingsContainer (lazy-loaded). The hero card pulls
        // that fuller profile internally when navigated to.
        if let userId = appState.currentUserId, !userId.isEmpty {
            return userId.hasPrefix("user-")
                ? String(userId.dropFirst(5)).capitalized
                : userId
        }
        return "Q-Audion User"
    }

    private var profileHandle: String? {
        guard let userId = appState.currentUserId else { return nil }
        // Show first 8 + ellipsis + last 4 of the user-id (typically a
        // sha256 hex of the phone number) so peers can fingerprint-match.
        if userId.count > 12 {
            return "Int. — · \(userId.prefix(8))…\(userId.suffix(4))"
        }
        return "Int. — · \(userId)"
    }
}

#Preview {
    SettingsScreen()
        .environmentObject(AppState())
        .qAudionTheme(dark: true)
}

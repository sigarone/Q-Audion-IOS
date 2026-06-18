import SwiftUI
import QAudionEngine

@MainActor
final class NotificationsSettingsContainer: ObservableObject {
    @Published var viewModel: NotificationsSettingsViewModel
    private let store: SettingsStore

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
        // W405: hydrate from NotificationsGate so the visible state
        // matches the value the banner / scheduleLocal will read.
        let legacy = store.loadNotifications()
        let qhEnabled = NotificationsGate.quietHoursEnabled
        let qhStartH = NotificationsGate.quietStartMinutes / 60
        let qhStartM = NotificationsGate.quietStartMinutes % 60
        let qhEndH   = NotificationsGate.quietEndMinutes / 60
        let qhEndM   = NotificationsGate.quietEndMinutes % 60
        self.viewModel = NotificationsSettingsViewModel(
            ringtoneId: legacy.ringtoneId,
            inAppSoundEnabled: NotificationsGate.inAppSoundEnabled,
            vibrationEnabled: NotificationsGate.vibrationEnabled,
            quietHours: NotificationsSettingsViewModel.QuietHours(
                startHour: qhStartH, startMinute: qhStartM,
                endHour: qhEndH, endMinute: qhEndM, enabled: qhEnabled),
            mutedContactsCount: legacy.mutedContactsCount
        )
    }

    func setRingtone(_ id: String) {
        viewModel = makeUpdated(ringtoneId: id)
        store.saveNotifications(viewModel)
    }

    func toggleInAppSound(_ enabled: Bool) {
        viewModel = makeUpdated(inAppSound: enabled)
        store.saveNotifications(viewModel)
        NotificationsGate.setInAppSound(enabled)
    }

    func toggleVibration(_ enabled: Bool) {
        viewModel = makeUpdated(vibration: enabled)
        store.saveNotifications(viewModel)
        NotificationsGate.setVibration(enabled)
    }

    func setQuietHours(_ quietHours: NotificationsSettingsViewModel.QuietHours) {
        viewModel = makeUpdated(quietHours: quietHours)
        store.saveNotifications(viewModel)
        // W405: also persist into NotificationsGate so the gate is the
        // single source of truth at banner-render time.
        NotificationsGate.setQuietHoursEnabled(quietHours.enabled)
        NotificationsGate.setQuietStart(minutes: quietHours.startHour * 60 + quietHours.startMinute)
        NotificationsGate.setQuietEnd(minutes: quietHours.endHour * 60 + quietHours.endMinute)
    }

    func toggleQuietHours(_ enabled: Bool) {
        let updated = NotificationsSettingsViewModel.QuietHours(
            startHour: viewModel.quietHours.startHour,
            startMinute: viewModel.quietHours.startMinute,
            endHour: viewModel.quietHours.endHour,
            endMinute: viewModel.quietHours.endMinute,
            enabled: enabled
        )
        setQuietHours(updated)
    }

    private func makeUpdated(
        ringtoneId: String? = nil,
        inAppSound: Bool? = nil,
        vibration: Bool? = nil,
        quietHours: NotificationsSettingsViewModel.QuietHours? = nil
    ) -> NotificationsSettingsViewModel {
        NotificationsSettingsViewModel(
            ringtoneId: ringtoneId ?? viewModel.ringtoneId,
            inAppSoundEnabled: inAppSound ?? viewModel.inAppSoundEnabled,
            vibrationEnabled: vibration ?? viewModel.vibrationEnabled,
            quietHours: quietHours ?? viewModel.quietHours,
            mutedContactsCount: viewModel.mutedContactsCount
        )
    }
}

/// Notifications settings sub-screen. W26 design-token refactor —
/// migrates from stock SwiftUI `Form` to the new design vocabulary
/// (`SettingsSectionHeader` + `SettingsToggleRow` + custom picker
/// row with surfaceVariant background).
struct NotificationsSettingsScreen: View {
    @StateObject private var container: NotificationsSettingsContainer

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    private let availableRingtones = ["qaudion-default", "classic", "pulse", "silent"]

    init(state: AppState) {
        _container = StateObject(wrappedValue: NotificationsSettingsContainer())
    }

    private var quietHoursRange: String {
        let qh = container.viewModel.quietHours
        return String(format: "%02d:%02d – %02d:%02d",
                      qh.startHour, qh.startMinute, qh.endHour, qh.endMinute)
    }

    /// W96: master switch for chat-message banners. Read by
    /// AppState.handleIncomingMessage before scheduling a UN
    /// notification. Persisted in UserDefaults so the preference
    /// sticks across launches; @AppStorage gives us automatic
    /// view re-render when the toggle changes.
    @AppStorage("qaudion.notifications.banners_enabled")
    private var bannersEnabled: Bool = true

    /// W265: pending + delivered notification counts. Populated by
    /// `refreshNotificationCounts()` on .onAppear and after the
    /// scheduleLocal / clearAllDelivered actions so the row stays
    /// honest. UN APIs are async-only, so we hop through Task.
    @State private var pendingCount: Int = 0
    @State private var deliveredCount: Int = 0

    /// W287: authorization status string. Populated alongside the
    /// counts since notificationSettings() is the same-cost call.
    @State private var authStatusLabel: String = "?"

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsSectionHeader("CONNETTIVITA")
                    VStack(spacing: 8) {
                        SettingsToggleRow(
                            title: "Mantieni connessione in background",
                            subtitle: "L'app si riconnette e riceve chiamate anche in background",
                            isOn: Binding(
                                get: { PrivacyGate.autoStartEnabled },
                                set: { PrivacyGate.setAutoStartEnabled($0) }
                            )
                        )
                    }
                    SettingsSectionHeader("BANNER")
                    VStack(spacing: 8) {
                        SettingsToggleRow(
                            title: "Notifiche messaggi",
                            subtitle: "Mostra banner per i messaggi ricevuti",
                            isOn: $bannersEnabled
                        )
                    }
                    SettingsSectionHeader("SUONI")
                    VStack(spacing: 8) {
                        ringtonePickerRow
                        SettingsToggleRow(
                            title: "Suoni in-app",
                            subtitle: "Effetti sonori dentro l'app",
                            isOn: Binding(
                                get: { container.viewModel.inAppSoundEnabled },
                                set: { container.toggleInAppSound($0) }
                            )
                        )
                        SettingsToggleRow(
                            title: "Vibrazione",
                            subtitle: "Vibra alla ricezione di chiamate / messaggi",
                            isOn: Binding(
                                get: { container.viewModel.vibrationEnabled },
                                set: { container.toggleVibration($0) }
                            )
                        )
                    }

                    SettingsSectionHeader("MODALITÀ NON DISTURBARE")
                    VStack(spacing: 8) {
                        SettingsToggleRow(
                            title: "Attiva non disturbare",
                            subtitle: "Silenzia notifiche in fascia oraria",
                            isOn: Binding(
                                get: { container.viewModel.quietHours.enabled },
                                set: { container.toggleQuietHours($0) }
                            )
                        )
                        if container.viewModel.quietHours.enabled {
                            kvRow(label: "Fascia oraria",
                                  value: quietHoursRange,
                                  mono: true)
                            Text("Le chiamate in entrata e i messaggi sono silenziati durante questa fascia.")
                                .qaudionStyle(type.labelSmall)
                                .foregroundStyle(scheme.onSurfaceVariant)
                                .padding(.horizontal, 14)
                        }
                    }

                    if container.viewModel.mutedContactsCount > 0 {
                        SettingsSectionHeader("CONTATTI SILENZIATI")
                        kvRow(label: "Contatti silenziati",
                              value: "\(container.viewModel.mutedContactsCount)",
                              mono: false)
                    }

                    // W265: live notification counts. `pendenti` are
                    // notifications scheduled but not yet delivered
                    // (e.g. after tapping W171 'Invia notifica di test'
                    // before the 1.5s trigger fires). `consegnate` are
                    // already in the iOS notification cassette but not
                    // yet dismissed. Helps QA verify the W171 + W263
                    // toolkit is actually doing what it claims.
                    SettingsSectionHeader("STATO")
                    VStack(spacing: 8) {
                        // W287: UN authorization status — verifies
                        // the user actually granted the prompt + that
                        // settings haven't been revoked from iOS.
                        kvRow(label: "Autorizzazione",
                              value: authStatusLabel,
                              mono: false)
                        kvRow(label: "Pendenti",
                              value: String(pendingCount),
                              mono: true)
                        kvRow(label: "Consegnate",
                              value: String(deliveredCount),
                              mono: true)
                    }

                    // W171: schedule a fake banner so the user can
                    // verify their banner / sound / vibration setup
                    // works end-to-end without needing a real peer
                    // message. Fires after 1.5s — long enough for
                    // the user to lock the screen and see the banner.
                    SettingsSectionHeader("DIAGNOSTICA")
                    // W278: haptic feedback test — fires the canonical
                    // success buzz so the tester can confirm the
                    // 'Vibrazione' toggle (W160) is actually wired and
                    // the device has a Taptic Engine (older iPads
                    // don't). Tap repeatedly to feel each pattern.
                    Button {
                        HapticFeedback.messageSent()
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "iphone.radiowaves.left.and.right")
                                .font(.system(size: 17, weight: .regular))
                                .foregroundStyle(.orange)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Test feedback aptico")
                                    .qaudionStyle(type.bodyMedium)
                                    .foregroundStyle(scheme.onSurface)
                                Text("Verifica vibrazione · richiede Taptic Engine")
                                    .qaudionStyle(type.labelSmall)
                                    .foregroundStyle(scheme.onSurfaceVariant)
                            }
                            Spacer()
                            Image(systemName: "play.fill")
                                .font(.system(size: 12, weight: .regular))
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

                    // W299: haptic pattern showcase. Fires each of the
                    // 6 HapticFeedback patterns in sequence with a
                    // 0.5s gap so the tester can feel them individually.
                    // Useful for confirming each pattern actually maps
                    // to a different Taptic Engine feel — 'message
                    // sent' and 'reaction toggle' should be subtly
                    // different but easy to mix up if mis-wired.
                    Button {
                        playHapticShowcase()
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "waveform.path")
                                .font(.system(size: 17, weight: .regular))
                                .foregroundStyle(.orange)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Showcase aptico (6 pattern)")
                                    .qaudionStyle(type.bodyMedium)
                                    .foregroundStyle(scheme.onSurface)
                                Text("Sent · Start · Stop · Reaction · Destructive · Failure")
                                    .qaudionStyle(type.labelSmall)
                                    .foregroundStyle(scheme.onSurfaceVariant)
                            }
                            Spacer()
                            Image(systemName: "play.fill")
                                .font(.system(size: 12, weight: .regular))
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

                    Button {
                        scheduleTestNotification()
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "bell.badge.fill")
                                .font(.system(size: 17, weight: .regular))
                                .foregroundStyle(.orange)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Invia notifica di test")
                                    .qaudionStyle(type.bodyMedium)
                                    .foregroundStyle(scheme.onSurface)
                                Text("Banner finto fra ~1.5s · blocca lo schermo per vederlo")
                                    .qaudionStyle(type.labelSmall)
                                    .foregroundStyle(scheme.onSurfaceVariant)
                            }
                            Spacer()
                            Image(systemName: "play.fill")
                                .font(.system(size: 12, weight: .regular))
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

                    // W263: clear all delivered notifications from the
                    // notification center. Testers who run W171 multiple
                    // times can accumulate a pile of stale banners that
                    // also keep the home-screen badge red. One tap wipes
                    // them; complementary to W166 (clear badge counter).
                    Button {
                        NotificationCenterService.shared.clearAllDelivered()
                        // W265: refresh the count immediately so the
                        // STATO row reflects the wipe.
                        refreshNotificationCounts()
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "tray.fill")
                                .font(.system(size: 17, weight: .regular))
                                .foregroundStyle(.orange)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Cancella notifiche consegnate")
                                    .qaudionStyle(type.bodyMedium)
                                    .foregroundStyle(scheme.onSurface)
                                Text("Svuota il cassetto notifiche di iOS")
                                    .qaudionStyle(type.labelSmall)
                                    .foregroundStyle(scheme.onSurfaceVariant)
                            }
                            Spacer()
                            Image(systemName: "trash")
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

                    // W270: cancel all pending notification requests.
                    // Sister of W263 which clears delivered ones — this
                    // wipes the queue of scheduled-but-not-yet-fired
                    // notifications. Useful if the QA tester taps W171
                    // 'Invia notifica di test' and changes mind before
                    // the 1.5s trigger fires.
                    Button {
                        UNUserNotificationCenter.current()
                            .removeAllPendingNotificationRequests()
                        refreshNotificationCounts()
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "calendar.badge.minus")
                                .font(.system(size: 17, weight: .regular))
                                .foregroundStyle(.orange)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Cancella notifiche pianificate")
                                    .qaudionStyle(type.bodyMedium)
                                    .foregroundStyle(scheme.onSurface)
                                Text("Annulla la coda dei trigger non ancora scattati")
                                    .qaudionStyle(type.labelSmall)
                                    .foregroundStyle(scheme.onSurfaceVariant)
                            }
                            Spacer()
                            Image(systemName: "xmark.circle")
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

                    // W169: shortcut into iOS Settings → Q-Audion
                    // permissions. Useful when the user has revoked
                    // mic / notifications and wants to fix it without
                    // hunting through Settings.
                    SettingsSectionHeader("SISTEMA")
                    Button {
                        #if canImport(UIKit)
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                        #endif
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 17, weight: .regular))
                                .foregroundStyle(.orange)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Apri Impostazioni iOS")
                                    .qaudionStyle(type.bodyMedium)
                                    .foregroundStyle(scheme.onSurface)
                                Text("Permessi · banner · suoni di sistema")
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
        .navigationTitle("Notifiche")
        // W265: refresh the pending / delivered counts on first paint.
        // No timer / observer — this is a snapshot for QA, not a live
        // dashboard. Re-trigger via the buttons below if the user
        // wants a fresh number after sending a test notification.
        .onAppear {
            refreshNotificationCounts()
        }
    }

    /// W299: fire all 6 HapticFeedback patterns in sequence with a
    /// 0.5s gap so the tester can distinguish them individually.
    /// Sequential async sleep — keeps closure body trivial per
    /// CLAUDE.md §13.
    private func playHapticShowcase() {
        Task {
            HapticFeedback.messageSent()
            try? await Task.sleep(nanoseconds: 500_000_000)
            HapticFeedback.recordingStart()
            try? await Task.sleep(nanoseconds: 500_000_000)
            HapticFeedback.recordingStop()
            try? await Task.sleep(nanoseconds: 500_000_000)
            HapticFeedback.reactionToggle()
            try? await Task.sleep(nanoseconds: 500_000_000)
            HapticFeedback.destructiveAction()
            try? await Task.sleep(nanoseconds: 500_000_000)
            HapticFeedback.sendFailure()
        }
    }

    /// W265: schedule the W171 test banner + refresh counts. Extracted
    /// from the inline closure body (CLAUDE.md §13 — no
    /// closure → Task → method-call patterns at SwiftUI call sites).
    private func scheduleTestNotification() {
        Task {
            await NotificationCenterService.shared.scheduleLocal(
                category: .messageDelivered,
                title: "Q-Audion test",
                body: "Se vedi questo banner, le notifiche funzionano correttamente.",
                delay: 1.5
            )
            // Refresh counts so the user sees pending+1 immediately,
            // then the row will flip after the trigger fires (~1.5s).
            await MainActor.run {
                refreshNotificationCounts()
            }
        }
    }

    /// W265: one-shot snapshot of UN center pending + delivered counts.
    /// Both APIs are async-only on iOS 16+ so we hop through Task and
    /// land back on the main actor for the @State writes. Kept as an
    /// instance method (not closure) per CLAUDE.md §13 — Task body is
    /// trivial (two awaits + two State writes), no nested closures.
    private func refreshNotificationCounts() {
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests()
            let delivered = await center.deliveredNotifications()
            // W287: also fetch authorization status — same call cost,
            // surfaces in the STATO row so testers see at a glance
            // whether the iOS prompt was accepted.
            let settings = await center.notificationSettings()
            self.pendingCount = pending.count
            self.deliveredCount = delivered.count
            self.authStatusLabel = Self.formatAuthStatus(settings.authorizationStatus)
        }
    }

    /// W287: friendly label for UN authorization status. Static so the
    /// type-checker has clean scope (CLAUDE.md §13).
    private static func formatAuthStatus(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized:        return "Autorizzato"
        case .denied:            return "Negato"
        case .notDetermined:     return "Non richiesto"
        case .provisional:       return "Provvisorio"
        case .ephemeral:         return "Effimero"
        @unknown default:        return "Sconosciuto"
        }
    }

    // MARK: - Ringtone picker row

    private var ringtonePickerRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(scheme.onSurfaceVariant)
                .frame(width: 22)

            Text("Suoneria")
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)

            Spacer(minLength: 6)

            Picker("Suoneria", selection: Binding(
                get: { container.viewModel.ringtoneId },
                set: { container.setRingtone($0) }
            )) {
                ForEach(availableRingtones, id: \.self) { tone in
                    Text(tone.capitalized).tag(tone)
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

    // MARK: - kvRow helper

    private func kvRow(label: String, value: String, mono: Bool) -> some View {
        HStack(spacing: 14) {
            Text(label)
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)
            Spacer()
            Text(value)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .modifier(MonoIfNeededN(mono: mono))
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }
}

private struct MonoIfNeededN: ViewModifier {
    let mono: Bool
    func body(content: Content) -> some View {
        if mono {
            content.font(.system(.caption, design: .monospaced))
        } else {
            content
        }
    }
}

import SwiftUI
import QAudionEngine

@MainActor
final class NotificationsSettingsContainer: ObservableObject {
    @Published var viewModel: NotificationsSettingsViewModel
    private let store: SettingsStore

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
        self.viewModel = store.loadNotifications()
    }

    func setRingtone(_ id: String) {
        viewModel = makeUpdated(ringtoneId: id)
        store.saveNotifications(viewModel)
    }

    func toggleInAppSound(_ enabled: Bool) {
        viewModel = makeUpdated(inAppSound: enabled)
        store.saveNotifications(viewModel)
    }

    func toggleVibration(_ enabled: Bool) {
        viewModel = makeUpdated(vibration: enabled)
        store.saveNotifications(viewModel)
    }

    func setQuietHours(_ quietHours: NotificationsSettingsViewModel.QuietHours) {
        viewModel = makeUpdated(quietHours: quietHours)
        store.saveNotifications(viewModel)
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

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
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
            self.pendingCount = pending.count
            self.deliveredCount = delivered.count
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

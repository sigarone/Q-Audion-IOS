import SwiftUI
import QAudionEngine

@MainActor
final class AboutSettingsContainer: ObservableObject {
    @Published var viewModel: AboutSettingsViewModel
    init(initial: AboutSettingsViewModel = .mock) { self.viewModel = initial }
}

/// Read-only "Informazioni" screen. W26 design-token refactor: replaces
/// the iOS-native `Form { Section }` shell with the same dark editorial
/// vocabulary used in `SettingsScreen` (sectioned `surfaceVariant`-tinted
/// rows, `SettingsSectionHeader` titles, `extras.success`/`extras.riskHigh`
/// status colors). Functionally unchanged: same fields, same update
/// checker plumbing.
struct AboutSettingsScreen: View {
    @ObservedObject var container: AboutSettingsContainer
    @StateObject private var updateChecker: AppUpdateChecker
    /// W167: live WS connection state so the diagnostic status row
    /// updates in real time as connect / disconnect events fire.
    @ObservedObject private var appState: AppState

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    init(state: AppState) {
        let c = AboutSettingsContainer()
        self._container = ObservedObject(wrappedValue: c)
        self._appState = ObservedObject(wrappedValue: state)
        _updateChecker = StateObject(wrappedValue: AppUpdateChecker(appState: state))
    }

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    section("VERSIONE") {
                        kvRow("App", container.viewModel.appVersion, mono: false)
                        kvRow("Build", container.viewModel.buildNumber, mono: true)
                        kvRow("Commit", container.viewModel.gitCommitShort, mono: true)
                        // W158: capture first-launch timestamp once,
                        // then surface it as "Membro da" so the user
                        // can see how long the app has been on this
                        // device. Stamped lazily via Self.firstSeen().
                        kvRow("Membro da", Self.firstSeenLabel(), mono: false)
                        // W162: per-build install timestamp — stamped
                        // when this specific build first launched.
                        // Lets the user know how long they've been
                        // running THIS version vs the older "Membro
                        // da" which spans the whole device install.
                        kvRow("Build installato",
                              Self.buildInstalledLabel(buildNumber: container.viewModel.buildNumber),
                              mono: false)
                    }
                    section("PIATTAFORMA") {
                        kvRow("Target iOS", "iOS \(container.viewModel.iosDeploymentTarget)+", mono: true)
                        // W170: surface the runtime device + OS info
                        // so testers can quickly confirm what they're
                        // running on without leaving the app.
                        kvRow("Dispositivo", Self.deviceModelLabel(), mono: false)
                        kvRow("iOS in uso", Self.iosVersionLabel(), mono: true)
                    }
                    // W159: local data summary — gives the user a
                    // sense of how much chat content lives on this
                    // device without exposing any peer content.
                    section("DATI LOCALI") {
                        let stats = Self.localDataStats()
                        kvRow("Conversazioni", "\(stats.conversations)", mono: true)
                        kvRow("Messaggi totali", "\(stats.messages)", mono: true)
                        kvRow("Abbozzi salvati", "\(stats.drafts)", mono: true)
                    }
                    section("SICUREZZA") {
                        statusRow("ML-KEM-1024 (PQC)",
                                  enabled: container.viewModel.mlKem1024Enabled)
                        kvRow("ONNX Runtime", container.viewModel.onnxruntimeVersion, mono: true)
                    }
                    // W167: live WebSocket connection state. Helps QA
                    // confirm whether the server-side leg is healthy
                    // without opening Diagnostics export.
                    section("CONNESSIONE") {
                        kvRow("WebSocket",
                              appState.wsConnectionState.rawValue,
                              mono: true)
                        kvRow("Autenticato",
                              appState.isAuthenticated ? "sì" : "no",
                              mono: false)
                    }
                    section("AGGIORNAMENTI") {
                        updateBlock
                    }
                    // W173: 1-tap mailto to support — pre-fills the
                    // subject with the build identifier so triage is
                    // faster. Plain UIApplication.shared.open call.
                    section("ASSISTENZA") {
                        Button {
                            #if canImport(UIKit)
                            let v = container.viewModel.appVersion
                            let b = container.viewModel.buildNumber
                            let subject = "Q-Audion v\(v) (build \(b)) — segnalazione"
                            let encoded = subject
                                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                            if let url = URL(string: "mailto:support@qaudion.app?subject=" + encoded) {
                                UIApplication.shared.open(url)
                            }
                            #endif
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "envelope.fill")
                                    .font(.system(size: 17, weight: .regular))
                                    .foregroundStyle(scheme.primary)
                                    .frame(width: 22)
                                Text("Contatta supporto")
                                    .qaudionStyle(type.bodyMedium)
                                    .foregroundStyle(scheme.onSurface)
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

                        // W179: copy a compact build-ID blob (version,
                        // build, device, iOS) to the clipboard so testers
                        // can paste it into any chat / issue tracker
                        // without opening Mail. Sister to "Contatta
                        // supporto" — same data, different transport.
                        Button {
                            #if canImport(UIKit)
                            let v = container.viewModel.appVersion
                            let b = container.viewModel.buildNumber
                            let device = Self.deviceModelLabel()
                            let ios = Self.iosVersionLabel()
                            // W179: single-segment + concatenation only.
                            // See CLAUDE.md §13 — no multi-segment
                            // interpolation inside the closure.
                            let line: String =
                                "Q-Audion v" + v + " (build " + b + ") · "
                                + device + " · " + ios
                            UIPasteboard.general.string = line
                            #endif
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "doc.on.doc.fill")
                                    .font(.system(size: 17, weight: .regular))
                                    .foregroundStyle(scheme.primary)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Copia diagnostica rapida")
                                        .qaudionStyle(type.bodyMedium)
                                        .foregroundStyle(scheme.onSurface)
                                    Text("Versione · build · dispositivo · iOS")
                                        .qaudionStyle(type.labelSmall)
                                        .foregroundStyle(scheme.onSurfaceVariant)
                                }
                                Spacer()
                                Image(systemName: "doc.on.clipboard")
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
                    }
                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
            }
        }
        .navigationTitle("Informazioni")
    }

    // MARK: - Section wrapper

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        SettingsSectionHeader(title)
        VStack(spacing: 8) {
            content()
        }
    }

    /// W159: local data stats. Walks the in-memory UserDefaults
    /// dictionary to count conversations / messages / drafts. Cheap
    /// — no disk I/O beyond the initial defaults plist load.
    private struct LocalDataStats {
        let conversations: Int
        let messages: Int
        let drafts: Int
    }

    private static func localDataStats() -> LocalDataStats {
        let store = UserDefaults.standard
        let allKeys = store.dictionaryRepresentation().keys
        let convKey = "qaudion.conv.list"
        let msgPrefix = "qaudion.conv.msgs."
        let draftPrefix = "qaudion.composer.draft."

        // Conversations are persisted as a single JSON array under
        // qaudion.conv.list — count its elements if available.
        var conversations = 0
        if let data = store.data(forKey: convKey),
           let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any] {
            conversations = arr.count
        }

        var messages = 0
        for k in allKeys where k.hasPrefix(msgPrefix) {
            if let data = store.data(forKey: k),
               let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any] {
                messages += arr.count
            }
        }

        var drafts = 0
        for k in allKeys where k.hasPrefix(draftPrefix) { drafts += 1 }

        return LocalDataStats(conversations: conversations,
                              messages: messages, drafts: drafts)
    }

    /// W170: device model label for the PIATTAFORMA row.
    /// UIDevice.current.model returns generic "iPhone" / "iPad" — the
    /// hardware identifier (e.g. iPhone15,4) lives under sysctl, but
    /// the user-friendly model name is enough here.
    private static func deviceModelLabel() -> String {
        #if canImport(UIKit)
        return UIDevice.current.model
        #else
        return "?"
        #endif
    }

    /// W170: running iOS version (UIDevice.current.systemVersion).
    private static func iosVersionLabel() -> String {
        #if canImport(UIKit)
        return "iOS " + UIDevice.current.systemVersion
        #else
        return "?"
        #endif
    }

    /// W162: stamp the first-launch timestamp for THIS build number
    /// (so Settings can show "Build installato 3 giorni fa"). Keyed
    /// by `qaudion.buildSeen.<n>` so each build gets its own stamp.
    /// Format: relative time-ago in Italian.
    private static func buildInstalledLabel(buildNumber: String) -> String {
        let key = "qaudion.buildSeen." + buildNumber
        let store = UserDefaults.standard
        let date: Date = {
            if let prior = store.object(forKey: key) as? Date {
                return prior
            }
            let now = Date()
            store.set(now, forKey: key)
            return now
        }()
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return "ora" }
        if elapsed < 3600 {
            let m = Int(elapsed / 60)
            return m == 1 ? "1 minuto fa" : "\(m) minuti fa"
        }
        if elapsed < 86400 {
            let h = Int(elapsed / 3600)
            return h == 1 ? "1 ora fa" : "\(h) ore fa"
        }
        let d = Int(elapsed / 86400)
        return d == 1 ? "1 giorno fa" : "\(d) giorni fa"
    }

    /// W158: read or stamp the first-launch timestamp under
    /// `qaudion.firstSeen`. Idempotent — only writes the value the
    /// first time this helper runs on a given device.
    private static func firstSeenLabel() -> String {
        let key = "qaudion.firstSeen"
        let store = UserDefaults.standard
        let date: Date = {
            if let prior = store.object(forKey: key) as? Date {
                return prior
            }
            let now = Date()
            store.set(now, forKey: key)
            return now
        }()
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }

    // MARK: - Rows

    private func kvRow(_ label: String, _ value: String, mono: Bool) -> some View {
        HStack(spacing: 14) {
            Text(label)
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)
            Spacer()
            Text(value)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .modifier(MonoIfNeeded(mono: mono))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }

    private func statusRow(_ label: String, enabled: Bool) -> some View {
        HStack(spacing: 14) {
            Text(label)
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(enabled ? extras.success : extras.riskHigh)
                    .frame(width: 8, height: 8)
                Text(enabled ? "Attivo" : "Disattivo")
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(enabled ? extras.success : extras.riskHigh)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }

    // MARK: - Updates block

    @ViewBuilder
    private var updateBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let result = updateChecker.lastResult {
                switch result {
                case .noUpdate:
                    iconRow(icon: "checkmark.circle.fill",
                            tint: extras.success,
                            title: "Sei aggiornato all'ultima versione",
                            subtitle: nil)
                case .updateAvailable(let info):
                    VStack(alignment: .leading, spacing: 8) {
                        iconRow(icon: "arrow.down.circle.fill",
                                tint: scheme.primary,
                                title: "Aggiornamento disponibile: v\(info.availableVersion)",
                                subtitle: info.releaseNotes.isEmpty ? nil : info.releaseNotes)
                        if info.downloadUrl != nil {
                            Button { updateChecker.openAppStoreLink(for: info) } label: {
                                Text("Apri App Store")
                                    .qaudionStyle(type.labelLarge)
                                    .foregroundStyle(scheme.onPrimary)
                                    .padding(.horizontal, 16).padding(.vertical, 8)
                                    .background(Capsule().fill(scheme.primary))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                case .error(let msg):
                    iconRow(icon: "exclamationmark.triangle.fill",
                            tint: extras.warning,
                            title: msg,
                            subtitle: nil)
                }
            }

            if let last = updateChecker.lastChecked {
                Text("Ultimo controllo \(last.formatted(.relative(presentation: .named)))")
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
            }

            Button {
                Task { await updateChecker.checkForUpdates() }
            } label: {
                HStack {
                    Image(systemName: "arrow.clockwise.circle")
                    Text("Controlla aggiornamenti")
                        .qaudionStyle(type.labelLarge)
                    if updateChecker.isChecking {
                        Spacer()
                        ProgressView().scaleEffect(0.8).tint(scheme.onSurface)
                    }
                }
                .foregroundStyle(scheme.onSurface)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(scheme.surfaceVariant.opacity(0.4))
                )
            }
            .buttonStyle(.plain)
            .disabled(updateChecker.isChecking)
        }
    }

    private func iconRow(icon: String,
                         tint: Color,
                         title: String,
                         subtitle: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .qaudionStyle(type.bodyMedium)
                    .foregroundStyle(scheme.onSurface)
                if let subtitle {
                    Text(subtitle)
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }
}

private struct MonoIfNeeded: ViewModifier {
    let mono: Bool
    func body(content: Content) -> some View {
        if mono {
            content.font(.system(.caption, design: .monospaced))
        } else {
            content
        }
    }
}

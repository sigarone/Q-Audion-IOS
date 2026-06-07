import SwiftUI
import QAudionEngine

/// Modello UI per una singola release firmata OTA. 1:1 mapping di
/// Android `VerifiedRelease` (core-domain). Engine pending: il vero
/// catalog fetch + Ed25519 signature verification per release sarà
/// in `AppUpdateChecker` extension (W42-engine, deferred).
public struct VerifiedRelease: Identifiable, Equatable {
    public let id: String
    public let versionCode: Int64
    public let versionName: String
    public let sha256Hex: String        // 64 char SHA-256 del binario
    public let fileSizeBytes: Int64
    public let releaseNotes: String
    public let channel: String          // "stable" | "beta"
    public let isForced: Bool
    public let createdAt: Date
    public let signatureValid: Bool
    public let isInstalled: Bool

    public init(id: String, versionCode: Int64, versionName: String,
                sha256Hex: String, fileSizeBytes: Int64,
                releaseNotes: String, channel: String,
                isForced: Bool, createdAt: Date,
                signatureValid: Bool, isInstalled: Bool) {
        self.id = id; self.versionCode = versionCode
        self.versionName = versionName; self.sha256Hex = sha256Hex
        self.fileSizeBytes = fileSizeBytes; self.releaseNotes = releaseNotes
        self.channel = channel; self.isForced = isForced
        self.createdAt = createdAt; self.signatureValid = signatureValid
        self.isInstalled = isInstalled
    }
}

/// Container UI-only: oggi popola con mock data, in futuro userà
/// `AppUpdateChecker` esteso (engine W42).
@MainActor
final class OtaUpdateContainer: ObservableObject {
    @Published private(set) var currentVersion: String = "1.0.88"
    @Published private(set) var currentVersionCode: Int64 = 88
    @Published var betaOptIn: Bool = false {
        didSet { applyChannel() }
    }
    @Published private(set) var allReleases: [VerifiedRelease] = []
    @Published private(set) var visibleReleases: [VerifiedRelease] = []
    @Published var selectedReleaseId: String? = nil
    @Published private(set) var checking: Bool = false
    @Published private(set) var downloading: Bool = false
    @Published private(set) var downloadProgress: Float = 0.0
    @Published var error: String? = nil
    @Published var justUpdatedToVersion: String? = nil

    /// SHA-256 della pubkey Ed25519 di firma OTA. Hardcoded per ora,
    /// lo proverà dall'engine quando wires (`AppUpdateChecker.pubkey`).
    let pubkeyFingerprint: String = "a1b2c3d4 e5f60718 29304142 53647586 97a8b9ca dbecfd0e"

    init() {
        // Read real version from bundle instead of hardcoding old values.
        let info = Bundle.main.infoDictionary
        if let v = info?["CFBundleShortVersionString"] as? String {
            currentVersion = v
        }
        if let b = info?["CFBundleVersion"] as? String,
           let code = Int64(b) {
            currentVersionCode = code
        }
        load()
    }

    func load() {
        allReleases = []
        visibleReleases = []
        selectedReleaseId = nil
    }

    func applyChannel() {
        let channelKey = betaOptIn ? "beta" : "stable"
        // Stable users vedono solo stable; beta users vedono entrambi
        // (così possono fare downgrade se serve).
        if betaOptIn {
            visibleReleases = allReleases
        } else {
            visibleReleases = allReleases.filter { $0.channel == "stable" }
        }
        // Auto-seleziona la più recente non installata firmata.
        selectedReleaseId = visibleReleases.first { !$0.isInstalled && $0.signatureValid }?.id
        _ = channelKey  // future engine API call
    }

    /// W56 (Track B engine wire #2): chiama il vero `AppUpdateChecker
    /// .checkForUpdates()` (`GET /api/v1/updates/check`) e fonde il
    /// risultato server con il mock catalog. Se il server espone un
    /// update, lo prepend al `visibleReleases` come VerifiedRelease
    /// nuovo entry — la firma Ed25519 NON è ancora verificata
    /// client-side (signatureValid = false con badge "FIRMA NON
    /// VERIFICATA"), il payload viene mostrato all'utente che può
    /// decidere di tap "Installa" → apertura App Store via downloadUrl.
    /// Engine wiring per la verifica Ed25519 + catalog multi-release
    /// resta deferred.
    /// W304: timestamp of last successful check — surfaced in the UI
    /// so QA can see when the catalog was last queried.
    @Published private(set) var lastCheckedAt: Date? = nil

    func check(serverUrl: String) async {
        checking = true
        error = nil
        defer {
            checking = false
            // Stamp on every check, even if it ends in error — what
            // matters for QA is 'when did we last try' not 'when did
            // we last succeed'.
            lastCheckedAt = Date()
        }

        let checker = AppUpdateChecker(serverUrl: serverUrl)
        await checker.checkForUpdates()

        switch checker.lastResult {
        case .none:
            error = "Nessuna risposta dal server."
        case .noUpdate:
            // Mantieni la catalog list esistente; nessun nuovo entry.
            // Reload mock per coerenza con UX precedente.
            load()
        case .updateAvailable(let info):
            // Inietta l'entry nel catalog. La firma NON è ancora
            // verificata client-side (deferred — richiede pubkey
            // Ed25519 hardcoded + signature attached al payload server).
            let serverEntry = VerifiedRelease(
                id: "server-\(info.availableVersion)",
                versionCode: 0,
                versionName: info.availableVersion,
                sha256Hex: "",
                fileSizeBytes: 0,
                releaseNotes: info.releaseNotes,
                channel: "stable",
                isForced: info.isMandatory,
                createdAt: Date(),
                signatureValid: false,  // Ed25519 verify deferred
                isInstalled: false
            )
            allReleases = [serverEntry]
            applyChannel()
        case .error(let msg):
            error = "Verifica fallita: \(msg)"
        }
    }

    func install() async {
        // On iOS, installation is handled by TestFlight or the App Store.
        // There is no mechanism to install an IPA from a custom server
        // outside Apple's distribution channels. Open TestFlight directly.
        #if canImport(UIKit)
        await MainActor.run {
            if let url = URL(string: "itms-beta://") {
                if UIApplication.shared.canOpenURL(url) {
                    UIApplication.shared.open(url)
                    return
                }
            }
            if let url = URL(string: "https://testflight.apple.com") {
                UIApplication.shared.open(url)
            }
        }
        #endif
    }

}

/// Schermo "Aggiornamento firmato OTA". 1:1 visual port di Android
/// `qaudion-android-new/feature/feature-settings/.../OtaUpdateScreen.kt`.
struct OtaUpdateScreen: View {
    @StateObject private var container = OtaUpdateContainer()
    @EnvironmentObject private var appState: AppState
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type
    @Environment(\.qaudionSnackbar) private var snackbar

    @State private var showingInstallConfirm: VerifiedRelease? = nil

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let installed = container.justUpdatedToVersion {
                        justUpdatedBanner(version: installed)
                    }
                    versionCard
                    channelCard
                    trustCard
                    SettingsSectionHeader("RELEASE DISPONIBILI")
                    releasesBlock
                    if let err = container.error {
                        errorBanner(err)
                    }
                    actionButtons.padding(.top, 4)
                    // W304: 'Ultimo controllo N minuti fa' — surfaces
                    // when the catalog was last queried. Renders only
                    // if at least one check has been performed in this
                    // session.
                    if let last = container.lastCheckedAt {
                        Text(Self.lastCheckedLabel(last))
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(scheme.onSurfaceVariant)
                            .padding(.top, 8)
                    }
                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
        }
        .navigationTitle("Aggiornamento OTA")
        .navigationBarTitleDisplayMode(.inline)
        .alert(installConfirmTitle,
               isPresented: installConfirmBinding,
               presenting: showingInstallConfirm) { release in
            Button("Installa") {
                Task {
                    await container.install()
                    snackbar?.show(.init(
                        text: "Aggiornamento a \(release.versionName) avviato.",
                        severity: .info))
                }
            }
            Button("Annulla", role: .cancel) {}
        } message: { _ in
            Text("Su iOS gli aggiornamenti vengono distribuiti via TestFlight o App Store. Verrai reindirizzato a TestFlight per installare la build.")
        }
    }

    // MARK: - Just-updated banner

    private func justUpdatedBanner(version: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(extras.success)
                .font(.system(size: 18, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("AGGIORNAMENTO COMPLETATO")
                    .qaudionStyle(type.labelSmall)
                    .tracking(1.2)
                    .foregroundStyle(extras.success)
                Text("Ora stai usando \(version)")
                    .qaudionStyle(type.bodySmall)
                    .foregroundStyle(scheme.onSurface)
            }
            Spacer()
            Button {
                container.justUpdatedToVersion = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .padding(6)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(extras.success.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(extras.success.opacity(0.45), lineWidth: 1)
        )
    }

    // MARK: - Version card

    private var versionCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("VERSIONE INSTALLATA")
                .qaudionStyle(type.labelSmall)
                .tracking(1.5)
                .foregroundStyle(scheme.primary)
            Text(container.currentVersion)
                .font(.system(size: 24, weight: .semibold, design: .monospaced))
                .foregroundStyle(scheme.onSurface)
            Text("versionCode \(container.currentVersionCode)")
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .modifier(MonoSmall())
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(scheme.surfaceVariant.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(scheme.outline.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Channel card

    private var channelCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CANALE RELEASE")
                .qaudionStyle(type.labelSmall)
                .tracking(1.5)
                .foregroundStyle(scheme.primary)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(container.betaOptIn ? "BETA" : "STABLE")
                        .qaudionStyle(type.titleSmall)
                        .tracking(1.0)
                        .foregroundStyle(container.betaOptIn ? extras.warning
                                                              : extras.success)
                    Text(container.betaOptIn
                         ? "Ricevi build pre-rilascio firmate. Possono contenere bug — rientri in stable disattivando l'opzione."
                         : "Ricevi solo build stabili. Attiva per testare versioni in anteprima.")
                        .qaudionStyle(type.bodySmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { container.betaOptIn },
                    set: { container.betaOptIn = $0 }
                ))
                    .labelsHidden()
                    .tint(extras.warning)
                    .disabled(container.checking || container.downloading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(scheme.surfaceVariant.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(container.betaOptIn ? extras.warning.opacity(0.5)
                                            : scheme.outline.opacity(0.4),
                        lineWidth: 1)
        )
    }

    // MARK: - Trust card

    private var trustCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PUBKEY FINGERPRINT (SHA-256)")
                .qaudionStyle(type.labelSmall)
                .tracking(1.5)
                .foregroundStyle(scheme.primary)
            Text(container.pubkeyFingerprint)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(scheme.onSurface)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(scheme.surfaceVariant.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(scheme.outline.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Releases block

    @ViewBuilder
    private var releasesBlock: some View {
        if container.checking {
            HStack(spacing: 8) {
                ProgressView().progressViewStyle(.circular)
                    .tint(scheme.primary)
                Text("INTERROGAZIONE SERVER…")
                    .qaudionStyle(type.labelSmall)
                    .tracking(1.2)
                    .foregroundStyle(scheme.onSurfaceVariant)
            }
            .padding(.vertical, 8)
        } else if container.visibleReleases.isEmpty {
            Text("NESSUNA RELEASE CARICATA. Premi Verifica per interrogare il server.")
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .padding(.vertical, 8)
        } else {
            VStack(spacing: 8) {
                ForEach(container.visibleReleases) { release in
                    releaseRow(release)
                }
            }
        }
    }

    private func releaseRow(_ release: VerifiedRelease) -> some View {
        let isSelected = container.selectedReleaseId == release.id
        return Button {
            if !release.isInstalled && release.signatureValid {
                container.selectedReleaseId = release.id
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(release.versionName)
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundStyle(scheme.onSurface)
                    Text("(\(release.versionCode))")
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .modifier(MonoSmall())
                    Spacer(minLength: 6)
                    if release.isInstalled {
                        Text("INSTALLATA")
                            .qaudionStyle(type.labelSmall)
                            .tracking(1.0)
                            .foregroundStyle(extras.success)
                    }
                    if release.isForced {
                        Text("FORZATA")
                            .qaudionStyle(type.labelSmall)
                            .tracking(1.0)
                            .foregroundStyle(extras.warning)
                    }
                    Image(systemName: release.signatureValid
                          ? "checkmark.seal.fill"
                          : "xmark.octagon.fill")
                        .foregroundStyle(release.signatureValid
                                         ? extras.success
                                         : extras.riskHigh)
                        .font(.system(size: 14, weight: .semibold))
                }
                HStack(spacing: 6) {
                    Text(release.signatureValid ? "FIRMA OK" : "FIRMA INVALIDA")
                        .qaudionStyle(type.labelSmall)
                        .tracking(1.0)
                        .foregroundStyle(release.signatureValid ? extras.success : extras.riskHigh)
                    Text("·")
                        .foregroundStyle(scheme.onSurfaceVariant)
                    Text(formatBytes(release.fileSizeBytes))
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .modifier(MonoSmall())
                    Text("·")
                        .foregroundStyle(scheme.onSurfaceVariant)
                    Text(formatDate(release.createdAt))
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .modifier(MonoSmall())
                    if release.channel == "beta" {
                        Text("· BETA")
                            .qaudionStyle(type.labelSmall)
                            .tracking(1.0)
                            .foregroundStyle(extras.warning)
                    }
                }
                Text(release.releaseNotes)
                    .qaudionStyle(type.bodySmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .padding(.top, 2)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(scheme.surfaceVariant.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isSelected ? scheme.primary
                                       : scheme.outline.opacity(0.35),
                            lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(release.isInstalled || !release.signatureValid)
    }

    // MARK: - Download progress + actions

    private var downloadProgressRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DOWNLOAD \(Int(container.downloadProgress * 100))%")
                .qaudionStyle(type.labelSmall)
                .tracking(1.2)
                .foregroundStyle(extras.success)
            ProgressView(value: container.downloadProgress)
                .tint(extras.success)
        }
        .padding(.horizontal, 4)
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button {
                Task { await container.check(serverUrl: appState.serverUrl) }
                snackbar?.show(.init(text: "Verifica avviata.",
                                     severity: .info,
                                     durationSeconds: 2))
            } label: {
                Text(container.checking ? "Verifica…" : "Verifica")
                    .qaudionStyle(type.labelLarge)
                    .foregroundStyle(scheme.onPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(container.checking
                                  ? scheme.surfaceVariant
                                  : scheme.primary)
                    )
            }
            .buttonStyle(.plain)
            .disabled(container.checking || container.downloading)

            Button {
                if let id = container.selectedReleaseId,
                   let release = container.visibleReleases.first(where: { $0.id == id }) {
                    showingInstallConfirm = release
                }
            } label: {
                Text("Installa")
                    .qaudionStyle(type.labelLarge)
                    .foregroundStyle(scheme.onPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(canInstall ? extras.success
                                             : scheme.surfaceVariant)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canInstall || container.downloading)
        }
    }

    private var canInstall: Bool {
        guard let id = container.selectedReleaseId,
              let release = container.visibleReleases.first(where: { $0.id == id })
        else { return false }
        return release.signatureValid && !release.isInstalled && !container.downloading
    }

    // MARK: - Alert plumbing

    private var installConfirmTitle: String {
        guard let release = showingInstallConfirm else { return "Installa aggiornamento" }
        return "Installa \(release.versionName)?"
    }

    /// Two-way binding that mirrors `showingInstallConfirm != nil` for the
    /// `isPresented:` parameter of `.alert(_:isPresented:presenting:)`. The
    /// alert API on iOS 16 needs both an `isPresented` Bool and a
    /// `presenting` value; we keep the optional release as the source of
    /// truth and synthesize the Bool from it.
    private var installConfirmBinding: Binding<Bool> {
        Binding(
            get: { showingInstallConfirm != nil },
            set: { newValue in
                if !newValue { showingInstallConfirm = nil }
            }
        )
    }

    // MARK: - Helpers

    private func errorBanner(_ msg: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(extras.riskHigh)
            Text(msg)
                .qaudionStyle(type.bodySmall)
                .italic()
                .foregroundStyle(extras.riskHigh)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(extras.riskHigh.opacity(0.12))
        )
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.1f MB", mb)
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "d MMM"
        return f.string(from: date)
    }

    /// W304: 'Ultimo controllo N minuti fa' relative label. Static so
    /// the call-site stays trivial — CLAUDE.md §13.
    private static func lastCheckedLabel(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.unitsStyle = .full
        let rel: String = f.localizedString(for: date, relativeTo: Date())
        return "Ultimo controllo " + rel
    }
}

private struct MonoSmall: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.system(.caption, design: .monospaced))
    }
}

#Preview {
    NavigationStack {
        OtaUpdateScreen()
            .environmentObject(AppState())
    }
    .qAudionTheme(dark: true)
}

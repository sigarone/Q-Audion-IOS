import SwiftUI
import UIKit
import QAudionEngine

/// W48: dev-only diagnostics export. Genera un text dump shareable con
/// build info, device info, e state non-credenziale dell'app — utile
/// quando un beta tester vuole mandarci un bug report. **Non** include
/// token / refresh-token / private keys / chat content — solo metadata
/// pubblici. Sister di W46 DevResetScreen: insieme formano la "QA
/// toolkit" sotto Impostazioni → SVILUPPATORE.
@MainActor
final class DiagnosticsExportContainer: ObservableObject {
    @Published var report: String = ""
    @Published var generating: Bool = false
    @Published var lastGeneratedAt: Date? = nil

    /// Build info dal main bundle Info.plist + git commit short.
    private var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    func generate(appState: AppState) async {
        generating = true
        try? await Task.sleep(nanoseconds: 300_000_000) // UX latency
        var lines: [String] = []

        lines.append("Q-AUDION iOS — Diagnostics report")
        lines.append("Generato: \(formatNow())")
        lines.append("")

        // ─── BUILD ─────────────────────────────────────────────────
        lines.append("BUILD")
        lines.append("  app version : \(bundleVersion)")
        lines.append("  build       : \(buildNumber)")
        lines.append("  bundle id   : \(Bundle.main.bundleIdentifier ?? "?")")
        lines.append("")

        // ─── DEVICE ────────────────────────────────────────────────
        lines.append("DEVICE")
        lines.append("  model       : \(UIDevice.current.model)")
        lines.append("  name        : <redacted>")  // never leak user's device name
        lines.append("  iOS         : \(UIDevice.current.systemVersion)")
        lines.append("  locale      : \(Locale.current.identifier)")
        lines.append("  timezone    : \(TimeZone.current.identifier)")
        lines.append("")

        // ─── SYSTEM STATE (W283 — pulls from W264-W282 telemetry) ──
        // Pre-bind every interpolated value to a local — see CLAUDE.md
        // §13. Each line gets ONE simple local interpolation, no chains.
        lines.append("SYSTEM STATE")
        let pi = ProcessInfo.processInfo
        let thermal: String = {
            switch pi.thermalState {
            case .nominal:   return "nominal"
            case .fair:      return "fair"
            case .serious:   return "serious"
            case .critical:  return "critical"
            @unknown default: return "?"
            }
        }()
        let lowPower: String = pi.isLowPowerModeEnabled ? "yes" : "no"
        let cores: String = String(pi.activeProcessorCount)
        let physMemMB: String = String(pi.physicalMemory / (1024 * 1024))
        let uptimeSec: String = String(Int(pi.systemUptime))
        lines.append("  thermal state : \(thermal)")
        lines.append("  low-power mode: \(lowPower)")
        lines.append("  active cores  : \(cores)")
        lines.append("  physical mem  : \(physMemMB) MB")
        lines.append("  system uptime : \(uptimeSec) s")

        // Free-disk: pull volumeAvailableCapacityForImportantUsage. This
        // is the realistic "how much can grow into" number iOS exposes,
        // accounting for purgeable caches.
        let docsURL = try? FileManager.default.url(for: .documentDirectory,
                                                   in: .userDomainMask,
                                                   appropriateFor: nil,
                                                   create: false)
        let freeMB: String = {
            guard let url = docsURL,
                  let vals = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
                  let bytes = vals.volumeAvailableCapacityForImportantUsage else {
                return "?"
            }
            return String(bytes / (1024 * 1024))
        }()
        lines.append("  free disk     : \(freeMB) MB")
        lines.append("")

        // ─── AUTH STATE (no secrets) ───────────────────────────────
        lines.append("AUTH")
        lines.append("  authenticated : \(appState.isAuthenticated)")
        lines.append("  has user id   : \(appState.currentUserId != nil)")
        lines.append("  has token     : \(appState.authService.loadToken() != nil)")
        let hasDeviceId = UserDefaults.standard.string(forKey: "com.qaudion.auth.device_id") != nil
        lines.append("  has device id : \(hasDeviceId)")
        lines.append("")

        // ─── CALL STATE ────────────────────────────────────────────
        lines.append("CALL")
        lines.append("  in call     : \(appState.isInCall)")
        lines.append("  state       : \(appState.callState.rawValue)")
        lines.append("  is video    : \(appState.isVideoCall)")
        lines.append("  has peer    : \(appState.callContactId != nil)")
        lines.append("")

        // ─── USERDEFAULTS (count summary, no values) ───────────────
        let knownKeys = DevResetContainer.knownKeys
        var presentCount = 0
        for key in knownKeys {
            if UserDefaults.standard.object(forKey: key) != nil {
                presentCount += 1
            }
        }
        lines.append("USERDEFAULTS")
        lines.append("  known keys present : \(presentCount) / \(knownKeys.count)")
        // Surface a few specific counts that are meaningful:
        let phones = UserDefaults.standard.array(forKey: "com.qaudion.profile.myPhones") as? [String]
        lines.append("  myPhones count     : \(phones?.count ?? 0)")
        // W164: per-device metadata counts (W137/W142/W158/W162).
        // Plain integers — no key contents leaked.
        let allKeys = UserDefaults.standard.dictionaryRepresentation().keys
        var draftCount = 0
        var lastSeenCount = 0
        var buildSeenCount = 0
        for k in allKeys {
            if k.hasPrefix("qa.composer.draft.") { draftCount += 1 }
            else if k.hasPrefix("qa.lastSeenAt.") { lastSeenCount += 1 }
            else if k.hasPrefix("qaudion.buildSeen.") { buildSeenCount += 1 }
        }
        lines.append("  drafts saved       : \(draftCount)")
        lines.append("  last-seen stamps   : \(lastSeenCount)")
        lines.append("  build-seen stamps  : \(buildSeenCount)")
        lines.append("")

        // ─── ERRORE ATTUALE ────────────────────────────────────────
        if let err = appState.errorMessage {
            lines.append("LAST ERROR")
            lines.append("  \(err)")
            lines.append("")
        }

        // ─── SERVER ────────────────────────────────────────────────
        lines.append("SERVER")
        lines.append("  pinned      : \(PinnedServerHost.url)")
        lines.append("")

        lines.append("─── end ───")

        report = lines.joined(separator: "\n")
        lastGeneratedAt = Date()
        generating = false
    }

    private func formatNow() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        return f.string(from: Date())
    }
}

struct DiagnosticsExportScreen: View {
    @StateObject private var container = DiagnosticsExportContainer()
    @EnvironmentObject var appState: AppState
    @State private var showingShareSheet: Bool = false

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type
    @Environment(\.qaudionSnackbar) private var snackbar

    // W415: state for the runtime-log section
    @StateObject private var logSink = RuntimeLogSink.shared
    @State private var showingLogSheet: Bool = false
    @State private var showingLogShare: Bool = false
    @State private var logShareUrl: URL? = nil
    @State private var uploading: Bool = false
    @State private var uploadFileId: String? = nil
    @State private var uploadError: String? = nil

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    introCard
                    if !container.report.isEmpty {
                        reportCard
                        actionRow
                    }
                    generateButton
                    // W415 — runtime log section (sempre visibile,
                    // indipendente dal generate del report).
                    runtimeLogCard
                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
        }
        .navigationTitle("Esporta diagnostica")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingShareSheet) {
            DiagnosticsShareSheet(items: [container.report])
        }
        .sheet(isPresented: $showingLogSheet) {
            RuntimeLogViewerSheet()
        }
        .sheet(isPresented: $showingLogShare) {
            if let url = logShareUrl {
                DiagnosticsShareSheet(items: [url])
            }
        }
        .task {
            // Auto-generate on first appearance so the user sees content
            // immediately rather than a blank "Genera" prompt.
            if container.report.isEmpty {
                await container.generate(appState: appState)
            }
        }
    }

    // MARK: - W415 runtime log section

    private var runtimeLogCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LOG RUNTIME (\(logSink.entryCount) righe)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(scheme.primary)
            Text("Sistema RTLog cattura eventi app (call setup, WS, errori) in un buffer in-memory. Niente token, niente messaggi utente. Esportabile per debug remoto.")
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .padding(.bottom, 4)
            HStack(spacing: 8) {
                Button {
                    showingLogSheet = true
                } label: {
                    Label("Mostra", systemImage: "doc.text.magnifyingglass")
                        .qaudionStyle(type.labelSmall)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(scheme.surfaceVariant.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Button {
                    do {
                        let url = try LogExportService.shared.writeDumpToTempFile(appState: appState)
                        logShareUrl = url
                        showingLogShare = true
                    } catch {
                        uploadError = error.localizedDescription
                    }
                } label: {
                    Label("Condividi", systemImage: "square.and.arrow.up")
                        .qaudionStyle(type.labelSmall)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(scheme.surfaceVariant.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Button {
                    uploading = true
                    uploadFileId = nil
                    uploadError = nil
                    Task {
                        do {
                            let id = try await LogExportService.shared.uploadDump(appState: appState)
                            await MainActor.run {
                                self.uploadFileId = id
                                self.uploading = false
                            }
                        } catch {
                            await MainActor.run {
                                self.uploadError = error.localizedDescription
                                self.uploading = false
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if uploading {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Image(systemName: "icloud.and.arrow.up")
                        }
                        Text(uploading ? "Carico…" : "Carica al server")
                            .qaudionStyle(type.labelSmall)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(scheme.primary.opacity(0.85))
                    .foregroundStyle(scheme.onPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .disabled(uploading)
                Spacer()
                Button {
                    logSink.clear()
                } label: {
                    Image(systemName: "trash")
                        .padding(8)
                        .background(extras.riskHigh.opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(extras.riskHigh)
                }
            }
            if let id = uploadFileId {
                VStack(alignment: .leading, spacing: 4) {
                    Text("UPLOAD COMPLETATO — fileId:")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(extras.success)
                    Text(id)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(scheme.onSurface)
                    Text("Copia + condividi col maintainer. Lui può scaricare il dump via:")
                        .font(.system(size: 10))
                        .foregroundStyle(scheme.onSurfaceVariant)
                    Text("curl -H \"Authorization: Bearer <admin>\" \(appState.serverUrl)/api/v1/files/\(id)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .textSelection(.enabled)
                }
                .padding(10)
                .background(extras.success.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if let err = uploadError {
                Text("Errore: \(err)")
                    .font(.system(size: 11))
                    .foregroundStyle(extras.riskHigh)
                    .padding(8)
                    .background(extras.riskHigh.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(scheme.outline.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Intro

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DEVTOOL")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(extras.warning)
            Text("Genera un report testuale con build, device, stato auth e summary di UserDefaults. **Non** include token, refresh-token, chiavi private né contenuti chat — solo metadata. Utile per allegare a bug-report TestFlight.")
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurface)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(extras.warning.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(extras.warning.opacity(0.45), lineWidth: 1)
        )
    }

    // MARK: - Report card

    private var reportCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("REPORT")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(scheme.primary)
            ScrollView {
                Text(container.report)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(scheme.onSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 360)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(scheme.surfaceVariant.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(scheme.outline.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Actions

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                UIPasteboard.general.string = container.report
                snackbar?.show(.init(text: "Report copiato.", severity: .info))
            } label: {
                Label("Copia", systemImage: "doc.on.doc")
                    .qaudionStyle(type.labelMedium)
                    .foregroundStyle(scheme.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(scheme.primary.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(scheme.primary.opacity(0.45), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            Button {
                showingShareSheet = true
            } label: {
                Label("Condividi", systemImage: "square.and.arrow.up")
                    .qaudionStyle(type.labelMedium)
                    .foregroundStyle(scheme.onPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(scheme.primary)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Generate button

    private var generateButton: some View {
        Button {
            Task { await container.generate(appState: appState) }
        } label: {
            HStack(spacing: 8) {
                if container.generating {
                    ProgressView().progressViewStyle(.circular)
                        .tint(scheme.primary)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                }
                Text(container.generating ? "Generazione…" : "Rigenera report")
                    .qaudionStyle(type.labelMedium)
            }
            .foregroundStyle(scheme.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(scheme.outline.opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(container.generating)
    }
}

/// `UIActivityViewController` wrapper per il share sheet su iOS 16+.
private struct DiagnosticsShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    NavigationStack {
        DiagnosticsExportScreen()
            .environmentObject(AppState())
    }
    .qAudionTheme(dark: true)
}

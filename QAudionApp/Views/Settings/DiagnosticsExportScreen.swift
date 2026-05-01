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
        .task {
            // Auto-generate on first appearance so the user sees content
            // immediately rather than a blank "Genera" prompt.
            if container.report.isEmpty {
                await container.generate(appState: appState)
            }
        }
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

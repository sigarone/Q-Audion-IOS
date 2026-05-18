import SwiftUI
import CoreImage.CIFilterBuiltins
import QAudionEngine

/// Key management sub-screen. W31 design-token refactor.
/// Replaces stock `Form` with the new design vocabulary while
/// preserving every coordinator binding (rotate / NFC pair / QR
/// export / clipboard).
struct KeyManagementScreen: View {
    @StateObject private var coordinator: KeyRotationCoordinator
    @State private var showingRotateConfirm = false
    @State private var showingIdentityText = false

    private let appState: AppState

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type
    @Environment(\.qaudionSnackbar) private var snackbar

    init(state: AppState) {
        self.appState = state
        _coordinator = StateObject(wrappedValue: KeyRotationCoordinator(appState: state))
    }

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsSectionHeader("FINGERPRINT IDENTITÀ")
                    fingerprintCard

                    if let qrString = coordinator.currentIdentityQr {
                        SettingsSectionHeader("MOSTRA LA TUA IDENTITÀ")
                        VStack(spacing: 12) {
                            qrCard(content: qrString)
                            actionRow(icon: "doc.plaintext.fill",
                                      title: "Mostra come testo") {
                                showingIdentityText = true
                            }
                            actionRow(icon: "doc.on.doc.fill",
                                      title: "Copia negli appunti") {
                                UIPasteboard.general.string = qrString
                            }
                        }
                    }

                    SettingsSectionHeader("ROTAZIONE CHIAVI")
                    VStack(spacing: 8) {
                        if let last = coordinator.lastRotationDate {
                            kvRow(label: "Ultima rotazione",
                                  value: last.formatted(.relative(presentation: .named)),
                                  mono: false)
                        }
                        rotateButton
                        Text("La rotazione genera una nuova identità. I tuoi contatti vedranno un fingerprint diverso e dovranno ri-verificarti.")
                            .qaudionStyle(type.labelSmall)
                            .foregroundStyle(scheme.onSurfaceVariant)
                            .padding(.horizontal, 14)
                    }

                    SettingsSectionHeader("DISPOSITIVI")
                    VStack(spacing: 8) {
                        NavigationLink {
                            DeviceManagementScreen(state: appState)
                        } label: {
                            SettingsRow(icon: "iphone",
                                        iconColor: scheme.primary,
                                        title: "Dispositivi collegati")
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            NfcExchangeView()
                        } label: {
                            SettingsRow(icon: "wave.3.right",
                                        iconColor: extras.pqcAccent,
                                        title: "Accoppia via NFC")
                        }
                        .buttonStyle(.plain)
                    }

                    if let err = coordinator.errorMessage {
                        errorBanner(err).padding(.top, 12)
                    }

                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
            }
        }
        .navigationTitle("Gestione chiavi")
        // SECURITY F-3: this screen shows the identity QR + fingerprint
        // and supports clipboard export of identity material. Mirror
        // ChatDetailScreen's secure-window lifecycle so it cannot be
        // screenshotted / recorded / AirPlay-mirrored while presented.
        .onAppear { ScreenshotLockService.lock() }
        .onDisappear { ScreenshotLockService.unlock() }
        .alert("Ruotare le chiavi?", isPresented: $showingRotateConfirm) {
            Button("Annulla", role: .cancel) { }
            Button("Ruota", role: .destructive) {
                coordinator.rotate()
                snackbar?.show(.init(
                    text: "Rotazione chiavi avviata.",
                    severity: .warning,
                    durationSeconds: 5
                ))
            }
        } message: {
            Text("Verranno generate nuove chiavi. Tutti i contatti dovranno ri-verificare la tua identità. Continuare?")
        }
        .sheet(isPresented: $showingIdentityText) {
            NavigationStack {
                ZStack {
                    scheme.background.ignoresSafeArea()
                    if let qr = coordinator.currentIdentityQr {
                        ScrollView {
                            Text(qr)
                                .qaudionStyle(type.bodySmall)
                                .modifier(MonoIfNeededK(mono: true))
                                .foregroundStyle(scheme.onSurface)
                                .padding(20)
                                .textSelection(.enabled)
                        }
                    }
                }
                .navigationTitle("Testo identità")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Fatto") { showingIdentityText = false }
                    }
                }
            }
        }
    }

    // MARK: - Fingerprint card

    private var fingerprintCard: some View {
        Text(coordinator.currentFingerprint)
            .font(.system(.title3, design: .monospaced).weight(.bold))
            .foregroundStyle(scheme.onSurface)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16).padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(scheme.surfaceVariant.opacity(0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(scheme.primary.opacity(0.4), lineWidth: 1)
            )
    }

    // MARK: - QR card

    private func qrCard(content: String) -> some View {
        VStack {
            qrCodeImage(for: content)
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white)
                )
        }
    }

    @ViewBuilder
    private func qrCodeImage(for content: String) -> some View {
        if let image = generateQrImage(from: content) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Text("Generazione QR fallita")
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(extras.riskHigh)
        }
    }

    private func generateQrImage(from content: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scale = CGAffineTransform(scaleX: 8, y: 8)
        let scaled = outputImage.transformed(by: scale)
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Rotate button

    private var rotateButton: some View {
        Button(action: { showingRotateConfirm = true }) {
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .foregroundStyle(extras.warning)
                Text("Ruota chiavi")
                    .qaudionStyle(type.labelLarge)
                    .foregroundStyle(extras.warning)
                Spacer()
                if coordinator.isRotating {
                    ProgressView().progressViewStyle(.circular).tint(extras.warning)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(extras.warning.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(extras.warning.opacity(0.45), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(coordinator.isRotating)
    }

    // MARK: - Generic action row + kv + error helpers

    private func actionRow(icon: String,
                           title: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(scheme.primary)
                    .frame(width: 22)
                Text(title)
                    .qaudionStyle(type.bodyMedium)
                    .foregroundStyle(scheme.onSurface)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(scheme.onSurfaceVariant)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 56)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(scheme.surfaceVariant.opacity(0.4))
            )
        }
        .buttonStyle(.plain)
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
                .modifier(MonoIfNeededK(mono: mono))
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(extras.riskHigh)
                .padding(.top, 1)
            Text(msg)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(extras.riskHigh)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(extras.riskHigh.opacity(0.12))
        )
    }
}

private struct MonoIfNeededK: ViewModifier {
    let mono: Bool
    func body(content: Content) -> some View {
        if mono {
            content.font(.system(.caption, design: .monospaced))
        } else {
            content
        }
    }
}

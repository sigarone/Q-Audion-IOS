import SwiftUI
import CoreImage.CIFilterBuiltins
import CryptoKit
import QAudionEngine

/// "Collega nuovo dispositivo" screen. 1:1 port di Android
/// `qaudion-android-new/feature/feature-settings/.../LinkNewDeviceScreen.kt`.
///
/// Genera una keypair X25519 efimera lato iOS (CryptoKit
/// `Curve25519.KeyAgreement.PrivateKey`), encoda la pubkey in un payload
/// JSON `bcrypto-device-link`, render il QR via `CIQRCodeGenerator`
/// (CoreImage), e mostra il fingerprint diviso in 6 gruppi da 8 hex
/// (48 char totali = 24 byte HKDF-SHA256). Quando l'utente preme
/// "RIGENERA" la keypair viene wipata e una nuova è generata.
///
/// Engine wiring pending: il pairing handshake server-side (POST
/// /auth/devices/link) non è ancora wired. Per ora la generazione è
/// pure-locale; quando l'engine espone la pipeline, `onPairingComplete`
/// sarà chiamato con il `deviceId` assegnato dal server.
struct LinkNewDeviceScreen: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type
    @Environment(\.dismiss) private var dismiss

    /// Callback chiamato quando il pairing è completato. Per ora invocato
    /// solo manualmente via stub button "Simula pairing"; quando l'engine
    /// wires la WS observer del pairing handshake, questa callback
    /// è il punto di handoff verso DeviceManagementScreen.
    let onPairingComplete: (String) -> Void

    @State private var ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey?
    @State private var qrImage: UIImage? = nil
    @State private var fingerprintGroups: [String] = []
    @State private var generating: Bool = true
    @State private var errorMessage: String? = nil
    // W316 — UX feedback for tap-to-copy on the fingerprint.
    @State private var copiedFlash: Bool = false

    // W316 — static copy helpers (avoid multi-segment interpolation in
    // ViewBuilder closures per SWIFT6_PATTERNS.md §1).
    private static let stubPairingHint: String =
        "Funzione in arrivo — il pairing server-side non è ancora attivo. Per ora il QR genera solo materiale locale."
    private static let copyHint: String =
        "Tocca il fingerprint per copiarlo."
    private static let copiedConfirmation: String =
        "Fingerprint copiato negli appunti."

    init(onPairingComplete: @escaping (String) -> Void = { _ in }) {
        self.onPairingComplete = onPairingComplete
    }

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    instructionsBanner
                    qrCard
                    if !fingerprintGroups.isEmpty {
                        fingerprintBlock
                    }
                    // W316 — explicit stub disclaimer about server wiring.
                    Text(Self.stubPairingHint)
                        .qaudionStyle(type.labelSmall)
                        .italic()
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let err = errorMessage {
                        errorBanner(err)
                    }
                    Spacer().frame(height: 32)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
        }
        .navigationTitle("Collega dispositivo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { regenerate() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                        Text("RIGENERA")
                            .qaudionStyle(type.labelSmall)
                            .tracking(1.2)
                    }
                    .foregroundStyle(scheme.primary)
                }
                .disabled(generating)
            }
        }
        .onAppear {
            if ephemeralPrivateKey == nil { regenerate() }
        }
        .onDisappear {
            // Wipe ephemeral key on disappear: nessun materiale segreto
            // sopravvive alla chiusura della view.
            ephemeralPrivateKey = nil
        }
    }

    // MARK: - Instructions banner

    private var instructionsBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ISTRUZIONI")
                .qaudionStyle(type.labelSmall)
                .tracking(1.5)
                .foregroundStyle(scheme.primary)
            Text("1. Apri Q-Audion sul nuovo dispositivo.\n2. Tocca \"Collega dispositivo\".\n3. Inquadra il QR qui sotto con la fotocamera.")
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurface)
            Text("Il QR contiene solo la chiave pubblica X25519 e un codice monouso: nessun segreto transita.")
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(scheme.surfaceVariant.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(scheme.outline.opacity(0.5), lineWidth: 1)
        )
    }

    // MARK: - QR card

    @ViewBuilder
    private var qrCard: some View {
        VStack {
            if generating {
                VStack(spacing: 10) {
                    ProgressView().progressViewStyle(.circular)
                        .tint(scheme.primary)
                    Text("Generazione chiave efimera…")
                        .qaudionStyle(type.bodySmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity, minHeight: 280)
            } else if let qr = qrImage {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 280, height: 280)
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 8).fill(.white)
                    )
                    .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(extras.riskHigh)
                    Text("QR non disponibile")
                        .qaudionStyle(type.bodyMedium)
                        .foregroundStyle(scheme.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity, minHeight: 280)
            }
        }
    }

    // MARK: - Fingerprint block

    private var fingerprintBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FINGERPRINT")
                .qaudionStyle(type.labelSmall)
                .tracking(1.5)
                .foregroundStyle(scheme.primary)
            // 6 gruppi da 8 hex → 3 righe da 2 gruppi
            let rows: [[String]] = stride(from: 0, to: fingerprintGroups.count, by: 2).map {
                Array(fingerprintGroups[$0..<min($0 + 2, fingerprintGroups.count)])
            }
            ForEach(0..<rows.count, id: \.self) { i in
                HStack(spacing: 12) {
                    ForEach(rows[i], id: \.self) { g in
                        Text(g)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundStyle(scheme.onSurface)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            // W316 — tap-to-copy hint / confirmation row.
            Text(copiedFlash ? Self.copiedConfirmation : Self.copyHint)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(copiedFlash ? scheme.primary : scheme.onSurfaceVariant)
                .padding(.top, 4)
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
        .contentShape(Rectangle())
        .onTapGesture(perform: copyFingerprint)
    }

    // W316 — extracted copy helper. Closure body kept trivial per
    // SWIFT6_PATTERNS.md §5 (no deep nesting in onTapGesture closure).
    private func copyFingerprint() {
        let joined: String = fingerprintGroups.joined(separator: " ")
        guard !joined.isEmpty else { return }
        UIPasteboard.general.string = joined
        copiedFlash = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copiedFlash = false
        }
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(extras.riskHigh)
            Text(msg)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(extras.riskHigh)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(extras.riskHigh.opacity(0.12))
        )
    }

    // MARK: - Generate / Regenerate

    private func regenerate() {
        generating = true
        errorMessage = nil
        qrImage = nil
        fingerprintGroups = []

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000) // UX latency

            // Generate ephemeral X25519 keypair
            let key = Curve25519.KeyAgreement.PrivateKey()
            ephemeralPrivateKey = key

            let pubkeyBytes = key.publicKey.rawRepresentation
            let payload = encodePairingPayload(pubkey: pubkeyBytes)

            // Generate QR via CoreImage
            qrImage = generateQrImage(content: payload)

            // Compute fingerprint: SHA-256 of pubkey, first 24 bytes,
            // grouped 4-byte (8 hex) chunks → 6 groups
            let digest = SHA256.hash(data: pubkeyBytes).prefix(24)
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            fingerprintGroups = stride(from: 0, to: hex.count, by: 8).map {
                let start = hex.index(hex.startIndex, offsetBy: $0)
                let end = hex.index(start, offsetBy: min(8, hex.count - $0))
                return String(hex[start..<end])
            }

            generating = false
        }
    }

    private func encodePairingPayload(pubkey: Data) -> String {
        // W359: switch from the iOS-only JSON shape to the cross-
        // platform DeviceLinkingProtocol QR. Android, Desktop, and
        // iOS all share `qaudion://link/<base64url(pub|userIdLen|
        // userId|oneTimeCode)>` so a single QR is scannable on every
        // platform.
        let proto = DeviceLinkingProtocol()
        // Use the current authenticated user id; fall back to a synth
        // for unauthenticated previews so the QR still renders.
        let userId = UserDefaults.standard.string(forKey: "currentUserId")
            ?? UUID().uuidString
        let qr = proto.generateLinkQr(userId: userId, devicePubKey: pubkey)
        return proto.encodeLinkQr(qr)
    }

    private func generateQrImage(content: String) -> UIImage? {
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
}

#Preview {
    NavigationStack {
        LinkNewDeviceScreen()
    }
    .qAudionTheme(dark: true)
}

import SwiftUI
import CoreImage.CIFilterBuiltins

/// W52: sheet "Invita via QR" che presenta un QR-code con il payload
/// `qaudion-group-invite` (groupId + groupName + protocol version).
/// Un peer scansiona il QR con la fotocamera dal proprio dispositivo
/// e si auto-aggiunge al gruppo. Engine wiring per la handshake serverside
/// (`POST /groups/:id/join`) è deferred — oggi il QR è generato pure-locale
/// e mostrato; il routing del payload scansionato passa per
/// `QrPayloadRouter` esistente.
///
/// Pattern parallelo a `LinkNewDeviceScreen.swift` (W41) che genera un
/// QR per il device-link X25519. Qui il QR ha contenuto JSON, non
/// crittograficamente sensibile (il groupId è già pubblico una volta
/// che un membro lo conosce — l'enforcement vero del controllo accesso
/// avviene server-side al momento del join).
struct GroupInviteQrSheet: View {
    let groupId: UUID
    let groupName: String

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type
    @Environment(\.qaudionSnackbar) private var snackbar
    @Environment(\.dismiss) private var dismiss

    @State private var qrImage: UIImage? = nil
    @State private var payload: String = ""

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                header
                instructionsCard
                qrCard
                metadataCard
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
        }
        .onAppear { generate() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Invita via QR")
                    .qaudionStyle(type.titleMedium)
                    .foregroundStyle(scheme.onSurface)
                Text(groupName)
                    .qaudionStyle(type.bodySmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .lineLimit(1)
            }
            Spacer()
            Button("Chiudi") { dismiss() }
                .foregroundStyle(scheme.primary)
        }
    }

    // MARK: - Instructions

    private var instructionsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ISTRUZIONI")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(scheme.primary)
            Text("Il peer apre Q-Audion → Contatti → \"Aggiungi via QR\" e inquadra questo codice. Si auto-aggiungerà al gruppo dopo la verifica dell'admin.")
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurface)
            Text("Il QR contiene solo l'ID del gruppo + il nome. Nessuna chiave crittografica passa via QR.")
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
        if let qr = qrImage {
            Image(uiImage: qr)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 240, height: 240)
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 8).fill(.white)
                )
                .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 10) {
                ProgressView().progressViewStyle(.circular)
                    .tint(scheme.primary)
                Text("Generazione QR…")
                    .qaudionStyle(type.bodySmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity, minHeight: 240)
        }
    }

    // MARK: - Metadata

    private var metadataCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DETTAGLI INVITO")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(scheme.primary)
            HStack(spacing: 10) {
                Text("groupId")
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .frame(width: 80, alignment: .leading)
                Text(groupId.uuidString)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(scheme.onSurface)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button {
                    UIPasteboard.general.string = groupId.uuidString
                    snackbar?.show(.init(text: "ID gruppo copiato.", severity: .info))
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(scheme.surfaceVariant.opacity(0.5))
        )
    }

    // MARK: - QR generation

    private func generate() {
        // W53: encode via GroupInviteQrCode → URL `qaudion://group-invite/<base64-json>`.
        // Schema URL consistente con DeviceLinkBinaryQR / FastSetupQrCode,
        // così il QrPayloadRouter dispatcha il payload via host-match.
        let url = GroupInviteQrCode.encode(.init(groupId: groupId,
                                                 groupName: groupName))
        payload = url.absoluteString
        qrImage = renderQr(content: payload)
    }

    private func renderQr(content: String) -> UIImage? {
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
    GroupInviteQrSheet(groupId: UUID(),
                       groupName: "Team Sicurezza")
        .qAudionTheme(dark: true)
}

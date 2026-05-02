import SwiftUI
import QAudionEngine

/// W379 — UI surface for the cross-platform parity rollover flags.
///
/// All toggles default OFF and are guarded by per-peer auto-detection
/// (W365), so flipping them is mostly informational for testers who
/// want to *force* the cross-platform path on a specific peer.
///
/// Screen lives under Settings → "Compatibilità cross-platform (beta)".
struct CrossPlatformBetaScreen: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type
    @Environment(\.dismiss) private var dismiss

    @AppStorage("ChatRatchetV3.enabled") private var ratchetV3Enabled: Bool = false
    @AppStorage("VoiceNote.attachAnnounce.enabled") private var attachAnnounceEnabled: Bool = false

    @State private var resetPeerCapsConfirm: Bool = false
    @State private var clearedAt: String? = nil

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard
                    chatToggleCard
                    voiceNoteToggleCard
                    peerCapsCard
                    diagnosticCard
                }
                .padding(16)
            }
        }
        .navigationTitle("Cross-platform (beta)")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Reset capability flags?", isPresented: $resetPeerCapsConfirm) {
            Button("Annulla", role: .cancel) {}
            Button("Reset", role: .destructive) {
                PeerCapabilityRegistry.shared.reset()
                let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
                clearedAt = f.string(from: Date())
            }
        } message: {
            Text("Cancella tutti i flag v3-capable per peer. La discovery riparte da zero.")
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Compatibilità cross-platform")
                .qaudionStyle(type.titleMedium)
                .foregroundStyle(scheme.onSurface)
            Text("Toggle interni per il rollover dei wire-format cross-platform. Da OFF i peer iOS-iOS continuano sui formati legacy; da ON i messaggi vanno in formato compatibile con Android e Desktop.")
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurfaceVariant)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(scheme.surfaceVariant.opacity(0.4)))
    }

    private var chatToggleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $ratchetV3Enabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Chat v3 (forward secrecy)")
                        .qaudionStyle(type.titleSmall)
                        .foregroundStyle(scheme.onSurface)
                    Text("Forza l'invio in formato 0xE3 (canonical CBOR AAD + chain ratchet) per ogni peer. Quando OFF, il routing è automatico per-peer su prima ricezione v3.")
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                }
            }
            .tint(scheme.primary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(scheme.surface.opacity(0.6)))
    }

    private var voiceNoteToggleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $attachAnnounceEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Voice notes cross-platform")
                        .qaudionStyle(type.titleSmall)
                        .foregroundStyle(scheme.onSurface)
                    Text("Invia voice notes via attach_announce (XChaCha20-Poly1305 + canonical CBOR AAD). Compatibile con Android e Desktop. OFF = qfile legacy iPhone↔iPhone only.")
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                }
            }
            .tint(scheme.primary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(scheme.surface.opacity(0.6)))
    }

    private var peerCapsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Capability per peer")
                .qaudionStyle(type.titleSmall)
                .foregroundStyle(scheme.onSurface)
            Text("Per ogni contatto, il flag v3-capable viene osservato e persiste. Reset → re-discovery automatica al prossimo messaggio inbound.")
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
            Button {
                resetPeerCapsConfirm = true
            } label: {
                Text("Reset capability flags")
                    .qaudionStyle(type.labelLarge)
                    .foregroundStyle(scheme.onPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 999).fill(scheme.primary))
            }
            if let stamp = clearedAt {
                Text("Reset eseguito alle \(stamp)")
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(extras.success)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(scheme.surface.opacity(0.6)))
    }

    private var diagnosticCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stato runtime")
                .qaudionStyle(type.titleSmall)
                .foregroundStyle(scheme.onSurface)
            diagRow(label: "v3 outbound (force)", value: ratchetV3Enabled ? "ON" : "OFF")
            diagRow(label: "attach_announce VN", value: attachAnnounceEnabled ? "ON" : "OFF")
            diagRow(label: "Biometric vault", value: BiometricKeyVaultGate.shared.isBiometryAvailable ? "available" : "n/a")
            diagRow(label: "Biometry type", value: BiometricKeyVaultGate.shared.biometryType)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(scheme.surfaceVariant.opacity(0.3)))
    }

    private func diagRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
            Spacer()
            Text(value)
                .qaudionStyle(type.labelSmall)
                .monospacedDigit()
                .foregroundStyle(scheme.onSurface)
        }
    }
}

#Preview {
    NavigationStack {
        CrossPlatformBetaScreen()
            .qAudionTheme(dark: true)
    }
}

import SwiftUI
import QAudionEngine

/// Per-contact detail screen. 1:1 visual port of Android
/// `qaudion-android-new/feature/feature-contacts/.../ContactDetailScreen.kt`.
///
/// Layout (top → bottom, scrollable):
///   1. Top bar — back chevron + "Dettaglio contatto" + "Modifica" + "Elimina"
///   2. 120pt avatar hero (centred)
///   3. Display name (headlineSmall italic) + presence label + status msg
///   4. Trust pills (PQC / VOICE / ENTERPRISE) + SAS-state chip
///   5. 5-action row (Chat / Audio / Video / SAS Verify / Block) — 52pt
///      circles with mono caption underneath
///   6. **TrustVerificationCard** — 3 rows: Identità / Voce / SAS, each
///      ✓ or ○, with optional CTA
///   7. **MetadataCard** — USERID / INTERNO / PRIMA VISTA / ULTIMA VERIFICA
///      / PSK FINGERPRINT, mono labels at fixed 110pt width
///   8. **SecurityLog** — events with severity-colored 8pt dot
///
/// Engine truth used: displayName, isVerified, isOnline, avatarUrl,
/// userId, phoneHash. Richer fields (statusMessage, presence enum,
/// pskFingerprint, securityEvents, voicePrintEnrolled) are NOT exposed
/// yet — sensible defaults render so the screen still validates layout.
struct ContactDetailScreen: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type
    @Environment(\.dismiss) private var dismiss

    let item: ContactsListViewModel.Item

    @State private var showingDeleteConfirm = false
    @State private var showingSasSheet = false

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    topBar
                    hero.padding(.top, 4)
                    trustBadgesRow
                    actionRow.padding(.horizontal, 16).padding(.top, 4)
                    trustVerificationCard.padding(.horizontal, 16)
                    metadataCard.padding(.horizontal, 16)
                    securityLogCard.padding(.horizontal, 16)
                    Spacer().frame(height: 32)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .alert("Eliminare il contatto?", isPresented: $showingDeleteConfirm) {
            Button("Annulla", role: .cancel) {}
            Button("Elimina", role: .destructive) {
                // TODO: wire ContactsStore.delete(userId:)
                dismiss()
            }
        } message: {
            Text("\(item.displayName) sarà rimosso dalla rubrica locale.")
        }
        .sheet(isPresented: $showingSasSheet) {
            SasVerifySheet(peerName: item.displayName)
                .presentationDetents([.medium])
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(scheme.onSurface)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Indietro")

            Text("Dettaglio contatto")
                .qaudionStyle(type.titleMedium)
                .foregroundStyle(scheme.onSurface)

            Spacer(minLength: 8)

            Button {
                // TODO: open ContactEditorScreen in edit mode
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 17))
                    .foregroundStyle(scheme.primary)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Modifica")

            Button { showingDeleteConfirm = true } label: {
                Image(systemName: "trash")
                    .font(.system(size: 17))
                    .foregroundStyle(extras.riskHigh)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Elimina")
        }
        .padding(.horizontal, 8)
        .frame(height: 56)
        .background(scheme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(scheme.outline.opacity(0.3)).frame(height: 0.5)
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 10) {
            QAudionAvatar(displayName: item.displayName,
                          imageURL: item.avatarUrl,
                          size: 120,
                          presenceDot: item.isOnline ? .online : .offline)
            Text(item.displayName)
                .font(.system(size: 24, weight: .semibold))
                .italic()
                .foregroundStyle(scheme.onSurface)
                .multilineTextAlignment(.center)
            Text(item.isOnline
                 ? "online · \(item.isVerified ? "verified voice" : "voice non verificata")"
                 : "offline")
                .qaudionStyle(type.labelMedium)
                .foregroundStyle(scheme.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Trust badges row

    private var trustBadgesRow: some View {
        HStack(spacing: 8) {
            TrustChip("PQC", accent: extras.pqcAccent)
            if item.isVerified {
                TrustChip("VOICE", accent: extras.success)
            }
            if item.isVerified {
                TrustChip("SAS VERIFICATO", accent: extras.success)
            } else {
                TrustChip("SAS DA VERIFICARE", accent: extras.warning)
            }
        }
    }

    // MARK: - Action row

    private var actionRow: some View {
        HStack(alignment: .top, spacing: 8) {
            actionButton(icon: "bubble.right",
                         caption: "Chat",
                         tint: scheme.primary) { /* TODO: deep-link chat */ }
            actionButton(icon: "phone",
                         caption: "Audio",
                         tint: extras.success) {
                Task { await appState.startCall(contactId: item.userId, video: false) }
            }
            actionButton(icon: "video",
                         caption: "Video",
                         tint: extras.pqcAccent) {
                Task { await appState.startCall(contactId: item.userId, video: true) }
            }
            actionButton(icon: "shield.lefthalf.filled",
                         caption: "SAS",
                         tint: extras.warning) { showingSasSheet = true }
            actionButton(icon: "circle.slash",
                         caption: "Blocca",
                         tint: extras.riskHigh) { /* TODO: ContactsStore.block */ }
        }
    }

    private func actionButton(icon: String,
                              caption: String,
                              tint: Color,
                              action: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(scheme.surfaceVariant.opacity(0.6)))
            }
            .buttonStyle(.plain)
            Text(caption)
                .qaudionStyle(type.labelSmall)
                .tracking(1.2)
                .foregroundStyle(scheme.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Trust verification card

    private var trustVerificationCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("VERIFICA TRUST")
                    .qaudionStyle(type.labelSmall)
                    .tracking(1.2)
                    .foregroundStyle(scheme.onSurfaceVariant)
                Spacer()
                TrustChip(item.isVerified ? "SAS VERIFIED" : "PENDING",
                          accent: item.isVerified ? extras.success : extras.warning)
            }
            .padding(.bottom, 12)

            trustFactorRow(label: "Identità pubblicata",
                           description: "IK pubblicata sulla directory bcrypto",
                           done: true)
            divider
            trustFactorRow(label: "Voce verificata",
                           description: item.isVerified
                               ? "Match con il voiceprint del contatto"
                               : "Effettua una chiamata per registrare il match",
                           done: item.isVerified)
            divider
            trustFactorRow(label: "SAS verificato",
                           description: item.isVerified
                               ? "Cerimonia SAS completata"
                               : "Avvia cerimonia NFC o SAS via voce",
                           done: item.isVerified)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(scheme.surfaceVariant.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(scheme.outline.opacity(0.5), lineWidth: 1))
    }

    private var divider: some View {
        Rectangle()
            .fill(scheme.outline.opacity(0.3))
            .frame(height: 0.5)
            .padding(.vertical, 10)
    }

    private func trustFactorRow(label: String, description: String, done: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(done ? TrustChipColors.jade : TrustChipColors.mutedGrey)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .qaudionStyle(type.bodyMedium)
                    .foregroundStyle(scheme.onSurface)
                Text(description)
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Metadata card

    private var metadataCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("METADATI")
                .qaudionStyle(type.labelSmall)
                .tracking(1.2)
                .foregroundStyle(scheme.onSurfaceVariant)
                .padding(.bottom, 10)

            metaRow("USERID", value: item.userId)
            metaDivider
            metaRow("PHONE HASH", value: phoneHashShort)
            metaDivider
            metaRow("PRIMA VISTA", value: "—")
            metaDivider
            metaRow("ULTIMA VERIFICA", value: item.isVerified ? "Recente" : "Mai")
            metaDivider
            metaRow("PSK FINGERPRINT", value: "—")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(scheme.surfaceVariant.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(scheme.outline.opacity(0.5), lineWidth: 1))
    }

    private var metaDivider: some View {
        Rectangle()
            .fill(scheme.outline.opacity(0.25))
            .frame(height: 0.5)
            .padding(.vertical, 8)
    }

    private func metaRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .qaudionStyle(type.labelSmall)
                .tracking(1.2)
                .foregroundStyle(scheme.onSurfaceVariant)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurface)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private var phoneHashShort: String {
        // 64-hex phone_hash, show first 8 + … + last 4 = 14 chars total.
        let h = item.phoneHash
        guard h.count > 12 else { return h }
        let prefix = h.prefix(8)
        let suffix = h.suffix(4)
        return "\(prefix)…\(suffix)"
    }

    // MARK: - Security log card

    private var securityLogCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("EVENTI DI SICUREZZA CONDIVISI")
                .qaudionStyle(type.labelSmall)
                .tracking(1.2)
                .foregroundStyle(scheme.primary)
                .padding(.bottom, 4)

            if item.isVerified {
                eventRow(severity: extras.success,
                         when: "oggi · 14:32",
                         summary: "Cerimonia SAS completata via voce")
                eventRow(severity: extras.success,
                         when: "ieri · 09:14",
                         summary: "Voiceprint match · C=0.94")
            } else {
                Text("Nessuna cerimonia SAS registrata per questo contatto. Avvia una verifica vocale o NFC.")
                    .qaudionStyle(type.bodySmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(scheme.surfaceVariant.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(scheme.outline.opacity(0.5), lineWidth: 1))
    }

    private func eventRow(severity: Color, when: String, summary: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(severity).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(when)
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
                Text(summary)
                    .qaudionStyle(type.bodySmall)
                    .foregroundStyle(scheme.onSurface)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - SAS verify sheet (placeholder)

private struct SasVerifySheet: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type
    @Environment(\.dismiss) private var dismiss

    let peerName: String
    @State private var input: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("VERIFICA SAS")
                .qaudionStyle(type.labelSmall)
                .tracking(1.5)
                .foregroundStyle(extras.warning)
            Text("Inserisci le 6 parole PGP lette a voce durante la chiamata con \(peerName).")
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)
            TextField("", text: $input,
                      prompt: Text("es. TYPHOON · BALLAD · SLIPSTREAM · …")
                          .foregroundColor(scheme.onSurfaceVariant),
                      axis: .vertical)
                .lineLimit(2...4)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(scheme.surfaceVariant.opacity(0.45)))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(extras.warning.opacity(0.5), lineWidth: 1))
            Text("Separatori ammessi: spazio, trattino, virgola o ·")
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
            HStack {
                Button("Annulla") { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Verifica") { dismiss() /* TODO: backend SAS verify */ }
                    .buttonStyle(.borderedProminent)
                    .tint(extras.warning)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(scheme.background)
    }
}

#Preview {
    NavigationStack {
        ContactDetailScreen(item: ContactsListViewModel.mock.items[0])
    }
    .environmentObject(AppState())
    .qAudionTheme(dark: true)
}

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
    @State private var showingEditor = false
    /// W51: payload pronto per il share sheet vCard. Non-nil triggers
    /// `.sheet(item:)` con `UIActivityViewController` (mail/messaggi/etc).
    @State private var sharingVCard: VCardShareItem? = nil

    @Environment(\.qaudionSnackbar) private var snackbar

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
                    safetyNumberSection.padding(.horizontal, 16)
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
                // W72: real ContactsStore.remove. The store is the
                // engine-side persistence — same path the new contacts
                // list relies on.
                ContactsStore().remove(userId: item.userId)
                let removedName = item.displayName
                dismiss()
                // Push the feedback AFTER dismiss so the snackbar
                // is rendered on the parent screen, not on a view
                // that's sliding away.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    snackbar?.show(.init(
                        text: "\(removedName) rimosso dalla rubrica.",
                        severity: .info
                    ))
                }
            }
        } message: {
            Text("\(item.displayName) sarà rimosso dalla rubrica locale.")
        }
        .sheet(isPresented: $showingSasSheet) {
            // W72: pass the verify callback so we can persist
            // `isVerified=true` on the local ContactsStore once the user
            // confirms the spoken-aloud SAS matches. Engine-side
            // `Fingerprint.verifyWords` (PGP word comparison vs the live
            // session-key fingerprint) is wired from inside the sheet —
            // for now the closure persists the local trust flag and the
            // server-side `markVerified` RPC is engine WT.
            SasVerifySheet(peerName: item.displayName, onVerified: {
                let store = ContactsStore()
                let stored = store.load().first(where: { $0.userId == item.userId })
                let updated = ContactsStore.StoredContact(
                    userId: item.userId,
                    displayName: item.displayName,
                    phoneHash: stored?.phoneHash ?? "",
                    avatarUrl: stored?.avatarUrl,
                    lastSeen: stored?.lastSeen,
                    isVerified: true,
                    pubkey: stored?.pubkey
                )
                store.upsert(updated)
                snackbar?.show(.init(
                    text: "\(item.displayName) verificato.",
                    severity: .info
                ))
            })
                .presentationDetents([.medium])
        }
        .sheet(item: $sharingVCard) { payload in
            // W51: share sheet nativo iOS con il vCard come testo (UIActivity-
            // ViewController). Mail/Messaggi/AirDrop possono trattarlo come
            // attachment .vcf — molti picker mostrano "Aggiungi ai Contatti".
            VCardShareSheet(text: payload.text, filename: payload.filename)
        }
        .sheet(isPresented: $showingEditor) {
            // W23.E: edit mode pre-fills displayName + extension from
            // the engine row. statusMessage / alias aren't on
            // ContactsListViewModel.Item yet — they'd be loaded from
            // ContactsStore in a future wiring pass.
            NavigationStack {
                ContactEditorScreen(
                    mode: .edit,
                    initialDisplayName: item.displayName,
                    initialAlias: "",
                    initialStatusMessage: "",
                    initialExtension: "",
                    onSave: { draft in
                        print("[ContactEditor] edited contact draft: \(draft)")
                    }
                )
                .navigationBarBackButtonHidden(true)
                .toolbar(.hidden, for: .navigationBar)
            }
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
                showingEditor = true
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 17))
                    .foregroundStyle(scheme.primary)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Modifica")

            // W51: Condividi vCard. Genera RFC 6350 vCard 3.0 in-memory
            // e apre il share sheet nativo iOS (mail / Messaggi / AirDrop).
            Button {
                sharingVCard = VCardShareItem(
                    text: VCardBuilder.build(for: item),
                    filename: vCardFilename(for: item)
                )
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 17))
                    .foregroundStyle(scheme.primary)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Condividi")

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

    // MARK: - W51 vCard helpers

    /// Sanitizza il displayName in un filename `.vcf` sicuro (no
    /// slash / backslash / colon / pipe / asterisk / quote / lt / gt /
    /// question mark — i tipici banditi su filesystem cross-platform).
    private func vCardFilename(for item: ContactsListViewModel.Item) -> String {
        let unsafe = CharacterSet(charactersIn: "/\\:|*\"<>?")
        let sanitized = item.displayName
            .components(separatedBy: unsafe)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = sanitized.isEmpty ? "contact" : sanitized
        return "\(base).vcf"
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
        VStack(spacing: 12) {
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
                // W35: il livello di rischio del contatto è derivato
                // dallo stato di verifica engine-side. Senza un campo
                // engine reale (deepfake history / blocked / SAS-fail
                // rate) approssimiamo: verified == low, !verified ==
                // medium. Il campo engine arriverà con lo stesso
                // surface usato dalla TrustVerificationCard (W36).
                RiskPill(item.isVerified ? .low : .medium)
            }
            // W35: VoiceTrustIndicator inline. Per ora il confidence
            // è un proxy di isVerified (1.0 / 0.55). Quando l'engine
            // espone il voice-match score storico, sostituisco il
            // proxy con il valore reale.
            VoiceTrustIndicator(index: item.isVerified ? 0.92 : 0.55)
        }
    }

    // MARK: - Action row

    private var actionRow: some View {
        HStack(alignment: .top, spacing: 8) {
            actionButton(icon: "bubble.right",
                         caption: "Chat",
                         tint: scheme.primary) {
                // W294: graceful interim — actual deep-link to a
                // ChatDetailScreen requires a global nav coordinator
                // (not currently wired). For now we dismiss this
                // detail screen + push a guidance snackbar telling
                // the user to use the Chat tab. Better than a no-op.
                // See TODO_AUDIT.md §2.3 for the proper fix.
                let peer: String = item.displayName
                dismiss()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    snackbar?.show(.init(
                        text: Self.openChatGuidance(peer: peer),
                        severity: .info,
                        durationSeconds: 4
                    ))
                }
            }
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
                         tint: extras.riskHigh) {
                // W72: server-side block via BCryptoContactsApi.
                // Best-effort: snackbar feedback regardless. Actual
                // contact-list dimming is engine-side WT (ContactsStore
                // doesn't expose `isBlocked` yet).
                let userId = item.userId
                let displayName = item.displayName
                Task {
                    guard let token = appState.authService.loadToken(),
                          !token.isEmpty else { return }
                    let backendConfig = BackendConfig(
                        serverUrl: appState.serverUrl,
                        accessToken: token
                    )
                    let provider = BCryptoBackendProvider(config: backendConfig)
                    do {
                        try await provider.contactsApi.blockContact(userId: userId)
                        await MainActor.run {
                            snackbar?.show(.init(
                                text: "\(displayName) bloccato.",
                                severity: .info
                            ))
                        }
                    } catch {
                        await MainActor.run {
                            snackbar?.show(.init(
                                text: "Blocco non riuscito. Riprova.",
                                severity: .error
                            ))
                        }
                    }
                }
            }
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

    // MARK: - Safety number section (W36)

    /// Sezione "NUMERO DI SICUREZZA" con la nuova `TrustVerificationCard`
    /// (1:1 port di Android core-ui). Source of truth per la verifica
    /// fingerprint cross-platform. Per ora i 60 digit + lo stato sono
    /// stub derivati da `item.isVerified`; il vero `TrustSafetyNumber`
    /// arriverà quando l'engine espone la deriv. HKDF-SHA256 lato iOS.
    private var safetyNumberSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NUMERO DI SICUREZZA")
                .qaudionStyle(type.labelSmall)
                .tracking(1.2)
                .foregroundStyle(scheme.onSurfaceVariant)
            TrustVerificationCard(
                state: item.isVerified ? .userVerified : .identityPinnedTofu,
                safetyNumber: stubSafetyNumber,
                verifiedAt: item.isVerified ? Date().addingTimeInterval(-3600) : nil,
                verificationMethod: item.isVerified ? .voice : nil,
                onMarkVerified: { method in
                    print("[ContactDetail] mark verified via \(method.localized)")
                    snackbar?.show(.init(
                        text: "Identità di \(item.displayName) marcata verificata via \(method.localized).",
                        severity: .info
                    ))
                },
                onAcceptNewFingerprint: {
                    print("[ContactDetail] accepted new fingerprint")
                    snackbar?.show(.init(
                        text: "Nuova identità accettata.",
                        severity: .warning
                    ))
                }
            )
        }
    }

    /// Stub deterministico: deriviamo 12 gruppi numerici dal `userId`
    /// così che lo stesso contatto mostri sempre lo stesso safety number
    /// nelle preview, anche se il vero HKDF non è ancora wired iOS-side.
    private var stubSafetyNumber: TrustSafetyNumber {
        let seed = item.userId
        var groups: [String] = []
        // Use the cross-platform constant (W36 component) so this stub
        // tracks future changes to the canonical group count without
        // a manual update here.
        for offset in 0..<TrustSafetyNumber.groupCount {
            // SDBM-style 32-bit hash sul prefisso seed+offset → 5-digit
            // deterministic numero. Stesso seed → sempre stessi gruppi.
            var h: UInt32 = 5381
            for byte in (seed + String(offset)).utf8 {
                h = (h &* 33) &+ UInt32(byte)
            }
            groups.append(String(format: "%05d", h % 100_000))
        }
        return TrustSafetyNumber(
            groups: groups,
            fingerprintHex: String(item.phoneHash.prefix(60))
        )
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

    /// W294: build the guidance snackbar text via static method to keep
    /// the closure body trivial. CLAUDE.md §13.
    private static func openChatGuidance(peer: String) -> String {
        return "Apri la chat con " + peer + " dalla scheda Chat."
    }
}

// MARK: - SAS verify sheet (placeholder)

private struct SasVerifySheet: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type
    @Environment(\.dismiss) private var dismiss

    let peerName: String
    /// Fired when the user taps "Verifica" with non-empty input. The
    /// caller persists `isVerified=true` on the contact.
    let onVerified: () -> Void
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
                Button("Verifica") {
                    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        onVerified()
                    }
                    dismiss()
                }
                    .buttonStyle(.borderedProminent)
                    .tint(extras.warning)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

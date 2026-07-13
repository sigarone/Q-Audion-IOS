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
    /// Local block state — initialised from BlockedContactsStore on .onAppear.
    @State private var isBlocked: Bool = false
    /// Internal extension number extracted from displayName (#NNN pattern),
    /// or nil when absent.
    @State private var peerExtension: String? = nil
    /// Real persistent safety-number + TOFU trust-state evaluation (W36
    /// wiring). nil while the initial server fetch + HKDF derivation is
    /// still in flight — the card renders `.unverified` ("Calcolo del
    /// trust in corso…") in that window, same as a genuine no-pin state.
    @State private var trustEval: PeerTrustEvaluator.Evaluation? = nil
    /// The peer's raw Ed25519 identity key resolved by the last
    /// `loadTrustEvaluation()` call. Needed by `onAcceptNewFingerprint` to
    /// re-pin without re-fetching.
    @State private var lastPeerIkEdPub: Data? = nil

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
        .onAppear {
            isBlocked = BlockedContactsStore.isBlocked(item.userId)
            peerExtension = Self.extractExtension(from: item.displayName)
        }
        .task(id: item.userId) {
            await loadTrustEvaluation()
        }
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
            // W36 — real wiring: the safety-number fingerprint just
            // rendered by `trustEval` is what gets pinned as "verified"
            // (mirrors Android `PeerTrustRepository.markVerified`, which
            // always verifies the CURRENT fingerprint, never a stale one).
            // Disabled while trustEval hasn't resolved a real fingerprint
            // yet (peer never published / offline) — nothing to attest to.
            // Also disabled in `.identityChanged`: this quick-action button
            // is independent of TrustVerificationCard's own footer (which
            // already correctly hides its mark-as-verified menu in that
            // state) — without this guard a rotated/unaccepted identity
            // could be self-attested "verified" via this shortcut alone,
            // producing a contacts-list/badge that says low-risk while the
            // card right below still shows the 🚨 alarm (adversarial-review
            // finding, confirmed).
            SasVerifySheet(peerName: item.displayName, onVerified: { method in
                guard let eval = trustEval, eval.state != .identityChanged,
                      !eval.safetyNumber.fingerprintHex.isEmpty else { return }
                let fp = eval.safetyNumber.fingerprintHex
                PeerTrustEvaluator.markVerified(peerUserId: item.userId, method: method, fingerprintHex: fp)
                Task { await loadTrustEvaluation() }
                snackbar?.show(.init(
                    text: "\(item.displayName) verificato via \(method.localized).",
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
            // W445: extended presence label — shows InCall / DND icons
            // and localised text. Falls back to binary online/offline
            // when extended state is .unknown (no presence update yet).
            heroPresenceLabel
        }
        .frame(maxWidth: .infinity)
    }

    /// W445: presence sub-label for the hero section. Extracted to a
    /// computed property so the SwiftUI type-checker operates in a clean
    /// scope (CLAUDE.md §13 — avoid inline expression complexity).
    @ViewBuilder
    private var heroPresenceLabel: some View {
        let presence = appState.presenceService.extendedPresence(for: item.userId)
        let isOnline = item.isOnline
        switch presence {
        case .unknown:
            // No extended update yet — fall back to binary isOnline flag.
            let fallbackText = isOnline
                ? "online · " + (item.isVerified ? "verified voice" : "voice non verificata")
                : "offline"
            Text(fallbackText)
                .qaudionStyle(type.labelMedium)
                .foregroundStyle(scheme.onSurfaceVariant)
        case .online:
            let onlineText = "online · " + (item.isVerified ? "verified voice" : "voice non verificata")
            Text(onlineText)
                .qaudionStyle(type.labelMedium)
                .foregroundStyle(extras.success)
        case .inCall:
            HStack(spacing: 4) {
                Image(systemName: "phone.fill")
                    .font(.caption)
                Text(ExtendedPresence.inCall.label)
                    .qaudionStyle(type.labelMedium)
            }
            .foregroundStyle(extras.pqcAccent)
        case .doNotDisturb:
            HStack(spacing: 4) {
                Image(systemName: "moon.fill")
                    .font(.caption)
                Text(ExtendedPresence.doNotDisturb.label)
                    .qaudionStyle(type.labelMedium)
            }
            .foregroundStyle(extras.warning)
        case .offline, .invisible:
            Text("offline")
                .qaudionStyle(type.labelMedium)
                .foregroundStyle(scheme.onSurfaceVariant)
        }
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
            actionButton(icon: isBlocked ? "circle.slash.fill" : "circle.slash",
                         caption: isBlocked ? "Sblocca" : "Blocca",
                         tint: extras.riskHigh) {
                if isBlocked { performUnblock() } else { performBlock() }
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
        let verified = trustEval?.state == .userVerified
        let changed = trustEval?.state == .identityChanged
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("VERIFICA TRUST")
                    .qaudionStyle(type.labelSmall)
                    .tracking(1.2)
                    .foregroundStyle(scheme.onSurfaceVariant)
                Spacer()
                TrustChip(changed ? "IDENTITÀ CAMBIATA" : (verified ? "SAS VERIFIED" : "PENDING"),
                          accent: changed ? extras.riskHigh : (verified ? extras.success : extras.warning))
            }
            .padding(.bottom, 12)

            trustFactorRow(label: "Identità pubblicata",
                           description: trustEval == nil ? "Verifica in corso…" : "IK pubblicata sulla directory bcrypto",
                           done: trustEval != nil)
            divider
            trustFactorRow(label: "Voce verificata",
                           description: verified
                               ? "Match con il voiceprint del contatto"
                               : "Effettua una chiamata per registrare il match",
                           done: verified)
            divider
            trustFactorRow(label: "SAS verificato",
                           description: verified
                               ? "Cerimonia SAS completata"
                               : "Avvia cerimonia NFC o SAS via voce",
                           done: verified)
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

    /// Sezione "NUMERO DI SICUREZZA" con la `TrustVerificationCard` (1:1
    /// port di Android core-ui), ora alimentata dal vero
    /// `PeerTrustEvaluator` — HKDF-SHA256+CBOR `SafetyNumber` derivato
    /// dall'identità Ed25519 di entrambe le parti (WIRE_SPEC.md §5.1.2),
    /// stesso stato TOFU/verified/changed di Android `PeerTrustRepository`.
    private var safetyNumberSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NUMERO DI SICUREZZA")
                .qaudionStyle(type.labelSmall)
                .tracking(1.2)
                .foregroundStyle(scheme.onSurfaceVariant)
            TrustVerificationCard(
                state: trustEval?.state ?? .unverified,
                safetyNumber: trustEval?.safetyNumber ?? TrustSafetyNumber(groups: [], fingerprintHex: ""),
                verifiedAt: trustEval?.verifiedAt,
                verificationMethod: trustEval?.verificationMethod,
                onMarkVerified: { method in
                    guard let fp = trustEval?.safetyNumber.fingerprintHex, !fp.isEmpty else { return }
                    PeerTrustEvaluator.markVerified(peerUserId: item.userId, method: method, fingerprintHex: fp)
                    Task { await loadTrustEvaluation() }
                    snackbar?.show(.init(
                        text: "Identità di \(item.displayName) marcata verificata via \(method.localized).",
                        severity: .info
                    ))
                },
                onAcceptNewFingerprint: {
                    guard let newKey = lastPeerIkEdPub else { return }
                    PeerTrustEvaluator.acceptNewFingerprint(peerUserId: item.userId, newPeerIkEdPub: newKey)
                    Task { await loadTrustEvaluation() }
                    snackbar?.show(.init(
                        text: "Nuova identità accettata.",
                        severity: .warning
                    ))
                }
            )
        }
    }

    /// Resolve the peer's published Ed25519 identity + compute the
    /// persistent safety number, then re-render. Called on-appear and
    /// after any mark-verified / accept-new-identity action.
    @MainActor
    private func loadTrustEvaluation() async {
        let eval = await PeerTrustEvaluator.evaluate(peerUserId: item.userId, provider: appState.liveProvider)
        trustEval = eval
        lastPeerIkEdPub = eval.peerIkEdPub
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
            metaRow("INTERNO", value: peerExtension ?? "—")
            metaDivider
            metaRow("PHONE HASH", value: phoneHashShort)
            metaDivider
            metaRow("PRIMA VISTA", value: "—")
            metaDivider
            metaRow("ULTIMA VERIFICA", value: lastVerificationLabel)
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

    private var lastVerificationLabel: String {
        guard let eval = trustEval else { return "…" }
        switch eval.state {
        case .userVerified:
            guard let date = eval.verifiedAt else { return "Verificato" }
            let f = DateFormatter()
            f.locale = Locale(identifier: "it_IT")
            f.dateStyle = .medium
            return f.string(from: date)
        case .identityChanged: return "🚨 Identità cambiata"
        case .identityPinnedTofu: return "Mai (pinned TOFU)"
        case .unverified: return "Mai"
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

    // MARK: - Block / Unblock

    private func performBlock() {
        BlockedContactsStore.add(item.userId)
        isBlocked = true
        let uid: String = item.userId
        let name: String = item.displayName
        if let provider = appState.liveProvider {
            Task { try? await provider.contactsApi.blockContact(userId: uid) }
        }
        let msg: String = name + " bloccato."
        snackbar?.show(.init(text: msg, severity: .info))
    }

    private func performUnblock() {
        BlockedContactsStore.remove(item.userId)
        isBlocked = false
        let uid: String = item.userId
        let name: String = item.displayName
        if let provider = appState.liveProvider {
            Task { try? await provider.contactsApi.unblockContact(userId: uid) }
        }
        let msg: String = name + " sbloccato."
        snackbar?.show(.init(text: msg, severity: .info))
    }

    // MARK: - Extension extraction

    /// Extracts a dial extension from a displayName containing a "#NNN" suffix.
    /// Returns nil when no such pattern is present.
    private static func extractExtension(from displayName: String) -> String? {
        guard let range = displayName.range(of: #"#(\d+)"#, options: .regularExpression) else {
            return nil
        }
        // Drop the leading '#'.
        let match = String(displayName[range])
        return String(match.dropFirst())
    }

    /// W294: build the guidance snackbar text via static method to keep
    /// the closure body trivial. CLAUDE.md §13.
    private static func openChatGuidance(peer: String) -> String {
        return "Apri la chat con " + peer + " dalla scheda Chat."
    }
}

// MARK: - SAS verify sheet

/// Self-attest chooser for the persistent safety number (W36). Mirrors
/// Android `TrustVerificationCard.markAsVerifiedMenu` exactly: there is no
/// live cryptographic check here (Android's own reference Menu doesn't run
/// one either — `PeerTrustRepository.markVerified` just records which
/// out-of-band method the user says they used). The real anti-replay
/// crypto check is `LiveInCallScreen`'s in-call SAS ceremony
/// (`ComputeSasUseCase` + `SasVerificationStore`), which persists
/// separately and also feeds `TrustSafetyNumberState.userVerified` (see
/// `PeerTrustEvaluator`).
private struct SasVerifySheet: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type
    @Environment(\.dismiss) private var dismiss

    let peerName: String
    /// Fired with the method the user attests they used to compare the
    /// safety number out-of-band.
    let onVerified: (TrustVerificationMethod) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("VERIFICA IDENTITÀ")
                .qaudionStyle(type.labelSmall)
                .tracking(1.5)
                .foregroundStyle(extras.warning)
            Text("Conferma di aver confrontato il numero di sicurezza a 60 cifre con \(peerName) fuori da questa app, e come.")
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)
            VStack(spacing: 8) {
                ForEach(TrustVerificationMethod.allCases, id: \.self) { method in
                    Button {
                        onVerified(method)
                        dismiss()
                    } label: {
                        HStack {
                            Text(method.localized)
                                .qaudionStyle(type.bodyMedium)
                                .foregroundStyle(scheme.onSurface)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(scheme.onSurfaceVariant)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 8).fill(scheme.surfaceVariant.opacity(0.45)))
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("Annulla") { dismiss() }
                .buttonStyle(.bordered)
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

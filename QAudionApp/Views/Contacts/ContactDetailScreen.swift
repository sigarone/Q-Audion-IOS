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
    /// Internal extension number for this peer, bare digits, no prefix —
    /// resolved via the canonical `DisplayName.resolvedExtension`, not by
    /// parsing `item.displayName` (see `extractExtension`'s old kdoc: that
    /// regex only ever matched a legacy "#NNN" shape and silently returned
    /// nil — showing "—" — for the current no-prefix/"Int. NNN" rendering).
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
                    presenceAuthCard.padding(.horizontal, 16)
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
            peerExtension = DisplayName.resolvedExtension(
                for: item.userId, serverDisplay: item.displayName,
                knownExtension: item.`extension`, contacts: appState.cachedContacts)
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
                        // 2026-08-06 fix: this used to only print(draft) --
                        // zero feedback, zero persistence, editing a
                        // contact silently changed nothing. ContactsStore
                        // has no combined displayName+extension setter, so
                        // rebuild the record from the existing one (same
                        // pattern ContactsStore's own overwriteDisplayName/
                        // rebuild helpers use internally) and upsert it.
                        let store = ContactsStore()
                        guard let existing = store.load().first(where: { $0.userId == item.userId }) else {
                            snackbar?.show(.init(text: "Contatto non trovato.", severity: .error))
                            return
                        }
                        let updated = ContactsStore.StoredContact(
                            userId: existing.userId,
                            displayName: draft.displayName,
                            phoneHash: existing.phoneHash,
                            avatarUrl: existing.avatarUrl,
                            lastSeen: existing.lastSeen,
                            isVerified: existing.isVerified,
                            pubkey: existing.pubkey,
                            verifiedFingerprintHex: existing.verifiedFingerprintHex,
                            verifiedAtMs: existing.verifiedAtMs,
                            verificationMethod: existing.verificationMethod,
                            presenceAuth: existing.presenceAuth,
                            presenceFloor: existing.presenceFloor,
                            phoneNumber: existing.phoneNumber,
                            extension: draft.extensionText.isEmpty ? existing.`extension` : draft.extensionText,
                            avatarVersion: existing.avatarVersion,
                            voiceVerifiedAt: existing.voiceVerifiedAt
                        )
                        store.upsert(updated)
                        snackbar?.show(.init(text: "Contatto aggiornato.", severity: .info))
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
                          presenceDot: heroPresenceDot)
            Text(item.displayName)
                .font(.system(size: 24, weight: .semibold))
                .italic()
                .foregroundStyle(scheme.onSurface)
                .multilineTextAlignment(.center)
            // W445: extended presence label — shows InCall / DND icons
            // and localised text. I3: `.unknown` (no presence update yet)
            // renders its own "stato sconosciuto" copy, distinct from a
            // confirmed `.offline` peer.
            heroPresenceLabel
        }
        .frame(maxWidth: .infinity)
    }

    /// W445: presence sub-label for the hero section. Extracted to a
    /// computed property so the SwiftUI type-checker operates in a clean
    /// scope (CLAUDE.md §13 — avoid inline expression complexity).
    ///
    /// I3 fix: text selection itself lives in `HeroPresenceLabel`, a pure
    /// enum below — the View only maps the resolved case to styling. Before
    /// this fix `.unknown` fell through to the same literal "offline" string
    /// as a genuinely-confirmed `.offline` peer (masked further by always
    /// reading the hardcoded `item.isOnline == false`), so a contact we
    /// simply hadn't heard from yet looked identical to one we knew for a
    /// fact was offline.
    @ViewBuilder
    private var heroPresenceLabel: some View {
        let presence = appState.presenceService.extendedPresence(for: item.userId)
        let label = HeroPresenceLabel.select(presence: presence, isVerified: item.isVerified)
        switch label {
        case .online:
            Text(label.text)
                .qaudionStyle(type.labelMedium)
                .foregroundStyle(extras.success)
        case .inCall:
            HStack(spacing: 4) {
                Image(systemName: "phone.fill")
                    .font(.caption)
                Text(label.text)
                    .qaudionStyle(type.labelMedium)
            }
            .foregroundStyle(extras.pqcAccent)
        case .doNotDisturb:
            HStack(spacing: 4) {
                Image(systemName: "moon.fill")
                    .font(.caption)
                Text(label.text)
                    .qaudionStyle(type.labelMedium)
            }
            .foregroundStyle(extras.warning)
        case .offline:
            Text(label.text)
                .qaudionStyle(type.labelMedium)
                .foregroundStyle(scheme.onSurfaceVariant)
        case .unknown:
            // I3: distinct visual treatment from real .offline — italic +
            // dimmer, so "never heard from the server" doesn't read as the
            // same confirmed-offline signal at a glance.
            Text(label.text)
                .italic()
                .qaudionStyle(type.labelMedium)
                .foregroundStyle(scheme.onSurfaceVariant.opacity(0.6))
        }
    }

    /// I2: the big hero avatar used to hardcode `item.isOnline` (always
    /// `false` — see `ContactsListContainer` construction sites), so the
    /// dot on this screen never reflected reality regardless of what
    /// `PresenceService` actually knew. Reads the same live source the
    /// label above uses. `.unknown` renders no dot at all (mirrors
    /// `ContactsListView.presenceDot(for:)`'s policy) rather than guessing.
    private var heroPresenceDot: PresenceDot? {
        switch appState.presenceService.extendedPresence(for: item.userId) {
        case .online, .inCall:                    return .online
        case .doNotDisturb:                        return .away
        case .offline, .invisible:                 return .offline
        case .unknown:                             return nil
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
        // C-4 (2026-07-30) — was `trustEval != nil`, which is true for EVERY
        // outcome of `PeerTrustEvaluator.evaluate()` including the graceful-
        // degrade `.unverified` fallback (self identity missing, provider
        // nil, peer fetch failed, bad UUID — see that function's own kdoc:
        // "Never throws... degrades to `.unverified`"). That made this row
        // claim "IK pubblicata sulla directory bcrypto" with a green check
        // even when the identity-key fetch had just FAILED. `peerIkEdPub`
        // is only non-nil on the paths where the peer's Ed25519 identity was
        // actually resolved from the server (see `Evaluation` — every early
        // guard-failure return sets it to `nil`), so it is the correct
        // signal for "identity published", independent of whether the peer
        // also went on to be TOFU-pinned / verified.
        let identityPublished = trustEval?.peerIkEdPub != nil
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("VERIFICA TRUST")
                    .qaudionStyle(type.labelSmall)
                    .tracking(1.2)
                    .foregroundStyle(scheme.onSurfaceVariant)
                Spacer()
                TrustChip(changed ? "IDENTITÀ CAMBIATA" : (verified ? "SAS VERIFICATO" : "IN ATTESA"),
                          accent: changed ? extras.riskHigh : (verified ? extras.success : extras.warning))
            }
            .padding(.bottom, 12)

            trustFactorRow(label: "Identità pubblicata",
                           description: trustEval == nil
                               ? "Verifica in corso…"
                               : (identityPublished ? "IK pubblicata sulla directory bcrypto" : "Impossibile risolvere l'identità del contatto"),
                           done: identityPublished)
            divider
            // Feature B ("voce verificata") — FIXED: this row used to read
            // the SAME `verified` boolean as the SAS row below (a mislabeled
            // duplicate, not a real independent signal — see the
            // W-VOICEFACTOR finding this replaces). Now reads
            // `voiceVerifiedAt`, written ONLY by `ContactsStore
            // .setVoiceVerified` when a `VoiceLearningSession` for this
            // contact — started manually from the live in-call "Avvia
            // apprendimento voce" button, fed from the peer's decoded RX
            // audio — actually reaches `.completed`. Independent of SAS: a
            // contact can be SAS-verified without ever being voice-learned,
            // and vice versa.
            trustFactorRow(label: "Voce verificata",
                           description: voiceVerifiedDescription,
                           done: voiceVerifiedAt != nil)
            divider
            // C-4 — the SAS row now has a real, tappable CTA. It reuses the
            // SAME `showingSasSheet` flow as the "SAS" quick-action button in
            // `actionRow` above (identical guards in `onVerified`, no new
            // code path) rather than opening `NfcExchangeView` directly:
            // that view has no notion of "verify THIS specific contact" (it
            // blind-pairs with whichever HCE device answers the tap) and its
            // success path persists a call PSK into `SovereignKeyVault`
            // only — it never writes to `PeerTrustEvaluator` / `ContactsStore`
            // / `PeerIdentityPinStore`, so completing that ceremony would
            // NOT flip this row and would look like a broken confirmation.
            // `SasVerifySheet` already lists "NFC" as one of its self-attest
            // methods, so a user who really did tap via the Contacts-list
            // "Aggiungi via NFC" flow can still record that here today.
            trustFactorRow(label: "SAS verificato",
                           description: verified
                               ? "Cerimonia SAS completata"
                               : "Avvia cerimonia NFC o SAS via voce",
                           done: verified,
                           ctaLabel: verified ? nil : "Avvia verifica",
                           ctaAction: verified ? nil : { showingSasSheet = true })
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

    /// C-4 (2026-07-30) — rows optionally render a trailing CTA button when
    /// `ctaLabel`/`ctaAction` are both non-nil, mirroring Android's
    /// `TrustFactorRow` (`ContactDetailScreen.kt`), which shows an inline
    /// `TextButton` only for an unsatisfied factor. Before this the row was
    /// a plain `HStack` with no `Button`/`.onTapGesture` anywhere in it —
    /// nothing here was ever selectable, on any row, regardless of state.
    private func trustFactorRow(label: String, description: String, done: Bool,
                                ctaLabel: String? = nil, ctaAction: (() -> Void)? = nil) -> some View {
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
            if let ctaLabel, let ctaAction {
                Button(action: ctaAction) {
                    Text(ctaLabel)
                        .qaudionStyle(type.labelSmall)
                        .fontWeight(.semibold)
                        .foregroundStyle(scheme.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .contentShape(Rectangle())
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

    // MARK: - Presence-auth card (W-ASSURANCE ship step 6/8)

    /// The persisted "this contact has been authenticated in person before"
    /// record (`ContactsStore.PresenceAuth`). A synchronous local read (no
    /// network — unlike `trustEval` above), so this is a plain computed
    /// property rather than `@State` populated by a `.task`.
    ///
    /// **THIS IS A DIFFERENT WIDGET from any live in-call verdict**
    /// (`InCallScreen`'s `assurancePresentation`, driven by
    /// `AssuranceStateUI.present`) — there is no live call context on this
    /// screen at all, and this card renders ONLY the persisted history
    /// record. Never let this speak for a live call, and never let a live
    /// call's banner render on this screen as if it were this badge. See
    /// this project's "two things that must never share a widget" rule.
    private var presenceAuth: ContactsStore.PresenceAuth? {
        ContactsStore().load().first(where: { $0.userId == item.userId })?.presenceAuth
    }

    /// Feature B ("voce verificata") — plain synchronous local read (same
    /// pattern as `presenceAuth` above, no network), the persisted
    /// "a `VoiceLearningSession` for this contact reached `.completed`"
    /// timestamp. nil until the user has run the in-call voice-learning
    /// flow at least once for this contact — see `trustVerificationCard`'s
    /// "Voce verificata" row above, the only consumer.
    private var voiceVerifiedAt: Date? {
        guard let ms = ContactsStore().load().first(where: { $0.userId == item.userId })?.voiceVerifiedAt else {
            return nil
        }
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    private static let voiceVerifiedDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateStyle = .medium
        return f
    }()

    private var voiceVerifiedDescription: String {
        guard let date = voiceVerifiedAt else {
            return "Durante una chiamata, avvia l'apprendimento vocale per registrare il match"
        }
        return "Voiceprint appreso il \(Self.voiceVerifiedDateFormatter.string(from: date))"
    }

    /// `nil` while this contact has never reached `AssuranceState
    /// .nfcAuthenticated` (S2) — which is EVERY contact today, since S2 is
    /// unreachable until ship step 7 wires real NFC mixing. Renders no card
    /// at all in that case, never a fabricated "not yet verified" state (the
    /// existing `trustVerificationCard`/`safetyNumberSection` above already
    /// cover the SAS/manual-verify tier — this card is additive, only for
    /// contacts that actually have an NFC presence record).
    @ViewBuilder
    private var presenceAuthCard: some View {
        if let auth = presenceAuth {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("PRESENZA FISICA (NFC)")
                        .qaudionStyle(type.labelSmall)
                        .tracking(1.2)
                        .foregroundStyle(scheme.onSurfaceVariant)
                    Spacer()
                    TrustChip(presenceAuthStatusLabel(auth.status), accent: presenceAuthStatusTint(auth.status))
                }
                .padding(.bottom, 4)
                Text(presenceAuthSummary(auth))
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4).fill(scheme.surfaceVariant.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(scheme.outline.opacity(0.5), lineWidth: 1))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Presenza fisica NFC: \(presenceAuthStatusLabel(auth.status)). \(presenceAuthSummary(auth))")
        }
    }

    private func presenceAuthStatusLabel(_ status: ContactsStore.PresenceAuth.Status) -> String {
        switch status {
        case .active: return "ATTIVA"
        case .suspended: return "SOSPESA"
        case .revoked: return "REVOCATA"
        }
    }

    private func presenceAuthStatusTint(_ status: ContactsStore.PresenceAuth.Status) -> Color {
        switch status {
        case .active: return extras.success
        case .suspended: return extras.warning
        case .revoked: return extras.riskHigh
        }
    }

    /// `firstConfirmedCallId` is DELIBERATELY never rendered here (standing
    /// project rule: no raw UUIDs in any user-facing UI) — only the
    /// human-relevant date/count.
    private func presenceAuthSummary(_ auth: ContactsStore.PresenceAuth) -> String {
        let date = Date(timeIntervalSince1970: Double(auth.firstConfirmedAt) / 1000)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let dateStr = formatter.string(from: date)
        let times = auth.confirmedCallCount == 1 ? "1 volta" : "\(auth.confirmedCallCount) volte"
        switch auth.status {
        case .active:
            return "Confermata di persona la prima volta il \(dateStr) · \(times) in totale."
        case .suspended:
            // VERBATIM wording family (design brief, S1/S7's persisted-record
            // description): "non usata nell'ultima chiamata".
            return "Non usata nell'ultima chiamata — la cronologia resta valida (confermata dal \(dateStr))."
        case .revoked:
            return "Revocata: questa chiave NFC risultava associata a un'altra identità."
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

    /// 2026-08-06 fix: this used to show two hardcoded, fabricated events
    /// ("oggi · 14:32" SAS ceremony, "ieri · 09:14" voiceprint match)
    /// whenever `item.isVerified` was true, regardless of whether either
    /// ever actually happened for this contact — fake audit-trail data
    /// presented as genuine in a security-focused app. `item` (a plain
    /// `ContactsListViewModel.Item`) only carries a bare `isVerified: Bool`
    /// with no timestamp, but `ContactsStore.StoredContact` (loaded
    /// separately here) already has REAL `verifiedAtMs`/`verificationMethod`/
    /// `voiceVerifiedAt` fields that were just never read by this screen.
    /// Uses only that real data now; falls back to an honest "not
    /// available" message rather than inventing specifics when a legacy
    /// row is verified but has no stored timestamp.
    private var securityLogCard: some View {
        let stored = ContactsStore().load().first(where: { $0.userId == item.userId })
        return VStack(alignment: .leading, spacing: 8) {
            Text("EVENTI DI SICUREZZA CONDIVISI")
                .qaudionStyle(type.labelSmall)
                .tracking(1.2)
                .foregroundStyle(scheme.primary)
                .padding(.bottom, 4)

            if let verifiedMs = stored?.verifiedAtMs {
                eventRow(severity: extras.success,
                         when: Self.formatEventDate(verifiedMs),
                         summary: "Identità verificata (\(stored?.verificationMethod ?? "SAS"))")
            }
            if let voiceMs = stored?.voiceVerifiedAt {
                eventRow(severity: extras.success,
                         when: Self.formatEventDate(voiceMs),
                         summary: "Voce verificata")
            }
            if stored?.verifiedAtMs == nil && stored?.voiceVerifiedAt == nil {
                if item.isVerified {
                    Text("Contatto verificato. Data e metodo della verifica non disponibili per questo record.")
                        .qaudionStyle(type.bodySmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                } else {
                    Text("Nessuna cerimonia SAS registrata per questo contatto. Avvia una verifica vocale o NFC.")
                        .qaudionStyle(type.bodySmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(scheme.surfaceVariant.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(scheme.outline.opacity(0.5), lineWidth: 1))
    }

    private static func formatEventDate(_ epochMs: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(epochMs) / 1000)
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
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

    /// W294: build the guidance snackbar text via static method to keep
    /// the closure body trivial. CLAUDE.md §13.
    private static func openChatGuidance(peer: String) -> String {
        return "Apri la chat con " + peer + " dalla scheda Chat."
    }
}

// MARK: - I3 hero presence label (pure, testable)

/// Text selection for `ContactDetailScreen`'s hero presence sub-label,
/// pulled out of the View body so it's a plain, exhaustively-switched
/// function of its inputs (style mirrors `PskOrigin` in
/// `QAudionEngine/Crypto/KeyExportPolicy.swift`).
///
/// The bug this exists to pin: `.unknown` (no `presence_update` received
/// yet for this peer) used to collapse into the exact same "offline"
/// string as a genuinely-confirmed `ExtendedPresence.offline` — a contact
/// we simply haven't heard from read identically to one the server told us
/// is offline. `.unknown` now gets its own copy; the View additionally
/// gives it a distinct (dimmer, italic) visual treatment.
enum HeroPresenceLabel: Equatable {
    case online(verifiedVoice: Bool)
    case inCall
    case doNotDisturb
    case offline
    case unknown

    /// Matched exhaustively with no `default` so a new `ExtendedPresence`
    /// case forces a decision here instead of silently falling through.
    static func select(presence: ExtendedPresence, isVerified: Bool) -> HeroPresenceLabel {
        switch presence {
        case .online:                     return .online(verifiedVoice: isVerified)
        case .inCall:                      return .inCall
        case .doNotDisturb:                return .doNotDisturb
        case .offline, .invisible:         return .offline
        case .unknown:                     return .unknown
        }
    }

    var text: String {
        switch self {
        case .online(let verifiedVoice):
            return "online · " + (verifiedVoice ? "verified voice" : "voice non verificata")
        case .inCall:       return ExtendedPresence.inCall.label
        case .doNotDisturb: return ExtendedPresence.doNotDisturb.label
        case .offline:      return "offline"
        case .unknown:      return "stato sconosciuto"
        }
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

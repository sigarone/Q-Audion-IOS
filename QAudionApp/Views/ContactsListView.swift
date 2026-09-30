import SwiftUI
import Combine
import QAudionEngine

@MainActor
final class ContactsListContainer: ObservableObject {
    @Published var viewModel: ContactsListViewModel
    @Published private(set) var isRefreshing: Bool = false
    @Published var errorMessage: String?
    @Published var scanProgress: PhonebookSyncCoordinator.ScanProgress?

    private var appState: AppState?
    private let store: ContactsStore
    private var service: ContactsRefreshService?
    private var cancellables: Set<AnyCancellable> = []

    init(appState: AppState? = nil, store: ContactsStore = ContactsStore()) {
        self.appState = appState
        self.store = store
        if let s = appState {
            self.service = ContactsRefreshService(appState: s, store: store)
        } else {
            self.service = nil
        }
        // W73: load from local store. Empty list = empty list — DO NOT
        // populate with `.mock` (Mario Rossi / Anna Bianchi placeholders
        // that surfaced as "fake contacts" during the first end-to-end
        // QA pass). The empty-state UI in ContactsScreen handles the
        // "Nessun contatto" copy.
        let stored = store.load()
        // W-EXTPREFIX consolidation (2026-07-29): `displayName` used to be
        // `sc.displayName` verbatim — a stale "Phone #100"/"New User" row
        // rendered as-is everywhere this view model feeds (ContactsScreen,
        // the new-conversation contact picker). Resolved through the
        // canonical `DisplayName.forUser` instead, with `contacts: stored`
        // so it also picks up `sc`'s own structured `extension`/
        // `phoneNumber` fields for the bare-digit/phone fallback.
        self.viewModel = ContactsListViewModel(items: stored.map { sc in
            ContactsListViewModel.Item(
                userId: sc.userId,
                displayName: DisplayName.forUser(sc.userId, contacts: stored),
                phoneHash: sc.phoneHash, avatarUrl: sc.avatarUrl,
                isOnline: false,
                unreadMessageCount: 0,
                isVerified: sc.isVerified,
                extension: sc.`extension`
            )
        })
        // 2026-07-30 fix (real device evidence: a contact whose ONLY known
        // field is the extension shows the bare extension forever — server
        // display_name "Pavel Ivanov" never surfaces, contact detail's
        // METADATI stays permanently blank). `DisplayName.forUser`'s async
        // enrichment (`NameResolutionService.ensureResolved` →
        // `enrichFromCallProfile`, the only path that fetches the server
        // profile and persists name/phone) only fires on a tier-6 miss —
        // never here, since tier 4 (bare extension, always known once a
        // contact has one) succeeds first. This list — unlike the in-call
        // screens fixed earlier — never called `ensureResolved` at all, so
        // enrichment for a contact reached only by extension never had a
        // chance to run. Kick it explicitly for every row (cheap — the
        // call is internally deduped + cooldown-gated) and re-render via
        // `.contactsDidChange` once it lands.
        for sc in stored {
            NameResolutionService.shared.ensureResolved(userId: sc.userId)
        }
        NotificationCenter.default.publisher(for: .contactsDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reloadFromStore() }
            .store(in: &cancellables)
    }

    /// Re-reads the store and rebuilds the view model, preserving the
    /// current search query — shared by the `.contactsDidChange` observer
    /// above and any other "the persisted contacts changed under us" path.
    private func reloadFromStore() {
        let stored = store.load()
        viewModel = ContactsListViewModel(
            items: stored.map { sc in
                ContactsListViewModel.Item(
                    userId: sc.userId,
                    displayName: DisplayName.forUser(sc.userId, contacts: stored),
                    phoneHash: sc.phoneHash, avatarUrl: sc.avatarUrl,
                    isOnline: false,
                    unreadMessageCount: 0,
                    isVerified: sc.isVerified,
                    extension: sc.`extension`
                )
            },
            searchQuery: viewModel.searchQuery
        )
    }

    func setSearchQuery(_ query: String) {
        viewModel = ContactsListViewModel(items: viewModel.items, searchQuery: query)
    }

    /// Returns the 32B X25519 pubkey for a stored contact, or nil if unknown.
    /// Forwarded straight to ContactsStore so the caller (e.g. detail view)
    /// can compute a canonical fingerprint without depending on the engine
    /// store directly.
    func lookupPubkey(userId: String) -> Data? {
        store.findPubkey(userId: userId)
    }

    /// Late-binds an AppState into the container after construction so the
    /// view can pull AppState from `@EnvironmentObject` and pass it down
    /// without forcing every call site (sheet presenters, previews) to
    /// inject one upfront. Idempotent: calling with the same AppState is
    /// a no-op; calling with a different AppState rebuilds the service.
    func attach(_ state: AppState) {
        if self.appState === state { return }
        self.appState = state
        self.service = ContactsRefreshService(appState: state, store: store)
    }

    /// Persists a QR-scanned payload as a verified local contact. Identity
    /// and device-link payloads both carry a userId + pubkey so we can render
    /// them in the contacts list immediately; fast-setup is onboarding-time
    /// only and is ignored here (the OnboardingFlow path will consume it).
    /// Returns `true` if a new row was inserted (or an existing one updated).
    @discardableResult
    /// `verified: false` is for callers whose in-person evidence does not
    /// bind the userId (an in-person pairing whose server check failed).
    ///
    /// - Parameters:
    ///   - proximityPairedAtMs: non-nil ONLY from the in-person (QR +
    ///     Bluetooth) pairing flow — epoch ms the SAS ceremony completed.
    ///     nil (the default) for an ordinary static-identity-QR scan, which
    ///     is not that ceremony. When nil, any prior in-person record this
    ///     contact already had is preserved, never cleared, by this call.
    ///   - proximityServerConfirmed: whether the server confirmed the
    ///     claimed account published the proved key (spec §12). Meaningless
    ///     when `proximityPairedAtMs` is nil.
    func addScannedContact(_ decoded: QrPayloadRouter.Decoded, verified: Bool = true,
                           proximityPairedAtMs: Int64? = nil,
                           proximityServerConfirmed: Bool? = nil) -> Bool {
        let userId: String
        let displayName: String
        let pubkey: Data
        switch decoded {
        case .identity(let id):
            userId = id.userId
            // W-UUIDSWEEP root cause: this used to persist the RAW 36-char
            // userId as the contact's displayName — the UUID then rendered
            // as the contact's NAME everywhere downstream (contacts list,
            // chat list, call screens, CarPlay). Persist the humane short
            // fallback instead; the server-lookup recovery (InCallContainer)
            // and any later rename upgrade it to the real name.
            displayName = DisplayName.shortUserFallback(id.userId)
            pubkey = id.pubkey
        case .deviceLink(let dl):
            userId = dl.userId
            displayName = DisplayName.shortUserFallback(dl.userId)
            pubkey = dl.pubkey
        case .groupInvite(let invite):
            // W68c: invece di no-op, persistiamo la pending invite in
            // UserDefaults via `PendingGroupInviteStore`. Quando il
            // backend esporrà `POST /groups/:id/join`, l'app può
            // replay-are tutte le pending. Per ora il side-effect
            // visibile per l'utente è l'incremento del counter
            // (visibile in Diagnostica W48 quando wirato).
            PendingGroupInviteStore.append(from: invite)
            // W70: server endpoint live → replay subito invece di
            // attendere il prossimo login. Best-effort, se 401/5xx la
            // pending resta nel local store per il replay successivo.
            if let appState = self.appState,
               let sync = TrackBSyncService.from(serverUrl: appState.serverUrl, token: appState.authService.loadToken()) {
                Task { _ = await sync.replayPendingGroupInvites() }
            }
            return false  // non aggiunto come contatto — è un gruppo
        case .fastSetup, .invalid, .unknown:
            // fastSetup è onboarding-time, gestito da OnboardingFlow.
            return false
        }
        // Security fix (2026-08-22, W-SELFCONTACT): the app has a single
        // generic QR scanner shared between "add contact" and scanning a
        // companion-device-link QR (LinkNewDeviceScreen, whose payload
        // encodes the SCANNING device's own account id — device-link
        // pairing is not yet wired server-side). Without this guard,
        // scanning your own "Collega nuovo dispositivo" QR with the
        // ordinary contacts scanner silently created a contact row whose
        // userId equals your own account, and every call to that "contact"
        // (avatar_announce included) then routed back to yourself. Root
        // cause confirmed end-to-end from QR generation to this call site.
        if let appState = self.appState, userId == appState.currentUserId {
            RTLog.warn("security", "addScannedContact rejected — scanned QR resolves to own account id")
            return false
        }
        // Security-review fix (2026-07-30): this used to build a bare
        // StoredContact and upsert() unconditionally — a full-record
        // replace (ContactsStore.upsert never merges). Re-scanning an
        // ALREADY-known contact's QR (a normal re-verify/re-pair action)
        // silently wiped displayName back to the synthetic short
        // fallback AND reset avatarVersion/avatarUrl/phoneNumber/
        // extension/presenceAuth/presenceFloor to nil — the exact
        // silent-wipe bug class this session's H1-parity/avatar-transport
        // sweep already fixed at 6 other call sites, missed here because
        // this one predates that sweep. Look up any existing row first
        // and preserve everything a re-scan isn't actually meant to
        // change; only pubkey/isVerified are this action's real purpose.
        let existing = store.load().first(where: { $0.userId == userId })
        let contact = ContactsStore.StoredContact(
            userId: userId,
            displayName: existing?.displayName ?? displayName,
            phoneHash: existing?.phoneHash ?? "",         // phone not present in QR payloads
            avatarUrl: existing?.avatarUrl,
            lastSeen: existing?.lastSeen,
            isVerified: verified,   // in-person scan ⇒ verified (unless the caller says otherwise)
            pubkey: pubkey,          // 32B X25519, source of canonical fingerprint
            verifiedFingerprintHex: existing?.verifiedFingerprintHex,
            verifiedAtMs: existing?.verifiedAtMs,
            verificationMethod: existing?.verificationMethod,
            presenceAuth: existing?.presenceAuth,
            presenceFloor: existing?.presenceFloor,
            phoneNumber: existing?.phoneNumber,
            extension: existing?.`extension`,
            avatarVersion: existing?.avatarVersion,
            // W-PAIRFB — only the in-person (QR + Bluetooth) pairing flow
            // passes a non-nil `proximityPairedAtMs`; an ordinary static-
            // identity-QR re-scan must not wipe a prior in-person record.
            proximityPairedAtMs: proximityPairedAtMs ?? existing?.proximityPairedAtMs,
            proximityServerConfirmed: proximityPairedAtMs != nil
                ? proximityServerConfirmed : existing?.proximityServerConfirmed
        )
        store.upsert(contact)
        // W77: kick off the pairwise PSK handshake so future chats with
        // this contact use a real shared secret instead of the
        // deterministic fallback. Fire-and-forget; the response (ACCEPT)
        // arrives via WS opaque_message and lands in the keychain.
        if let appState = self.appState {
            appState.triggerKeyExchange(with: userId, force: false)
        }
        // Refresh the in-memory view-model from the store so the new row
        // shows up immediately in the list.
        reloadFromStore()
        return true
    }

    // MARK: - In-person (QR + Bluetooth) pairing

    /// The Ed25519 identity keys `userId`'s account published on the server;
    /// empty when offline, unknown or signed out. Feeds the pairing screen's
    /// account check (docs/security/PROXIMITY_PAIRING_QR_BLE_SPEC.md §12).
    func publishedIdentityKeys(_ userId: String) async -> Set<Data> {
        guard let provider = appState?.liveProvider else { return [] }
        return await provider.kmsClient.fetchUserIdentityKeySet(userId: userId)
    }

    struct ProximityOutcome: Equatable, Identifiable {
        /// Distinguishes the four ways an in-person pairing can end, for the
        /// telemetry `outcome` attribute (`ProximityPairingTelemetry`) and
        /// for the final-screen icon/tone — never for the user-facing text,
        /// which is `title`/`detail` below.
        ///
        /// Review fix (W-PAIRFB cross-platform telemetry audit): the raw
        /// values are the wire strings the `outcome` attribute ships to the
        /// server and MUST match Android's `ProximityPairingLogic
        /// .telemetryOutcome` vocabulary (known/added/added_verified/
        /// not_added, pinned by its own `ProximityPairingLogicTest`) — they
        /// used to be a separate, iOS-only vocabulary (new_contact/
        /// existing_contact/saved_unverified), which would have silently
        /// split every funnel aggregation by platform. The Swift case NAMES
        /// are unaffected (nothing switches or compares on the raw string
        /// except telemetry), so this is a wire-format-only change.
        enum Kind: String, Equatable {
            case newContactVerified = "added_verified"
            case existingContact = "known"
            case savedUnverified = "added"
            case notAdded = "not_added"
        }
        let id = UUID()
        let title: String
        let detail: String
        let isError: Bool
        let kind: Kind
    }

    /// Records a completed in-person pairing (its key is already in the
    /// vault). The ceremony proves the Ed25519 key of the phone that was in
    /// front of the user, not the key this address book holds for the userId
    /// it claims, so a KNOWN contact is never rewritten (key, verified badge)
    /// from here — spec §12, "adds the peer as a contact if missing"; a
    /// different stored key was already flagged on the confirmation screen.
    /// A new contact is marked verified only when the server confirmed that
    /// the claimed account published that key — this call never upgrades
    /// trust beyond that: a SAS-confirmed pairing whose server check could
    /// not run is reported (and persisted) as "saved", never "verified".
    ///
    /// Either way, `proximityPairedAtMs`/`proximityServerConfirmed` are
    /// persisted (see `ContactsStore.setProximityPairing` / the
    /// `addScannedContact` call below) so `ContactDetailScreen` can show a
    /// "Verificato di persona" / "Chiave di persona salvata" row with a
    /// date — W-PAIRFB, the audit gap this fixes.
    @discardableResult
    func recordProximityPairing(_ result: ProximityPairingSummary) -> ProximityOutcome {
        let peerUserId: String = result.peer.userId
        let alreadyKnown: Bool = store.load().contains(where: { (row: ContactsStore.StoredContact) -> Bool in
            return row.userId == peerUserId
        })
        let name: String = DisplayName.forUser(peerUserId)
        let pairedAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
        let outcome: ProximityOutcome
        if alreadyKnown {
            store.setProximityPairing(userId: peerUserId, pairedAtMs: pairedAtMs,
                                      serverConfirmed: result.serverIdentityConfirmed)
            let title = String(localized: "proximity.outcome.existing_contact",
                defaultValue: "Chiave aggiunta a un contatto esistente",
                comment: "In-person (QR + Bluetooth) pairing outcome — the peer was already a known contact, so only its call key was saved; the contact's own key/verified badge is unchanged. %@ in the detail line is their display name.")
            outcome = ProximityOutcome(title: title, detail: name, isError: false, kind: .existingContact)
        } else {
            let identity = IdentityQrCode.Identity(userId: peerUserId, pubkey: result.peer.encryptionPublicKey)
            let added: Bool = addScannedContact(.identity(identity), verified: result.serverIdentityConfirmed,
                                                proximityPairedAtMs: pairedAtMs,
                                                proximityServerConfirmed: result.serverIdentityConfirmed)
            if !added {
                let title = String(localized: "proximity.outcome.not_added",
                    defaultValue: "Chiave salvata, contatto non aggiunto",
                    comment: "In-person pairing outcome — the call key was saved but the peer could not be added as a contact (e.g. the scanned code resolved to the user's own account)")
                outcome = ProximityOutcome(title: title, detail: name, isError: true, kind: .notAdded)
            } else if result.serverIdentityConfirmed {
                let title = String(localized: "proximity.outcome.new_verified",
                    defaultValue: "Nuovo contatto aggiunto e verificato",
                    comment: "In-person pairing outcome — a brand-new contact was added and the server confirmed the claimed account published the key just proved over Bluetooth")
                outcome = ProximityOutcome(title: title, detail: name, isError: false, kind: .newContactVerified)
            } else {
                let title = String(localized: "proximity.outcome.saved_unverified",
                    defaultValue: "Chiave salvata, verifica server non disponibile",
                    comment: "In-person pairing outcome — the 6-digit code was confirmed on both phones and a new contact was added, but the account-ownership check against the server could not run (offline, timeout, or the account published no keys)")
                outcome = ProximityOutcome(title: title, detail: name, isError: false, kind: .savedUnverified)
            }
        }
        ProximityPairingTelemetry.emitCompleted(outcome: outcome.kind,
                                                serverCheck: result.serverCheckOutcome,
                                                elapsedMs: result.elapsedMs)
        return outcome
    }

    func refresh() {
        guard let svc = service else { return }
        Task {
            await MainActor.run {
                self.isRefreshing = true
                self.errorMessage = nil
                self.scanProgress = nil
            }
            do {
                _ = try await svc.refreshFromPhonebook { progress in
                    Task { @MainActor in self.scanProgress = progress }
                }
                await MainActor.run {
                    self.reloadFromStore()
                    self.isRefreshing = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isRefreshing = false
                }
            }
        }
    }
}

struct ContactsListView: View {
    @StateObject private var container: ContactsListContainer
    @EnvironmentObject private var appState: AppState
    /// Entitlements Task 5 — read directly from the environment for
    /// reactivity; see `QAudionApp.swift`'s injection site doc.
    @EnvironmentObject private var capabilityGate: CapabilityGate
    /// Entitlements Task 5 — drives `.sheet(isPresented:)` for `UpgradeSheet`.
    @State private var showNfcUpgradeSheet: Bool = false
    @State private var searchText: String = ""
    @State private var showingQrScanner: Bool = false
    @State private var showingMyIdentity: Bool = false
    @State private var showingNfcPair: Bool = false
    /// In-person QR + Bluetooth pairing, displayer side.
    @State private var showingProximityPair: Bool = false
    /// W-PAIRFB — the in-person pairing final outcome, presented as its own
    /// clear screen (`ProximityOutcomeResultSheet`).
    @State private var proximityOutcome: ContactsListContainer.ProximityOutcome?
    @State private var showingPhonebookImport: Bool = false
    @State private var lastScanResult: ScanResultBanner?
    @State private var showingGroupCallPicker: Bool = false
    @Environment(\.dismiss) private var dismiss

    init() {
        _container = StateObject(wrappedValue: ContactsListContainer())
    }

    /// Transient banner shown after a successful QR scan so the user gets
    /// confirmation that the contact was added (or that the payload was
    /// rejected). Auto-dismisses after a short delay.
    private struct ScanResultBanner: Equatable {
        let title: String
        let detail: String
        let isError: Bool
    }

    var body: some View {
        List {
            // W-ORPHANPEER — this list is also the new-chat picker, so it
            // must not offer accounts that no longer exist. Read-time filter;
            // see the note in ContactsScreen.allList for why not in the container.
            ForEach(
                container.viewModel.filteredItems
                    .filter { !shouldHideContact(appState.orphanPeerIds.contains($0.userId)) },
                id: \.userId
            ) { item in
                NavigationLink(destination: detailView(for: item)) {
                    contactRow(item)
                }
            }
        }
        .searchable(text: $searchText, prompt: "Cerca contatti")
        .onChange(of: searchText) { newValue in
            // Single-param form for iOS 16 compat.
            container.setSearchQuery(newValue)
        }
        .navigationTitle("Contatti")
        .toolbar {
            // W-GRPUI: real entry point to start a group call — mirrors
            // Android's HomeShell `onStartGroupCall` (contacts tab →
            // multi-select → GroupCallController.createCall). Previously
            // GroupCallController had zero UI reachability on iOS.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingGroupCallPicker = true
                } label: {
                    Image(systemName: "person.2.fill")
                }
                .disabled(container.viewModel.items.isEmpty)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Scansiona QR", systemImage: "qrcode.viewfinder") {
                        showingQrScanner = true
                    }
                    Button("Mostra la mia identità", systemImage: "qrcode") {
                        showingMyIdentity = true
                    }
                    // QR + Bluetooth proximity pairing (hybrid ML-KEM-1024):
                    // this phone shows the code, the other scans it with
                    // "Scansiona QR" above. Not capability-gated.
                    Button(ProximityEntryPointHint.menuTitle, systemImage: "person.2.wave.2") {
                        showingProximityPair = true
                    }
                    // Entitlements Task 5 — Capability.nfc. A `Menu`
                    // row can't render the dim+lock-badge visual treatment
                    // `GatedActionButton` gives an icon button, so this
                    // stays a plain always-visible, always-tappable row
                    // (never removed, matching design doc §7.2) whose
                    // ACTION branches on entitlement instead: unlocked →
                    // the real NFC pairing sheet, locked → UpgradeSheet.
                    Button("Aggiungi via NFC", systemImage: "wave.3.right") {
                        if capabilityGate.isUnlocked(.nfc) {
                            showingNfcPair = true
                        } else {
                            showNfcUpgradeSheet = true
                        }
                    }
                    Button("Importa dal telefono", systemImage: "phone.badge.plus") {
                        showingPhonebookImport = true
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingGroupCallPicker) {
            GroupCallContactPickerSheet(
                // W-ORPHANPEER — group-call picker: a reach surface.
                contacts: container.viewModel.items
                    .filter { !shouldHideContact(appState.orphanPeerIds.contains($0.userId)) },
                onStart: { selectedIds, video in
                    showingGroupCallPicker = false
                    appState.groupCallController?.createCall(
                        invitees: selectedIds,
                        callType: video ? "video" : "audio")
                }
            )
        }
        .refreshable { container.refresh() }
        .onAppear {
            container.attach(appState)
            appState.presenceService.observeCallState(
                callContactId: appState.$callContactId.eraseToAnyPublisher(),
                isInCall: appState.$isInCall.eraseToAnyPublisher()
            )
        }
        // When a chat deep-link is set (e.g. user tapped Chat in ContactDetailView),
        // dismiss this sheet so ChatListScreen can navigate to the conversation.
        .onChange(of: appState.pendingDeepLinkConversationId) { newId in
            if newId != nil { dismiss() }
        }
        .overlay(alignment: .top) {
            if let progress = container.scanProgress, container.isRefreshing {
                scanProgressBanner(progress)
            } else if let banner = lastScanResult {
                scanResultBannerView(banner)
            }
        }
        .sheet(isPresented: $showingMyIdentity) {
            MyIdentityQrSheet(appState: appState)
        }
        .sheet(isPresented: $showingProximityPair) {
            ProximityPairingDisplaySheet(localUserId: appState.currentUserId,
                                         serverIdentityKeys: { (userId: String) async -> Set<Data> in
                                             await container.publishedIdentityKeys(userId)
                                         },
                                         onCompleted: { result in handleProximityPaired(result) })
        }
        .sheet(isPresented: $showingNfcPair) {
            NavigationStack {
                NfcExchangeView()
                    .navigationTitle("Pair via NFC")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Fatto") { showingNfcPair = false }
                        }
                    }
            }
        }
        // Entitlements Task 5 — presents UpgradeSheet when the "Aggiungi
        // via NFC" row is tapped while locked.
        .sheet(isPresented: $showNfcUpgradeSheet) {
            UpgradeSheet(capability: .nfc)
                .environmentObject(appState)
        }
        .sheet(isPresented: $showingPhonebookImport) {
            NavigationStack {
                PhonebookImportView(appState: appState)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Fatto") { showingPhonebookImport = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showingQrScanner) {
            QrScannerSheet(onAccepted: { decoded in
                let added = container.addScannedContact(decoded)
                if added {
                    let id: String = {
                        switch decoded {
                        case .identity(let i): return i.userId
                        case .deviceLink(let d): return d.userId
                        default: return "?"
                        }
                    }()
                    lastScanResult = ScanResultBanner(
                        title: "Contact added",
                        detail: id,
                        isError: false
                    )
                } else {
                    lastScanResult = ScanResultBanner(
                        title: "Scan ignored",
                        detail: "Payload not supported as a contact",
                        isError: true
                    )
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if lastScanResult != nil { lastScanResult = nil }
                }
            },
            proximityLocalUserId: appState.currentUserId,
            proximityServerIdentityKeys: { (userId: String) async -> Set<Data> in
                await container.publishedIdentityKeys(userId)
            },
            onProximityCompleted: { result in handleProximityPaired(result) })
        }
        .sheet(item: $proximityOutcome) { outcome in
            ProximityOutcomeResultSheet(outcome: outcome) { proximityOutcome = nil }
        }
    }

    /// In-person QR + Bluetooth pairing finished on both phones and its key is
    /// already stored (`ProximityPairingStore.persist`). The container adds the
    /// peer only if missing (`recordProximityPairing`); this view reports it
    /// via a clear final screen (`ProximityOutcomeResultSheet`) distinguishing
    /// the three ways it can end, rather than the transient banner this used
    /// (audit finding — easy to miss, no way to tell "verified" from "saved").
    private func handleProximityPaired(_ result: ProximityPairingSummary) {
        let outcome: ContactsListContainer.ProximityOutcome = container.recordProximityPairing(result)
        // Close whichever sheet ran the pairing so the outcome screen below
        // is actually visible (it presents under an open sheet otherwise).
        showingProximityPair = false
        showingQrScanner = false
        proximityOutcome = outcome
    }

    private func scanResultBannerView(_ banner: ScanResultBanner) -> some View {
        HStack(spacing: 10) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(banner.isError ? .red : .green)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(.subheadline.weight(.semibold))
                Text(banner.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(10)
        .background(Color(.systemBackground).opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 2, y: 1)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeOut(duration: 0.2), value: lastScanResult)
    }

    private func scanProgressBanner(_ p: PhonebookSyncCoordinator.ScanProgress) -> some View {
        HStack {
            ProgressView().scaleEffect(0.7)
            Text("Scansione rubrica: \(p.processedContacts) / \(p.totalContacts) — trovati \(p.resolvedUserCount) utenti Q-Audion")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color(.systemBackground).opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.top, 8)
    }

    @ViewBuilder
    private func detailView(for item: ContactsListViewModel.Item) -> some View {
        let pubkey = container.lookupPubkey(userId: item.userId)
        let fingerprint: String = {
            guard let pk = pubkey else { return "????.????.????.????" }
            return (try? Fingerprint.format(pubkey: pk)) ?? "????.????.????.????"
        }()
        // 2026-08-06 fix: this used to hardcode isBlocked: false regardless
        // of the real BlockedContactsStore state, and onBlock always called
        // .add(...) -- a contact already blocked via ContactsScreen's
        // Blocked tab showed here as "not blocked, tap to Block" with no
        // way to unblock from this legacy screen. Read the real state and
        // toggle both directions, matching ContactsScreen/ContactDetailScreen's
        // own block/unblock behavior.
        let reallyBlocked = BlockedContactsStore.isBlocked(item.userId)
        let detail = ContactDetailViewModel(
            userId: item.userId,
            displayName: item.displayName,
            phoneHash: item.phoneHash,
            fingerprint: fingerprint,
            avatarUrl: item.avatarUrl,
            trustLevel: item.isVerified ? .sasVerified : .unverified,
            isBlocked: reallyBlocked,
            lastSeen: nil,
            recentCallCount: 0,
            unreadMessageCount: item.unreadMessageCount
        )
        ContactDetailView(
            viewModel: detail,
            onCall: {
                Task { await appState.startCall(contactId: item.userId, video: false) }
            },
            onChat: {
                openOrCreateChat(peerUserId: item.userId, displayName: item.displayName)
            },
            onVerifySas: nil,
            onBlock: {
                if reallyBlocked {
                    BlockedContactsStore.remove(item.userId)
                } else {
                    BlockedContactsStore.add(item.userId)
                }
            },
            onDelete: {
                ContactsStore().remove(userId: item.userId)
                container.refresh()
            }
        )
    }

    /// Find existing or create new conversation for a peer, then set the deep-link
    /// so ChatListScreen navigates to it. ContactsListView auto-dismisses via onChange.
    private func openOrCreateChat(peerUserId: String, displayName: String) {
        let store = ConversationStore()
        let convId: UUID
        if let existing = store.loadConversations().first(where: { $0.peerUserId == peerUserId }) {
            convId = existing.id
        } else {
            let newConv = Conversation(
                id: UUID(),
                peerUserId: peerUserId,
                peerDisplayName: displayName,
                lastMessagePreview: nil,
                lastActivity: Date(),
                unreadCount: 0,
                pinned: false
            )
            store.upsertConversation(newConv)
            convId = newConv.id
        }
        appState.pendingDeepLinkConversationId = convId
    }

    private func contactRow(_ item: ContactsListViewModel.Item) -> some View {
        HStack(spacing: 12) {
            avatar(item)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayName).font(.body.weight(.medium))
                    if item.isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                // W445: extended presence label — shows "In chiamata",
                // "Non disturbare", etc. when the server or call-state
                // inference provides a richer state than binary online/offline.
                presenceLabel(for: item)
            }
            Spacer()
            if item.unreadMessageCount > 0 {
                Text("\(item.unreadMessageCount)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.blue)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - W445 extended presence helpers (CLAUDE.md §13: pre-bind locals)

    @ViewBuilder
    private func presenceLabel(for item: ContactsListViewModel.Item) -> some View {
        let p = appState.presenceService.extendedPresence(for: item.userId)
        let text: String = presenceLabelText(p, isOnline: item.isOnline)
        let color: Color = presenceLabelColor(p, isOnline: item.isOnline)
        Text(text).font(.caption).foregroundStyle(color)
    }

    private func presenceLabelText(_ p: ExtendedPresence, isOnline: Bool) -> String {
        if p == .unknown { return isOnline ? "Online" : "Offline" }
        return p.label.isEmpty ? (isOnline ? "Online" : "Offline") : p.label
    }

    private func presenceLabelColor(_ p: ExtendedPresence, isOnline: Bool) -> Color {
        switch p {
        case .online:        return .green
        case .inCall:        return Color(hex: 0xB388FF)
        case .doNotDisturb:  return Color(hex: 0xF2B73A)
        case .unknown:       return isOnline ? .green : .secondary
        default:             return .secondary
        }
    }

    @ViewBuilder
    private func presenceDot(for item: ContactsListViewModel.Item) -> some View {
        let p = appState.presenceService.extendedPresence(for: item.userId)
        switch p {
        case .online:
            Circle().fill(Color.green).frame(width: 10, height: 10)
                .overlay(Circle().stroke(.white, lineWidth: 2))
        case .inCall:
            ZStack {
                Circle().fill(Color(hex: 0xB388FF)).frame(width: 12, height: 12)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                Image(systemName: "phone.fill")
                    .font(.system(size: 6, weight: .bold)).foregroundStyle(.white)
            }
        case .doNotDisturb:
            ZStack {
                Circle().fill(Color(hex: 0xF2B73A)).frame(width: 12, height: 12)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                Image(systemName: "moon.fill")
                    .font(.system(size: 5, weight: .bold)).foregroundStyle(.white)
            }
        default:
            EmptyView()
        }
    }

    private func avatar(_ item: ContactsListViewModel.Item) -> some View {
        let blocked = BlockedContactsStore.isBlocked(item.userId)
        return Group {
            if let url = item.avatarUrl {
                AsyncImage(url: url) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    placeholder(item)
                }
                .frame(width: 40, height: 40)
                .clipShape(Circle())
            } else {
                placeholder(item)
            }
        }
        .opacity(blocked ? 0.4 : 1.0)
        .overlay(alignment: .bottomTrailing) {
            if blocked {
                Image(systemName: "circle.slash.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
                    .background(Circle().fill(.white).padding(-1))
            } else {
                // W445: extended presence dot. Only shown when there is
                // a visible state (.online / .inCall / .doNotDisturb).
                // .offline / .unknown / .invisible render no dot.
                presenceDot(for: item)
            }
        }
    }

    private func placeholder(_ item: ContactsListViewModel.Item) -> some View {
        Circle()
            .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 40, height: 40)
            .overlay(
                Text(initials(item.displayName))
                    .font(.caption.bold())
                    .foregroundStyle(.white)
            )
    }

    private func initials(_ name: String) -> String {
        let words = name.split(separator: " ")
        return String(words.prefix(2).compactMap { $0.first }).uppercased()
    }
}

#Preview {
    // Preview needs an AppState in the environment because the "+" menu
    // presents MyIdentityQrSheet which requires it.
    NavigationStack { ContactsListView() }
        .environmentObject(AppState())
        .environmentObject(CapabilityGate.previewInstance())
}

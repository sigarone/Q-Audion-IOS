import SwiftUI
import Contacts
import QAudionEngine

/// W442 — SCOPRI tab: import from device address book.
/// 1:1 port of Android `DiscoverList` + `ImportContactSheet` in ContactsScreen.kt.
///
/// Flow:
///   1. Tap "IMPORTA RUBRICA" card → request CNContactStore permission.
///   2. Load all CNContacts that have at least one phone number.
///   3. Show list filtered by the search text from the parent.
///   4. Tap a row → bottom sheet to confirm alias + manual Q-Audion ID field.
///   5. Save to ContactsStore → contact appears in TUTTI tab immediately.
///
/// Deployment note: CNAuthorizationStatus.limited for Contacts requires
/// iOS 18.0+. All uses are guarded with #available(iOS 18.0, *).
struct PhoneContactImportView: View {
    let searchText: String
    let onImported: (_ displayName: String) -> Void

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type
    @Environment(\.qaudionSnackbar) private var snackbar

    @State private var permission: CNAuthorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
    @State private var candidates: [PhoneCandidate] = []
    @State private var loading: Bool = false
    @State private var selectedCandidate: PhoneCandidate? = nil
    @State private var filtered: [PhoneCandidate] = []

    struct PhoneCandidate: Identifiable {
        let id: String      // CNContact.identifier
        let displayName: String
        let phoneNumbers: [String]
        let thumbnailData: Data?
    }

    // MARK: - Computed

    /// True when the user has granted (full or limited on iOS 18+) contacts access.
    private var isAccessGranted: Bool {
        if permission == .authorized { return true }
        if #available(iOS 18.0, *) {
            return permission == .limited
        }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            importCard
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            if !candidates.isEmpty {
                sectionHeader("RUBRICA LOCALE · \(filtered.count)/\(candidates.count)")
            }

            if loading {
                ProgressView()
                    .padding(.top, 40)
            } else if candidates.isEmpty && isAccessGranted {
                emptyState
            } else {
                candidateList
            }
        }
        .onAppear {
            refreshIfAuthorized()
            updateFiltered(with: candidates)
        }
        .onChange(of: searchText) { _ in
            updateFiltered(with: candidates)
        }
        .onChange(of: candidates) { newCandidates in
            updateFiltered(with: newCandidates)
        }
        .sheet(item: $selectedCandidate) { candidate in
            ImportContactSheet(candidate: candidate) { stored in
                // Security-review fix (2026-07-30): `stored` is always a
                // freshly-built StoredContact from ImportContactSheet — an
                // unconditional upsert() (full-record replace, never a
                // merge) would silently wipe avatarVersion/presenceAuth/
                // presenceFloor/pubkey/verifiedFingerprintHex if the user
                // re-imports (or manually re-types the real userId of) a
                // contact already known locally, the same silent-wipe bug
                // class this session's avatar-transport sweep fixed at 6
                // other call sites. displayName/avatarUrl/phoneNumber stay
                // the user's fresh choice here (this is a deliberate
                // manual-import action, unlike the QR re-scan case) —
                // only the identity/trust/avatar-version fields thread
                // through from any existing row.
                let store = ContactsStore()
                let existing = store.load().first(where: { $0.userId == stored.userId })
                let merged = ContactsStore.StoredContact(
                    userId: stored.userId,
                    displayName: stored.displayName,
                    phoneHash: stored.phoneHash,
                    avatarUrl: stored.avatarUrl,
                    lastSeen: existing?.lastSeen,
                    isVerified: existing?.isVerified ?? stored.isVerified,
                    pubkey: existing?.pubkey,
                    verifiedFingerprintHex: existing?.verifiedFingerprintHex,
                    verifiedAtMs: existing?.verifiedAtMs,
                    verificationMethod: existing?.verificationMethod,
                    presenceAuth: existing?.presenceAuth,
                    presenceFloor: existing?.presenceFloor,
                    phoneNumber: stored.phoneNumber,
                    extension: existing?.`extension`,
                    avatarVersion: existing?.avatarVersion
                )
                store.upsert(merged)
                selectedCandidate = nil
                let name = stored.displayName
                onImported(name)
                snackbar?.show(.init(
                    text: "Contatto \(name) importato in rubrica.",
                    severity: .info
                ))
            }
        }
    }

    // MARK: - Import card (top CTA)

    private var importCard: some View {
        Button(action: requestImport) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(scheme.primary.opacity(0.16))
                        .frame(width: 44, height: 44)
                    Image(systemName: "person.2.crop.square.stack.fill")
                        .foregroundStyle(scheme.primary)
                        .font(.system(size: 18))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("IMPORTA RUBRICA")
                        .qaudionStyle(type.labelSmall)
                        .tracking(1.5)
                        .foregroundStyle(scheme.primary)

                    let subtitle = importCardSubtitle
                    Text(subtitle)
                        .qaudionStyle(type.bodySmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                }

                Spacer()

                Text(candidates.isEmpty ? "AVVIA" : "RISCANSIONA")
                    .qaudionStyle(type.labelSmall)
                    .tracking(1.2)
                    .foregroundStyle(scheme.onPrimary)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(scheme.primary))
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(scheme.primary.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(scheme.primary.opacity(0.35), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(loading)
    }

    private var importCardSubtitle: String {
        if isAccessGranted {
            if candidates.isEmpty {
                return "Carica i tuoi contatti per scoprire chi usa Q-Audion"
            }
            return "\(candidates.count) contatti trovati in rubrica"
        }
        switch permission {
        case .notDetermined:
            return "Tocca per autorizzare l'accesso ai contatti"
        case .denied, .restricted:
            return "Accesso ai contatti negato · apri Impostazioni iOS"
        case .authorized:
            // Handled above by isAccessGranted.
            return candidates.isEmpty
                ? "Carica i tuoi contatti per scoprire chi usa Q-Audion"
                : "\(candidates.count) contatti trovati in rubrica"
        case .limited:
            // iOS 18+: limited access — show available contacts.
            return candidates.isEmpty
                ? "Accesso parziale ai contatti autorizzato"
                : "\(candidates.count) contatti trovati in rubrica"
        @unknown default:
            return "Tocca per importare i contatti"
        }
    }

    // MARK: - Candidate list

    private var candidateList: some View {
        List(filtered) { candidate in
            Button {
                selectedCandidate = candidate
            } label: {
                HStack(spacing: 12) {
                    avatarView(for: candidate)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.displayName)
                            .qaudionStyle(type.titleSmall)
                            .foregroundStyle(scheme.onSurface)
                        if let phone = candidate.phoneNumbers.first {
                            Text(phone)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(scheme.onSurfaceVariant)
                        }
                    }

                    Spacer()

                    Text("IMPORTA")
                        .qaudionStyle(type.labelSmall)
                        .tracking(1.2)
                        .foregroundStyle(scheme.primary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .overlay(
                            Capsule().stroke(scheme.primary, lineWidth: 1)
                        )
                }
            }
            .buttonStyle(.plain)
            .listRowBackground(scheme.background)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(scheme.background)
        // This list is the body of the Contacts tab's SCOPRI tab, so the
        // floating "Aggiungi contatto" capsule ContactsScreen overlays sits
        // above its last row.
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 88) }
    }

    @ViewBuilder
    private func avatarView(for candidate: PhoneCandidate) -> some View {
        if let data = candidate.thumbnailData, let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(Circle())
        } else {
            QAudionAvatar(displayName: candidate.displayName, imageURL: nil, size: 44)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 48))
                .foregroundStyle(scheme.onSurfaceVariant)
            Text("Nessun contatto con numero di telefono")
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurfaceVariant)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.top, 40)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .qaudionStyle(type.labelSmall)
            .tracking(1.5)
            .foregroundStyle(scheme.onSurfaceVariant)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    // MARK: - Permission + loading

    private func requestImport() {
        if isAccessGranted {
            loadCandidates()
            return
        }
        switch permission {
        case .notDetermined:
            CNContactStore().requestAccess(for: .contacts) { granted, _ in
                DispatchQueue.main.async {
                    permission = CNContactStore.authorizationStatus(for: .contacts)
                    if granted { loadCandidates() }
                }
            }
        case .denied, .restricted:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        case .authorized:
            loadCandidates()
        case .limited:
            // iOS 18+: limited access grants read to the user-chosen subset.
            loadCandidates()
        @unknown default:
            break
        }
    }

    // MARK: - Filter logic

    private func updateFiltered(with currentCandidates: [PhoneCandidate]) {
        guard !searchText.isEmpty else {
            filtered = currentCandidates
            return
        }
        let q = searchText.lowercased()
        filtered = currentCandidates.filter {
            $0.displayName.lowercased().contains(q)
            || $0.phoneNumbers.contains { $0.contains(q) }
        }
    }

    // MARK: - Loading

    private func refreshIfAuthorized() {
        if isAccessGranted { loadCandidates() }
    }

    private func loadCandidates() {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let request = CNContactFetchRequest(keysToFetch: DeviceContactLookup.keysToFetch)
            var result: [PhoneCandidate] = []
            do {
                try CNContactStore().enumerateContacts(with: request) { contact, _ in
                    let phones = contact.phoneNumbers.map {
                        DeviceContactLookup.normalizedDigits($0.value.stringValue)
                    }.filter { !$0.isEmpty }
                    guard !phones.isEmpty else { return }
                    let name = [contact.givenName, contact.familyName]
                        .filter { !$0.isEmpty }.joined(separator: " ")
                    guard !name.isEmpty else { return }
                    result.append(PhoneCandidate(
                        id: contact.identifier,
                        displayName: name,
                        phoneNumbers: phones,
                        thumbnailData: contact.thumbnailImageData
                    ))
                }
            } catch {
                // Permission error or no contacts — result stays empty.
            }
            result.sort { $0.displayName < $1.displayName }
            DispatchQueue.main.async {
                candidates = result
                loading = false
                permission = CNContactStore.authorizationStatus(for: .contacts)
            }
        }
    }
}

// MARK: - Import confirmation sheet

private struct ImportContactSheet: View {
    let candidate: PhoneContactImportView.PhoneCandidate
    let onConfirm: (ContactsStore.StoredContact) -> Void

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type
    @Environment(\.dismiss) private var dismiss

    @State private var alias: String
    @State private var qaudionId: String = ""

    init(candidate: PhoneContactImportView.PhoneCandidate,
         onConfirm: @escaping (ContactsStore.StoredContact) -> Void) {
        self.candidate = candidate
        self.onConfirm = onConfirm
        _alias = State(initialValue: candidate.displayName)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Header
                    Text("IMPORTA CONTATTO")
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .tracking(1.5)
                        .foregroundStyle(scheme.primary)
                        .padding(.top, 20)

                    Text(candidate.displayName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(scheme.onSurface)
                        .padding(.top, 6)

                    if let phone = candidate.phoneNumbers.first {
                        Text(phone)
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(scheme.onSurfaceVariant)
                    }

                    Divider().padding(.vertical, 16)

                    // Alias field
                    fieldLabel("NOME NELLA RUBRICA CIFRATA")
                    textField(text: $alias, placeholder: "Nome visualizzato")
                        .padding(.top, 4)

                    // Q-Audion ID field (optional)
                    fieldLabel("ID Q-AUDION (opzionale)")
                        .padding(.top, 14)
                    textField(text: $qaudionId, placeholder: "UUID o estensione del peer")
                        .padding(.top, 4)
                    Text("Lascia vuoto se non conosci l'ID — potrai completarlo in seguito dal dettaglio contatto.")
                        .font(.caption)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .padding(.top, 4)

                    // All phone numbers
                    if candidate.phoneNumbers.count > 1 {
                        fieldLabel("TUTTI I NUMERI")
                            .padding(.top, 14)
                        ForEach(candidate.phoneNumbers, id: \.self) { phone in
                            Text(phone)
                                .font(.system(.subheadline, design: .monospaced))
                                .foregroundStyle(scheme.onSurface)
                                .padding(.vertical, 4)
                        }
                    }

                    // Confirm button
                    Button(action: confirm) {
                        Text("IMPORTA")
                            .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                            .tracking(1.2)
                            .foregroundStyle(scheme.onPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(alias.trimmingCharacters(in: .whitespaces).isEmpty
                                          ? Color.gray : scheme.primary)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(alias.trimmingCharacters(in: .whitespaces).isEmpty)
                    .padding(.top, 24)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .background(scheme.background.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func confirm() {
        let trimName = alias.trimmingCharacters(in: .whitespaces)
        guard !trimName.isEmpty else { return }
        let phone = candidate.phoneNumbers.first ?? ""
        // Use Q-Audion ID if provided; otherwise provisional key from phone number.
        let trimId = qaudionId.trimmingCharacters(in: .whitespaces)
        let userId = trimId.isEmpty ? "phone:" + phone : trimId
        // The raw phone number lives in `phoneNumber` — `phoneHash` stays
        // reserved exclusively for the real peppered server hash (never
        // populated here: a purely-local manual import never talks to the
        // server, so there is no peppered hash to store).
        let localPhotoUrl = candidate.thumbnailData.flatMap {
            DeviceContactLookup.cachePhoto($0, forUserId: userId)
        }
        let stored = ContactsStore.StoredContact(
            userId: userId,
            displayName: trimName,
            phoneHash: "",
            avatarUrl: localPhotoUrl,
            lastSeen: nil,
            isVerified: false,
            phoneNumber: phone
        )
        onConfirm(stored)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced).weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(scheme.onSurfaceVariant)
    }

    private func textField(text: Binding<String>, placeholder: String) -> some View {
        TextField(placeholder, text: text)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.words)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(scheme.surfaceVariant.opacity(0.45))
            )
    }
}

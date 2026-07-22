import SwiftUI
import QAudionEngine

/// "Nuovo gruppo" — ContactPicker per selezionare partecipanti +
/// nome gruppo + bottone "Crea (N)". 1:1 port di Android
/// `qaudion-android-new/feature/feature-chat/.../group/CreateGroupScreen.kt`.
///
/// Layout:
///   1. Top bar — back chevron + "NUOVO GRUPPO" titleSmall semibold tracking 2
///   2. Name field 48pt — placeholder italic "Nome del gruppo…"
///   3. Search field 44pt rounded 22 — "Cerca contatti…"
///   4. Error banner (riskHigh) se `selectedMemberIds.isEmpty` al tap Crea
///   5. ContactPicker LazyVStack — toggle selection con check icon
///   6. Bottom action bar — "Crea (N)" disabled finché lista vuota
///
/// Source contacts: `ContactsStore.load()` (engine Persistence). Quando
/// l'engine espone `GroupChatRepository.createGroup(...)`, il callback
/// `onGroupCreated(groupId)` apre `GroupChatScreen`. Per ora simulato
/// via UUID + snackbar feedback.
struct CreateGroupScreen: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type
    @Environment(\.dismiss) private var dismiss
    @Environment(\.qaudionSnackbar) private var snackbar
    /// W400: needed to call AppState.createGroup which ships invites
    /// via 1:1 ratchet to each selected member.
    @EnvironmentObject private var appState: AppState

    @State private var state: CreateGroupUiState
    let onGroupCreated: (UUID) -> Void

    init(onGroupCreated: @escaping (UUID) -> Void = { _ in }) {
        // Contacts are loaded from appState.cachedContacts on .onAppear
        // (available after @EnvironmentObject injection). Initial value
        // is empty — the view renders an empty picker until appear fires,
        // which is imperceptible since appear fires synchronously on mount.
        _state = State(initialValue: CreateGroupUiState(contacts: []))
        self.onGroupCreated = onGroupCreated
    }

    /// Convert stored contacts to picker rows. Receives the cached snapshot
    /// from AppState so no UserDefaults decode is needed at call time.
    private static func makePickerRows(_ stored: [ContactsStore.StoredContact]) -> [ContactPickerRowUi] {
        return stored.map {
            ContactPickerRowUi(
                userId: $0.userId,
                displayName: $0.displayName,
                avatarUrl: $0.avatarUrl
            )
        }
    }

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                fields
                if let error = state.error {
                    errorBanner(error)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                }
                contactList
                bottomBar
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            // Populate contacts from the AppState cache — zero UserDefaults
            // overhead since cachedContacts is already loaded at app start.
            if state.contacts.isEmpty {
                // W-ORPHANPEER — reachableContacts, not cachedContacts: a
                // member picker must not offer accounts that no longer
                // exist server-side.
                state.contacts = Self.makePickerRows(appState.reachableContacts)
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

            Text("NUOVO GRUPPO")
                .qaudionStyle(type.titleSmall)
                .tracking(2)
                .foregroundStyle(scheme.onSurface)
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 56)
        .background(scheme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(scheme.outline.opacity(0.3)).frame(height: 0.5)
        }
    }

    // MARK: - Fields

    private var fields: some View {
        VStack(spacing: 12) {
            // Name field
            TextField("",
                      text: nameBinding,
                      prompt: Text("Nome del gruppo…")
                          .italic()
                          .foregroundColor(scheme.onSurfaceVariant))
                .qaudionStyle(type.bodyMedium)
                .foregroundColor(scheme.onSurface)
                .tint(scheme.primary)
                .padding(.horizontal, 14).padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(scheme.surfaceVariant.opacity(0.45))
                )

            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(scheme.onSurfaceVariant)
                TextField("",
                          text: queryBinding,
                          prompt: Text("Cerca contatti…")
                              .foregroundColor(scheme.onSurfaceVariant))
                    .qaudionStyle(type.bodyMedium)
                    .foregroundColor(scheme.onSurface)
                    .tint(scheme.primary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 22)
                    .fill(scheme.surfaceVariant.opacity(0.45))
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - Contact list

    private var contactList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                if state.filteredContacts.isEmpty {
                    Text(state.contacts.isEmpty
                         ? "Nessun contatto nella rubrica."
                         : "Nessun risultato.")
                        .qaudionStyle(type.bodySmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .padding(.top, 32)
                } else {
                    ForEach(state.filteredContacts) { row in
                        ContactPickerRow(
                            row: row,
                            isSelected: state.selectedMemberIds.contains(row.userId)
                        ) {
                            toggleMember(row.userId)
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 96)  // space for bottom bar
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            // W319: live selection counter on the left of the bottom
            // bar so the user always sees "N selezionati / M totali"
            // even before tapping Crea. Uses static helper to keep
            // String formatting outside @ViewBuilder closures.
            Text(Self.formatSelectionCounter(
                    selected: state.selectedMemberIds.count,
                    total: state.contacts.count))
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
            Spacer()
            Button(action: handleCreate) {
                HStack(spacing: 6) {
                    if state.creating {
                        ProgressView().progressViewStyle(.circular)
                            .scaleEffect(0.7).tint(scheme.onPrimary)
                    }
                    Text("Crea (\(state.selectedMemberIds.count))")
                        .qaudionStyle(type.labelLarge)
                        .foregroundStyle(scheme.onPrimary)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(
                    Capsule()
                        .fill(canCreate ? scheme.primary : scheme.surfaceVariant)
                )
            }
            .buttonStyle(.plain)
            .disabled(!canCreate || state.creating)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(scheme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(scheme.outline.opacity(0.3)).frame(height: 0.5)
        }
    }

    /// W319: builds the "N selezionati su M" string outside any
    /// @ViewBuilder / closure context. Uses `String(describing:)` to
    /// avoid the `String(Int)` overload trap (SWIFT6_PATTERNS §3).
    private static func formatSelectionCounter(selected: Int,
                                               total: Int) -> String {
        let s: String = String(describing: selected)
        let t: String = String(describing: total)
        return s + " selezionati su " + t
    }

    private var canCreate: Bool {
        !state.selectedMemberIds.isEmpty
    }

    // MARK: - Helpers

    private var nameBinding: Binding<String> {
        Binding(get: { state.name }, set: { state.name = $0 })
    }

    private var queryBinding: Binding<String> {
        Binding(get: { state.query }, set: { state.query = $0 })
    }

    private func toggleMember(_ userId: String) {
        if state.selectedMemberIds.contains(userId) {
            state.selectedMemberIds.remove(userId)
        } else {
            state.selectedMemberIds.insert(userId)
        }
        // Pulisci eventuali errori precedenti quando l'utente riprova.
        state.error = nil
    }

    private func handleCreate() {
        guard canCreate else {
            state.error = "Seleziona almeno un contatto"
            return
        }
        // W400: real path. AppState.createGroup persists in
        // GroupRegistry, bootstraps the GroupChatService session
        // (random 32-byte sender seed → CK_0), AND ships a
        // qa_grp:1 group_invite envelope via the 1:1 ratchet to
        // every selected member. The local user is auto-joined.
        state.creating = true
        let displayName = state.name.trimmingCharacters(in: .whitespaces)
            .isEmpty
            ? "Gruppo \(state.selectedMemberIds.count) membri"
            : state.name
        let memberIds = Array(state.selectedMemberIds)
        // Admin-only initial set: just self. The local user can
        // promote others later via the GroupInfo screen (admin
        // toggle wired to AppState.setGroupAdmin if/when added).
        guard let gidHex = appState.createGroup(
            name: displayName, members: memberIds, admins: []
        ) else {
            state.creating = false
            state.error = "Impossibile creare il gruppo (utente non autenticato)"
            return
        }
        // Convert the gidHex back to UUID for the existing
        // onGroupCreated callback signature (which navigates to
        // GroupChatScreen). The GroupChatScreen already maps
        // groupId.uuidString → hex internally for vault lookups.
        Task { @MainActor in
            // Tiny delay so the snackbar lands AFTER the dismiss
            // animation, matching the prior UX timing.
            try? await Task.sleep(nanoseconds: 200_000_000)
            state.creating = false
            snackbar?.show(.init(
                text: "Gruppo \"\(displayName)\" creato. Invio inviti…",
                severity: .info
            ))
            dismiss()
            // Map the 32-char hex back to a UUID for the existing
            // navigation callback. Insert hyphens at standard offsets.
            if let uuid = Self.uuid(fromHex: gidHex) {
                onGroupCreated(uuid)
            }
        }
    }

    /// W400 — re-hyphenate a 32-char lowercase hex string to UUID.
    private static func uuid(fromHex hex: String) -> UUID? {
        guard hex.count == 32 else { return nil }
        let s = hex
        let formatted = "\(s.prefix(8))-\(s.dropFirst(8).prefix(4))-\(s.dropFirst(12).prefix(4))-\(s.dropFirst(16).prefix(4))-\(s.suffix(12))"
        return UUID(uuidString: formatted)
    }

    // MARK: - Error banner

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
}

// MARK: - ContactPickerRow

private struct ContactPickerRow: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    let row: ContactPickerRowUi
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                QAudionAvatar(displayName: row.displayName,
                              imageURL: row.avatarUrl,
                              size: 40)
                Text(row.displayName)
                    .qaudionStyle(type.titleSmall)
                    .foregroundStyle(scheme.onSurface)
                Spacer(minLength: 8)
                ZStack {
                    Circle()
                        .stroke(isSelected ? scheme.primary
                                            : scheme.outline.opacity(0.6),
                                lineWidth: 1.5)
                        .frame(width: 22, height: 22)
                    if isSelected {
                        Circle().fill(scheme.primary).frame(width: 22, height: 22)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(scheme.onPrimary)
                    }
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationStack {
        CreateGroupScreen()
    }
    .qAudionTheme(dark: true)
}

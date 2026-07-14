import SwiftUI

/// Pannello di gruppo — nome, epoch, membri (con badge ADMIN), button
/// "Esci dal gruppo". 1:1 port di Android
/// `qaudion-android-new/feature/feature-chat/.../group/GroupInfoScreen.kt`.
///
/// Layout:
///   1. Top bar — back chevron + nome gruppo titleLarge semibold +
///      "epoch X · N membri" subtitle mono labelSmall onSurfaceVariant
///   2. Sezione MEMBRI — list righe membri (40pt avatar + displayName +
///      "(tu)" se isSelf + ADMIN badge primary capsule)
///   3. Leave row — riskHigh icon + testo "Esci dal gruppo" (alert
///      conferma su tap)
///
/// Engine wiring pending: il vero `GroupChatRepository.observeGroup(...)`
/// alimenterà state.epoch + members. Oggi il chiamante (futuro
/// GroupChatScreen) passa lo state stub via init.
struct GroupInfoScreen: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type
    @Environment(\.dismiss) private var dismiss
    @Environment(\.qaudionSnackbar) private var snackbar

    @State private var state: GroupInfoUiState
    @State private var showingLeaveConfirm = false
    /// W52: presenta il sheet QR di invito al gruppo. Engine wiring per
    /// `GroupChatRepository.createInvite(groupId:)` deferred — oggi
    /// genera un payload pure-locale (groupId + name).
    @State private var showingInviteQr = false
    /// W321: timestamp dell'ultimo refresh dello state (oggi == apertura
    /// schermata, finché GroupChatRepository.observeGroup non lo
    /// aggiorna). Surfaced in UI come "Aggiornato N min fa" così il
    /// tester sa quanto è fresca la lista membri.
    @State private var lastRefreshAt: Date = Date()
    /// Fase 1A — add-member picker (admin-only) + per-row remove confirm.
    @State private var showingAddMembers = false
    @State private var selectedToAdd: Set<String> = []
    @State private var pendingRemoveMember: GroupMemberRowUi?
    let onLeft: () -> Void

    // Fase 1A — admin membership affordances. Defaulted so pre-existing
    // call sites (and the #Preview) keep compiling; GroupChatScreen wires
    // the real values.
    private let isSelfAdmin: Bool
    private let addableContacts: [ContactPickerRowUi]
    private let onAddMembers: ([String]) -> Void
    private let onRemoveMember: (String) -> Void

    init(state: GroupInfoUiState,
         isSelfAdmin: Bool = false,
         addableContacts: [ContactPickerRowUi] = [],
         onAddMembers: @escaping ([String]) -> Void = { _ in },
         onRemoveMember: @escaping (String) -> Void = { _ in },
         onLeft: @escaping () -> Void = {}) {
        _state = State(initialValue: state)
        self.isSelfAdmin = isSelfAdmin
        self.addableContacts = addableContacts
        self.onAddMembers = onAddMembers
        self.onRemoveMember = onRemoveMember
        self.onLeft = onLeft
    }

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                topBar
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsSectionHeader("MEMBRI")
                        // W321: relative-time freshness indicator. Helps
                        // testers tell stale data from real refresh.
                        Text(Self.formatLastRefreshed(lastRefreshAt))
                            .qaudionStyle(type.labelSmall)
                            .italic()
                            .foregroundStyle(scheme.onSurfaceVariant)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 6)
                        // Fase 1A — admin-only "Aggiungi membri" affordance.
                        if isSelfAdmin {
                            addMembersRow
                                .padding(.horizontal, 16)
                                .padding(.bottom, 8)
                        }
                        VStack(spacing: 8) {
                            ForEach(state.members) { member in
                                memberRow(member)
                            }
                        }
                        .padding(.horizontal, 16)

                        Spacer().frame(height: 24)
                        leaveRow
                            .padding(.horizontal, 16)

                        if let err = state.error {
                            errorBanner(err)
                                .padding(.horizontal, 16)
                                .padding(.top, 8)
                        }

                        Spacer().frame(height: 32)
                    }
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .alert("Uscire dal gruppo \"\(state.name)\"?",
               isPresented: $showingLeaveConfirm) {
            Button("Annulla", role: .cancel) {}
            Button("Esci", role: .destructive) { handleLeave() }
        } message: {
            Text("Non riceverai più i messaggi di questo gruppo. Per rientrare dovrai essere reinvitato da un admin.")
        }
        .sheet(isPresented: $showingInviteQr) {
            // W52: medium detent così la QR è ben visibile ma il sheet
            // resta dismissable swipe-down (non interactiveDismissDisabled).
            GroupInviteQrSheet(groupId: state.groupId,
                               groupName: state.name)
                .presentationDetents([.medium, .large])
        }
        // Fase 1A — add-member multi-select picker (admin).
        .sheet(isPresented: $showingAddMembers) {
            AddGroupMembersSheet(
                candidates: addableRows,
                selected: $selectedToAdd,
                onConfirm: {
                    let ids = Array(selectedToAdd)
                    showingAddMembers = false
                    guard !ids.isEmpty else { return }
                    onAddMembers(ids)
                    snackbar?.show(.init(
                        text: ids.count == 1 ? "Membro aggiunto." : "\(ids.count) membri aggiunti.",
                        severity: .info))
                },
                onCancel: { showingAddMembers = false })
                .presentationDetents([.medium, .large])
        }
        // Fase 1A — remove-member confirmation (admin, destructive).
        .alert("Rimuovere \(pendingRemoveMember?.displayName ?? "")?",
               isPresented: Binding(
                get: { pendingRemoveMember != nil },
                set: { if !$0 { pendingRemoveMember = nil } })) {
            Button("Annulla", role: .cancel) { pendingRemoveMember = nil }
            Button("Rimuovi", role: .destructive) {
                if let m = pendingRemoveMember {
                    onRemoveMember(m.userId)
                    snackbar?.show(.init(text: "Membro rimosso.", severity: .info))
                }
                pendingRemoveMember = nil
            }
        } message: {
            Text("Non riceverà più i messaggi del gruppo. Le chiavi vengono rigenerate per gli altri membri.")
        }
    }

    /// Contacts eligible to add: those not already in the group roster.
    private var addableRows: [ContactPickerRowUi] {
        let present = Set(state.members.map { $0.userId })
        return addableContacts.filter { !present.contains($0.userId) }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(scheme.onSurface)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Indietro")

            VStack(alignment: .leading, spacing: 1) {
                Text(state.name)
                    .qaudionStyle(type.titleMedium)
                    .foregroundStyle(scheme.onSurface)
                    .lineLimit(1)
                Text("epoch \(state.epoch) · \(state.members.count) membri")
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .modifier(MonoCaption())
            }
            Spacer(minLength: 8)
            // W52: Invita via QR. Apre sheet con QR-code che encoda il
            // payload `qaudion-group-invite` (groupId + name). Un peer
            // scansiona il QR dal proprio dispositivo e si auto-aggiunge
            // al gruppo (engine wire pending — oggi solo generazione).
            Button(action: { showingInviteQr = true }) {
                Image(systemName: "qrcode")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(scheme.primary)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Invita via QR")
        }
        .padding(.horizontal, 8)
        .frame(height: 56)
        .background(scheme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(scheme.outline.opacity(0.3)).frame(height: 0.5)
        }
    }

    // MARK: - Member row

    private func memberRow(_ member: GroupMemberRowUi) -> some View {
        HStack(spacing: 12) {
            QAudionAvatar(displayName: member.displayName,
                          imageURL: member.avatarUrl,
                          size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.displayName + (member.isSelf ? " (tu)" : ""))
                        .qaudionStyle(type.titleSmall)
                        .foregroundStyle(scheme.onSurface)
                        .lineLimit(1)
                    if member.isAdmin {
                        Text("ADMIN")
                            .qaudionStyle(type.labelSmall)
                            .tracking(1.0)
                            .foregroundStyle(scheme.onPrimary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(scheme.primary))
                    }
                }
            }
            Spacer(minLength: 8)
            // Fase 1A — admin can remove any OTHER member. Tapping arms a
            // confirmation alert (destructive, forward-secrecy rekey).
            if isSelfAdmin && !member.isSelf {
                Button(action: { pendingRemoveMember = member }) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(extras.riskHigh)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rimuovi \(member.displayName)")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }

    // MARK: - Add members row (admin)

    private var addMembersRow: some View {
        Button(action: {
            selectedToAdd = []
            showingAddMembers = true
        }) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(scheme.primary.opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: "person.badge.plus")
                        .foregroundStyle(scheme.primary)
                        .font(.system(size: 14, weight: .semibold))
                }
                Text("Aggiungi membri")
                    .qaudionStyle(type.bodyMedium)
                    .foregroundStyle(scheme.primary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(scheme.surfaceVariant.opacity(0.4))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Leave row

    private var leaveRow: some View {
        Button(action: { showingLeaveConfirm = true }) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(extras.riskHigh.opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .foregroundStyle(extras.riskHigh)
                        .font(.system(size: 14, weight: .semibold))
                }
                Text("Esci dal gruppo")
                    .qaudionStyle(type.bodyMedium)
                    .foregroundStyle(extras.riskHigh)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(scheme.surfaceVariant.opacity(0.4))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    /// W321: builds "Aggiornato …" relative-time string with locale
    /// it_IT. Static so its String formatting lives outside any
    /// @ViewBuilder closure (SWIFT6_PATTERNS rule 1).
    private static func formatLastRefreshed(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.unitsStyle = .full
        let rel: String = f.localizedString(for: date, relativeTo: Date())
        return "Aggiornato " + rel
    }

    private func handleLeave() {
        // W409: real leave path. Snackbar surfaces user feedback;
        // dismiss closes the info sheet; onLeft delegates the actual
        // engine-side leave (ship qa_grp:1 member_left + tear down
        // local registry/session) to the caller, which has the
        // groupId in scope and wires AppState.leaveGroup.
        snackbar?.show(.init(
            text: "Hai lasciato il gruppo.",
            severity: .info
        ))
        dismiss()
        onLeft()
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
}

private struct MonoCaption: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.system(.caption, design: .monospaced))
    }
}

/// Fase 1A — multi-select sheet for adding members to an existing group.
/// Reuses `ContactPickerRowUi` (same rows as `CreateGroupScreen`). Purely
/// presentational: the confirm handler hands the selected userIds back to
/// `GroupInfoScreen`, which drives `AppState.addGroupMembers`.
private struct AddGroupMembersSheet: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    let candidates: [ContactPickerRowUi]
    @Binding var selected: Set<String>
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var query: String = ""

    private var filtered: [ContactPickerRowUi] {
        guard !query.isEmpty else { return candidates }
        let q = query.lowercased()
        return candidates.filter { $0.displayName.lowercased().contains(q) }
    }

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if candidates.isEmpty {
                    emptyState
                } else {
                    searchField
                    list
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Button("Annulla") { onCancel() }
                .foregroundStyle(scheme.onSurfaceVariant)
            Spacer()
            Text("Aggiungi membri")
                .qaudionStyle(type.titleSmall)
                .foregroundStyle(scheme.onSurface)
            Spacer()
            Button("Aggiungi") { onConfirm() }
                .foregroundStyle(selected.isEmpty ? scheme.onSurfaceVariant : scheme.primary)
                .disabled(selected.isEmpty)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(scheme.onSurfaceVariant)
            TextField("Cerca contatti", text: $query)
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(scheme.surfaceVariant.opacity(0.5)))
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(filtered) { row in
                    Button(action: { toggle(row.userId) }) {
                        HStack(spacing: 12) {
                            QAudionAvatar(displayName: row.displayName,
                                          imageURL: row.avatarUrl, size: 40)
                            Text(row.displayName)
                                .qaudionStyle(type.titleSmall)
                                .foregroundStyle(scheme.onSurface)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: selected.contains(row.userId)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(row.userId)
                                                 ? scheme.primary : scheme.onSurfaceVariant)
                                .font(.system(size: 20))
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 12)
                            .fill(scheme.surfaceVariant.opacity(0.4)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 40))
                .foregroundStyle(scheme.onSurfaceVariant)
            Text("Nessun contatto da aggiungere")
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurfaceVariant)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func toggle(_ userId: String) {
        if selected.contains(userId) { selected.remove(userId) }
        else { selected.insert(userId) }
    }
}

#Preview {
    NavigationStack {
        GroupInfoScreen(state: GroupInfoUiState(
            name: "Famiglia",
            epoch: 4,
            members: [
                GroupMemberRowUi(userId: "u-self", displayName: "Tu",
                                 isAdmin: true, isSelf: true),
                GroupMemberRowUi(userId: "u-mario", displayName: "Mario Rossi",
                                 isAdmin: false, isSelf: false),
                GroupMemberRowUi(userId: "u-anna", displayName: "Anna Bianchi",
                                 isAdmin: false, isSelf: false),
                GroupMemberRowUi(userId: "u-luigi", displayName: "Luigi Verdi",
                                 isAdmin: true, isSelf: false)
            ]
        ))
    }
    .qAudionTheme(dark: true)
}

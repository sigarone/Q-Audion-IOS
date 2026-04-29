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
    let onLeft: () -> Void

    init(state: GroupInfoUiState, onLeft: @escaping () -> Void = {}) {
        _state = State(initialValue: state)
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
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
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

    private func handleLeave() {
        // Stub: simula leave (engine wiring pending).
        snackbar?.show(.init(
            text: "Hai lasciato il gruppo.",
            severity: .info
        ))
        dismiss()
        // Caller (futuro GroupChatScreen) gestisce pop addizionale.
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

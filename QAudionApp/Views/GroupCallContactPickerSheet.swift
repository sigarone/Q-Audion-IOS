import SwiftUI
import QAudionEngine

/// Minimal multi-select contact picker for starting a group call — the
/// missing UI reachability piece for `GroupCallController.createCall`
/// (previously the ONLY iOS call site was `#Preview`/`CallDesignShowcase`).
/// Mirrors Android's contacts-tab → multi-select → `onStartGroupCall` flow
/// (`HomeShell.kt`), simplified to a single sheet since iOS presents the
/// call surface reactively off `AppState.groupCallControllerState` rather
/// than navigating with a pre-known callId.
struct GroupCallContactPickerSheet: View {
    let contacts: [ContactsListViewModel.Item]
    /// W-GRPVIDEO: `video` reflects the toggle below — threaded down to
    /// `GroupCallController.createCall(callType:)` so an ad-hoc group call
    /// can start as video, not just audio.
    let onStart: (_ selectedUserIds: [String], _ video: Bool) -> Void

    @State private var selected: Set<String> = []
    /// W-GRPVIDEO: audio/video choice for the call about to be created.
    @State private var wantsVideo = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: $wantsVideo) {
                        Label("Videochiamata", systemImage: wantsVideo ? "video.fill" : "video.slash")
                    }
                }
                Section {
                    if contacts.isEmpty {
                        Text("Nessun contatto disponibile")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(contacts, id: \.userId) { contact in
                            Button {
                                toggle(contact.userId)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(contact.displayName).font(.body)
                                        Text(contact.userId.prefix(8) + "…")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selected.contains(contact.userId) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.blue)
                                    } else {
                                        Image(systemName: "circle")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Chiamata di gruppo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Avvia (\(selected.count))") {
                        onStart(Array(selected), wantsVideo)
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
    }

    private func toggle(_ userId: String) {
        if selected.contains(userId) {
            selected.remove(userId)
        } else {
            selected.insert(userId)
        }
    }
}

#Preview {
    GroupCallContactPickerSheet(
        contacts: [
            .init(userId: "user-mario-1234", displayName: "Mario Rossi", phoneHash: "", avatarUrl: nil, isOnline: true, unreadMessageCount: 0, isVerified: true),
            .init(userId: "user-anna-5678", displayName: "Anna Bianchi", phoneHash: "", avatarUrl: nil, isOnline: false, unreadMessageCount: 0, isVerified: false)
        ],
        onStart: { _, _ in }
    )
}

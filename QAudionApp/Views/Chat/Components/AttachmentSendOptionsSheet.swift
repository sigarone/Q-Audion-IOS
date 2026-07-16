import SwiftUI

/// W-XPTTL — pre-send attachment options: the TTL/view-once timer
/// override (`EphemeralTimerOption`, already shipped as W447) PLUS the
/// export-permission toggle, presented together.
///
/// Design decision requires the export toggle "alongside" the existing
/// TTL picker. SwiftUI's `confirmationDialog` is a plain button list —
/// it cannot host a live `Toggle` — so this is a `.sheet` with a `List`
/// instead of the action-sheet style the bare TTL picker used before
/// this field existed. Shared by all THREE attachment-send surfaces so
/// they offer byte-identical UX and encoding:
///   - 1:1 (`ChatDetailScreen`'s `pendingAttachmentSend` flow)
///   - group chat (`GroupChatScreen`'s `pendingGroupAttachmentSend` flow)
///   - group in-call chat (`GroupCallChatPanel`'s equivalent flow)
///
/// Confirm returns `(overrideSeconds, exportBlocked)` — same encoding
/// `EphemeralTimerOption.seconds`/`AttachmentTimerResolver` already use
/// (nil/0 = off, -1 = view-once, positive = TTL seconds) plus a plain
/// `Bool` for the export choice (`false` = allowed, matches the wire
/// default). Cancel discards everything — mirrors the pre-existing
/// confirmationDialog's "nothing sent until confirmed" contract.
struct AttachmentSendOptionsSheet: View {
    @Environment(\.qaudionScheme) private var scheme

    /// Conversation-level default TTL. `nil` for group sends (group has
    /// no per-conversation default — mirrors the `conversationDefault:
    /// nil` contract already established for
    /// `AttachmentTimerResolver.resolve` on the group receive path).
    let currentDefaultSeconds: Int?
    let onConfirm: (_ overrideSeconds: Int?, _ exportBlocked: Bool) -> Void
    let onCancel: () -> Void

    @State private var selectedOptionId: String
    @State private var exportAllowed: Bool = true

    init(currentDefaultSeconds: Int?,
         onConfirm: @escaping (Int?, Bool) -> Void,
         onCancel: @escaping () -> Void) {
        self.currentDefaultSeconds = currentDefaultSeconds
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        let defaultOption = EphemeralTimerOption.all.first(where: { $0.seconds == currentDefaultSeconds })
            ?? EphemeralTimerOption.all[0]
        _selectedOptionId = State(initialValue: defaultOption.id)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Consenti esportazione", isOn: $exportAllowed)
                } footer: {
                    Text("Se disattivato, chi riceve questo allegato non potrà salvarlo né condividerlo. Nessuna protezione lato server — solo un limite mostrato nell'app di chi riceve.")
                }
                Section("Timer") {
                    ForEach(EphemeralTimerOption.all) { option in
                        Button {
                            selectedOptionId = option.id
                        } label: {
                            HStack {
                                Text(option.label)
                                    .foregroundStyle(scheme.onSurface)
                                Spacer()
                                if option.id == selectedOptionId {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(scheme.primary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Opzioni allegato")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Invia") {
                        let seconds = EphemeralTimerOption.all
                            .first(where: { $0.id == selectedOptionId })?.seconds
                        onConfirm(seconds, !exportAllowed)
                    }
                }
            }
        }
    }
}

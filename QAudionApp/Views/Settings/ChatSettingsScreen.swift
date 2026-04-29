import SwiftUI
import QAudionEngine

@MainActor
final class ChatSettingsContainer: ObservableObject {
    @Published var viewModel: ChatSettingsViewModel
    private let store: SettingsStore

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
        self.viewModel = store.loadChat()
    }

    func toggleReadReceipts(_ enabled: Bool) {
        viewModel = makeUpdated(readReceipts: enabled)
        store.saveChat(viewModel)
    }

    func toggleTypingIndicators(_ enabled: Bool) {
        viewModel = makeUpdated(typing: enabled)
        store.saveChat(viewModel)
    }

    func toggleMessagePreview(_ enabled: Bool) {
        viewModel = makeUpdated(preview: enabled)
        store.saveChat(viewModel)
    }

    private func makeUpdated(
        readReceipts: Bool? = nil,
        typing: Bool? = nil,
        preview: Bool? = nil
    ) -> ChatSettingsViewModel {
        ChatSettingsViewModel(
            readReceiptsEnabled: readReceipts ?? viewModel.readReceiptsEnabled,
            typingIndicatorsEnabled: typing ?? viewModel.typingIndicatorsEnabled,
            messagePreviewInNotifications: preview ?? viewModel.messagePreviewInNotifications
        )
    }
}

/// Chat settings sub-screen. W26 design-token refactor — migrates from
/// stock SwiftUI `Form` to the same `SettingsToggleRow` vocabulary used
/// in the new `SettingsScreen` root. Functional bindings unchanged.
struct ChatSettingsScreen: View {
    @StateObject private var container: ChatSettingsContainer

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    init(state: AppState) {
        _container = StateObject(wrappedValue: ChatSettingsContainer())
    }

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsSectionHeader("INTERAZIONE")
                    VStack(spacing: 8) {
                        SettingsToggleRow(
                            title: "Conferme di lettura",
                            subtitle: "Notifica al mittente quando hai letto",
                            isOn: Binding(
                                get: { container.viewModel.readReceiptsEnabled },
                                set: { container.toggleReadReceipts($0) }
                            )
                        )
                        SettingsToggleRow(
                            title: "Indicatore di scrittura",
                            subtitle: "Mostra ai contatti quando stai scrivendo",
                            isOn: Binding(
                                get: { container.viewModel.typingIndicatorsEnabled },
                                set: { container.toggleTypingIndicators($0) }
                            )
                        )
                    }

                    SettingsSectionHeader("NOTIFICHE")
                    VStack(spacing: 8) {
                        SettingsToggleRow(
                            title: "Anteprima messaggio nelle notifiche",
                            subtitle: "Visibile sulla schermata di blocco",
                            isOn: Binding(
                                get: { container.viewModel.messagePreviewInNotifications },
                                set: { container.toggleMessagePreview($0) }
                            )
                        )
                        privacyHintRow
                    }

                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
            }
        }
        .navigationTitle("Chat")
    }

    @ViewBuilder
    private var privacyHintRow: some View {
        if container.viewModel.messagePreviewInNotifications {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "eye")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(extras.warning)
                Text("Il contenuto del messaggio sarà visibile sulla schermata di blocco.")
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(extras.warning)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(extras.warning.opacity(0.12))
            )
        } else {
            Text("Contenuto nascosto sulla schermata di blocco — consigliato per sicurezza.")
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .padding(.horizontal, 14)
        }
    }
}
